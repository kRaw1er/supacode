import Foundation
import SupacodeSettingsShared
import SwiftTreeSitter
import SwiftTreeSitterLayer
import TreeSitterClient

/// One blob (old OR new side) prepared for highlighting. `utf16` is the raw UTF-16
/// code-unit blob from the Phase-9 streaming layer (`FileDiffBatch.old/newBlobUTF16`);
/// `blobOID` (the git object id) is the content identity → cache key, so the base
/// blob parses once across every worktree diff. `path` determines the grammar (a
/// rename that changes language keys each side on its own path).
///
/// `nonisolated` + value type so it lives in TCA state and rides into `@Sendable`
/// effect closures unchanged. `[UInt16]` equality has the stdlib identical-buffer
/// fast path, so comparing two copies whose blob was not reassigned is O(1).
nonisolated struct HighlightBlobInput: Sendable, Equatable {
  let blobOID: String
  let utf16: [UInt16]
  let path: String
}

/// Wraps ChimeHQ **neon** for the diff viewer. neon has zero diff awareness — the
/// diff-indirection (correct blob per `DiffSource`, both sides, span → line mapping)
/// is entirely ours. One `TreeSitterClient` per `(blobOID, queryName)` over a whole
/// blob (each blob is a valid complete source file — what tree-sitter needs, NOT
/// patch text); `NamedRange` (absolute UTF-16 file offsets) map to line-relative
/// `StyleRun`s via the blob's line-start table.
///
/// `@MainActor` because `TreeSitterClient` is `@MainActor` and non-`Sendable`
/// (`TreeSitterClient.swift:22-24`); its heavy parse runs off-main on the client's
/// internal `BackgroundingLanguageLayerTree`. Kept off the render critical path by
/// the `DiffHighlightPolicy` size gate + the windowed query + the sync fast path.
@MainActor
final class DiffHighlightEngine {
  private static let logger = SupaLogger("DiffHighlightEngine")

  /// Shared instance so every open diff tab reuses one bounded parse cache across
  /// files. `disposeShared()` tears it down; the next access rebuilds a fresh one.
  static private(set) var shared = DiffHighlightEngine()
  static func disposeShared() { shared = DiffHighlightEngine() }

  private let parseTrees = ParseTreeCache(capacity: 24)
  private let spans = HighlightSpanCache(capacity: 100)
  private var configCache: [String: LanguageConfiguration] = [:]
  /// NSString + line-start table per blob (content identity), so bucketing is O(1)
  /// per span and the blob is decoded once. Keyed by `blobOID`.
  private var blobStore: [String: PreparedBlob] = [:]

  /// Bumped by a future user-theme swap; invalidates span-cache keys but NEVER the
  /// parse-tree cache (parse trees are theme-independent).
  private(set) var syntaxThemeGen = 0
  func bumpSyntaxTheme() { syntaxThemeGen += 1 }

  private struct PreparedBlob {
    let text: NSString
    let string: String
    /// UTF-16 offset of each 0-based line start (NO trailing sentinel).
    let lineStarts: [Int]
  }

  private struct Prepared {
    let client: TreeSitterClient
    let blob: PreparedBlob
    let grammar: GrammarRegistry.Grammar
  }

  // MARK: - sync fast path (paint now) + async fallback (never blocks a deep parse)

  /// Synchronous attempt for the render path. Returns `nil` ⇒ the parse is still
  /// pending (neon `canAttemptSynchronousAccess == hasPendingChanges == false`, C9)
  /// and the caller should schedule the async pass. Returns `[:]` when there is no
  /// grammar / nothing visible (a legitimate plain render, not a pending parse).
  func syncStyleRuns(for input: HighlightBlobInput, visibleLines: Range<Int>) -> [Int: [StyleRun]]? {
    guard let prepared = prepare(input) else { return [:] }
    let window = windowRange(prepared.blob, visibleLines)
    guard !window.lines.isEmpty else { return [:] }
    do {
      // Non-async context ⇒ the sync `highlights(in:provider:) -> [NamedRange]?`
      // overload (TreeSitterClient.swift:380-382); `nil` ⇒ still parsing.
      guard
        let named = try prepared.client.highlights(
          in: window.range, provider: prepared.blob.string.predicateTextProvider)
      else { return nil }
      return Self.bucket(
        named, lineStarts: prepared.blob.lineStarts, textLength: prepared.blob.text.length, window: window.lines)
    } catch {
      Self.logger.error("sync highlight failed for \(input.path): \(error)")
      return [:]
    }
  }

  /// Async pass — always answers (TreeSitterClient.swift:385-387). Buckets the
  /// window and unions it into the span cache for scroll reuse.
  func styleRuns(for input: HighlightBlobInput, visibleLines: Range<Int>) async -> [Int: [StyleRun]] {
    guard let prepared = prepare(input) else { return [:] }
    let window = windowRange(prepared.blob, visibleLines)
    guard !window.lines.isEmpty else { return [:] }
    do {
      let named = try await prepared.client.highlights(
        in: window.range, provider: prepared.blob.string.predicateTextProvider)
      let byLine = Self.bucket(
        named, lineStarts: prepared.blob.lineStarts, textLength: prepared.blob.text.length, window: window.lines)
      spans.merge(
        byLine,
        into: .init(blobOID: input.blobOID, queryName: prepared.grammar.queryName, themeGen: syntaxThemeGen))
      return byLine
    } catch {
      Self.logger.error("highlight failed for \(input.path): \(error)")
      return [:]
    }
  }

  // MARK: - client + config build (mirrors TreeSitterClient+Neon.swift:75-110)

  /// Builds/reuses the client, the decoded blob, and resolves the grammar. `nil` ⇒
  /// no bundled grammar (render plain) or a build failure (logged loudly).
  private func prepare(_ input: HighlightBlobInput) -> Prepared? {
    guard let grammar = GrammarRegistry.grammar(forPath: input.path) else { return nil }

    let blob: PreparedBlob
    if let cached = blobStore[input.blobOID] {
      blob = cached
    } else {
      let text = NSString(characters: input.utf16, length: input.utf16.count)
      let string = text as String
      let prepared = PreparedBlob(text: text, string: string, lineStarts: Self.lineStarts(of: text))
      blobStore[input.blobOID] = prepared
      blob = prepared
    }

    let key = ParseTreeCache.Key(blobOID: input.blobOID, queryName: grammar.queryName)
    let client: TreeSitterClient
    if let cached = parseTrees[key] {
      client = cached
    } else {
      guard let built = try? buildClient(grammar: grammar, content: blob.string) else {
        Self.logger.error("failed to build tree-sitter client for '\(grammar.queryName)' (\(input.path))")
        return nil
      }
      parseTrees[key] = built
      client = built
    }
    return Prepared(client: client, blob: blob, grammar: grammar)
  }

  private func buildClient(grammar: GrammarRegistry.Grammar, content: String) throws -> TreeSitterClient {
    let config = try languageConfiguration(for: grammar)
    let length = content.utf16.count
    let snapshot = LanguageLayer.ContentSnapshot(string: content, limit: length)
    let client = try TreeSitterClient(
      rootLanguageConfig: config,
      configuration: .init(
        languageProvider: { [weak self] name in
          MainActor.assumeIsolated { self?.injectedConfiguration(named: name) }
        },
        contentSnapshopProvider: { _ in snapshot },
        lengthProvider: { length },
        invalidationHandler: { _ in },
        locationTransformer: { _ in nil }
      )
    )
    // Seed the length so the first query has content to parse (headless template).
    client.didChangeContent(in: NSRange(location: 0, length: 0), delta: length)
    return client
  }

  private func languageConfiguration(for grammar: GrammarRegistry.Grammar) throws -> LanguageConfiguration {
    if let cached = configCache[grammar.queryName] { return cached }
    var queries: [Query.Definition: Query] = [:]
    if let highlights = loadQuery(.highlights, grammar: grammar) {
      queries[.highlights] = highlights
    }
    // Injections are legitimately absent for most grammars (only html/markdown/php
    // etc. bundle one); a missing `injections.scm` is NOT an error.
    if let injections = loadQuery(.injections, grammar: grammar) {
      queries[.injections] = injections
    }
    let config = LanguageConfiguration(grammar.language(), name: grammar.queryName, queries: queries)
    configCache[grammar.queryName] = config
    return config
  }

  /// Resolves an injected language name (e.g. `"javascript"`, `"css"`) to its
  /// bundled config. A missing grammar logs loudly (Phase 0 principle — never a
  /// silent drop) and returns `nil`, so the embedded region renders plain.
  func injectedConfiguration(named name: String) -> LanguageConfiguration? {
    guard let grammar = GrammarRegistry.grammar(forInjectionName: name) else {
      Self.logger.info("no grammar for injected language '\(name)'; embedded region renders plain")
      return nil
    }
    return try? languageConfiguration(for: grammar)
  }

  private func loadQuery(_ definition: Query.Definition, grammar: GrammarRegistry.Grammar) -> Query? {
    guard
      let url = Bundle.main.url(
        forResource: definition.name,
        withExtension: "scm",
        subdirectory: "TreeSitterQueries/\(grammar.queryName)"
      )
    else {
      // A resolved grammar with no bundled highlights.scm is a stale/partial
      // TreeSitterGrammars build — surface it. Injections are optional, stay quiet.
      if definition == .highlights {
        Self.logger.error(
          "missing bundled highlights.scm for resolved grammar '\(grammar.queryName)' — plain-text fallback "
            + "(stale/partial TreeSitterGrammars build?)")
      }
      return nil
    }
    do {
      return try Query(language: Language(grammar.language()), data: Data(contentsOf: url))
    } catch {
      Self.logger.error("query load failed for '\(grammar.queryName)/\(definition.name)': \(error)")
      return nil
    }
  }

  // MARK: - NamedRange (absolute UTF-16) → line-relative StyleRun

  /// Buckets each capture into line-relative `StyleRun`s. `named.range` is **already
  /// UTF-16 code units** (`QueryDefinitions.swift:57` reads `tsRange.bytes.range`,
  /// which `Encoding+Helpers.swift:30-31` already divided by 2, and the parser runs
  /// `TSInputEncodingUTF16` — `Parser.swift`), so it is consumed **directly**: NO
  /// second `/2` (C10 — the double-`/2` bug the retired hand-rolled highlighter
  /// shipped). Only lines inside `window` produce runs (windowed query); a capture
  /// spanning multiple lines is clipped to each line's bounds.
  nonisolated static func bucket(
    _ named: [NamedRange],
    lineStarts: [Int],
    textLength: Int,
    window: Range<Int>
  ) -> [Int: [StyleRun]] {
    var byLine: [Int: [StyleRun]] = [:]
    guard !lineStarts.isEmpty else { return byLine }
    for range in named {
      let nsRange = range.range  // ALREADY UTF-16 — no /2
      guard nsRange.length > 0 else { continue }
      let lower = nsRange.location
      let upper = NSMaxRange(nsRange)
      var line = Self.line(forOffset: lower, lineStarts: lineStarts)
      while line < lineStarts.count {
        let lineStart = lineStarts[line]
        if lineStart >= upper { break }
        let lineEnd = line + 1 < lineStarts.count ? lineStarts[line + 1] : textLength
        if window.contains(line) {
          let spanLo = max(lower, lineStart) - lineStart
          let spanHi = min(upper, lineEnd) - lineStart
          if spanHi > spanLo {
            byLine[line, default: []].append(StyleRun(range: spanLo..<spanHi, capture: range.name))
          }
        }
        line += 1
      }
    }
    return byLine
  }

  /// 0-based line for a UTF-16 offset — largest index with `lineStarts[index] <=
  /// offset` (binary search).
  nonisolated static func line(forOffset offset: Int, lineStarts: [Int]) -> Int {
    var low = 0
    var high = lineStarts.count - 1
    var result = 0
    while low <= high {
      let mid = (low + high) / 2
      if lineStarts[mid] <= offset {
        result = mid
        low = mid + 1
      } else {
        high = mid - 1
      }
    }
    return result
  }

  /// UTF-16 offset of each 0-based line start (NO trailing sentinel): the last line's
  /// end is the blob length. ONE `unichar`-level pass, no Swift `String`.
  nonisolated static func lineStarts(of text: NSString) -> [Int] {
    var starts = [0]
    let length = text.length
    var index = 0
    while index < length {
      if text.character(at: index) == 0x0A { starts.append(index + 1) }
      index += 1
    }
    return starts
  }

  // MARK: - windowing

  /// The UTF-16 `NSRange` a visible-line window covers, plus the clamped line range.
  private struct WindowRange {
    let range: NSRange
    let lines: Range<Int>
  }

  private func windowRange(_ blob: PreparedBlob, _ visibleLines: Range<Int>) -> WindowRange {
    let count = blob.lineStarts.count
    let lower = max(0, visibleLines.lowerBound)
    let upper = min(count, visibleLines.upperBound)
    guard lower < upper else { return WindowRange(range: NSRange(location: 0, length: 0), lines: lower..<upper) }
    let start = blob.lineStarts[lower]
    let end = upper < count ? blob.lineStarts[upper] : blob.text.length
    return WindowRange(range: NSRange(location: start, length: max(0, end - start)), lines: lower..<upper)
  }
}
