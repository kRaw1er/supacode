import Foundation
import SupacodeSettingsShared
import SwiftTreeSitter
import SwiftTreeSitterLayer
import Synchronization
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
  private nonisolated static let logger = SupaLogger("DiffHighlightEngine")

  /// Shared instance so every open diff tab reuses one bounded parse cache across
  /// files. `disposeShared()` tears it down; the next access rebuilds a fresh one.
  static private(set) var shared = DiffHighlightEngine()
  static func disposeShared() { shared = DiffHighlightEngine() }

  private let parseTrees = ParseTreeCache(capacity: 24)
  private let spans = HighlightSpanCache(capacity: 100)
  /// Per-engine cache of language configs (root + injected), keyed by `queryName`. A
  /// `Mutex` (not a plain dict) because neon calls the `languageProvider` off the main
  /// actor to resolve injected sublayers, so this must be reachable nonisolated. It is
  /// PER-INSTANCE (not static): a tree-sitter `Query` is bound to its parser, so a
  /// config must not be shared across the distinct neon clients different engines own.
  private let configCache = Mutex<[String: LanguageConfiguration]>([:])
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

  // MARK: - async parse (off-main) → span-cache fill (the warmer's path)

  /// Buckets the window and unions it into the span cache for scroll reuse. Prefers neon's
  /// SYNCHRONOUS `highlights` overload (reads the already-parsed tree, no `await`); only when the
  /// tree is not yet warm does it fall through to the expensive async parse.
  func styleRuns(for input: HighlightBlobInput, visibleLines: Range<Int>) async -> [Int: [StyleRun]] {
    guard let prepared = prepare(input) else { return [:] }
    let key = HighlightSpanCache.Key(
      blobOID: input.blobOID, queryName: prepared.grammar.queryName, themeGen: syntaxThemeGen)
    // Mark the REQUESTED range covered up front — BEFORE the empty-window early return —
    // so lines past the blob end or lines that yield no tokens are recorded as queried and
    // `missingBlobLines` never re-reports them. Without this the warmer re-requests the same
    // token-less lines every layout → warm→repaint→layout→warm runaway (the <60fps loop).
    let requested = max(0, visibleLines.lowerBound)..<max(max(0, visibleLines.lowerBound), visibleLines.upperBound)
    spans.markCovered(requested, for: key)
    let window = windowRange(prepared.blob, visibleLines)
    guard !window.lines.isEmpty else { return [:] }
    let provider = prepared.blob.string.predicateTextProvider

    // FAST PATH — the SYNC `highlights` overload (`TreeSitterClient.swift:380`) reads the
    // ALREADY-PARSED tree and returns immediately. It is ~1000× cheaper than the async overload,
    // which re-runs `processLocation` + `await`s neon's background processor on EVERY call (the
    // async overload was ~34ms/call warm vs ~0.04ms sync — that per-call async cost, serialized
    // by the parse gate, was the scroll slowdown). It is also SUSPENSION-FREE, so a concurrent
    // warm fan-out can't interleave on neon's non-Sendable tree here — no race, no gate needed.
    // Returns `nil` only while the tree still has pending changes (the initial parse hasn't
    // reached this window yet) → fall through to the async parse below.
    if let byLine = trySyncStyleRuns(prepared: prepared, window: window, key: key, provider: provider) {
      return byLine
    }

    // SLOW PATH — the tree is not warm yet. Drive ONE async parse of the WHOLE blob so neon's
    // background processor SETTLES (`hasPendingChanges → false`); only then does the sync overload
    // start answering. A PARTIAL (windowed) parse leaves the rest pending, so `hasPendingChanges`
    // stays true and EVERY later sync returns nil → every call re-parses (~34-64ms) — the scroll
    // slowdown. Settle once, and the whole file is sync-cheap forever after.
    //
    // Single-flight it via the per-client gate: the FIRST cold task runs the full-file parse; every
    // task that piled up behind the gate re-checks sync on wake and returns WITHOUT parsing. That
    // also fixes the fan-out cost (14 concurrent cold windows used to EACH re-parse 0→depth,
    // serialized → seconds). Serializing is likewise what stops the concurrent-parse corruption
    // (the all-red bug): the async overload suspends on the background processor, and two at once on
    // the same non-Sendable client race.
    let gate = parseGate(for: ParseTreeCache.Key(blobOID: input.blobOID, queryName: prepared.grammar.queryName))
    await gate.acquire()
    defer { gate.release() }
    if let byLine = trySyncStyleRuns(prepared: prepared, window: window, key: key, provider: provider) {
      return byLine
    }
    do {
      // Parse the window (returns its runs, advances the tree), then SETTLE the rest cheaply: a
      // 1-unit query at the END drives `processLocation` to `blob.length` → `hasPendingChanges`
      // clears → every LATER window takes the sync fast path. A 1-unit query materializes no O(file)
      // capture array (a full-range query would). This cold path runs ONCE per blob.
      let named = try await prepared.client.highlights(in: window.range, provider: provider)
      let byLine = mergeNamed(named, prepared: prepared, window: window, key: key)
      let end = prepared.blob.text.length
      if end > window.range.upperBound {
        _ = try await prepared.client.highlights(in: NSRange(location: end - 1, length: 1), provider: provider)
      }
      return byLine
    } catch {
      Self.logger.error("highlight failed for \(input.path): \(error)")
    }
    return trySyncStyleRuns(prepared: prepared, window: window, key: key, provider: provider) ?? [:]
  }

  /// The synchronous fast path: `nil` when the tree isn't warm enough to answer without a parse
  /// (neon's sync overload returns `nil` while `hasPendingChanges`). Suspension-free, so it never
  /// races a concurrent warm.
  private func trySyncStyleRuns(
    prepared: Prepared, window: WindowRange, key: HighlightSpanCache.Key, provider: @escaping SwiftTreeSitter.Predicate.TextProvider
  ) -> [Int: [StyleRun]]? {
    do {
      let named: [NamedRange]? = try prepared.client.highlights(in: window.range, provider: provider)
      guard let named else { return nil }
      return mergeNamed(named, prepared: prepared, window: window, key: key)
    } catch {
      Self.logger.error("sync highlight failed for \(prepared.grammar.queryName): \(error)")
      return nil
    }
  }

  private func mergeNamed(
    _ named: [NamedRange], prepared: Prepared, window: WindowRange, key: HighlightSpanCache.Key
  ) -> [Int: [StyleRun]] {
    let byLine = Self.bucket(
      named, lineStarts: prepared.blob.lineStarts, textLength: prepared.blob.text.length, window: window.lines)
    spans.merge(byLine, into: key)
    return byLine
  }

  /// FIFO async mutex (count 1). One per neon client serializes `highlights` calls so a
  /// concurrent warm fan-out can never run two parses on the same non-Sendable
  /// `TreeSitterClient` at once (which corrupts neon's parse into all-`string` garbage).
  @MainActor
  private final class ParseGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
      if !busy {
        busy = true
        return
      }
      await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
      if waiters.isEmpty {
        busy = false
      } else {
        waiters.removeFirst().resume()
      }
    }
  }

  private var parseGates: [ParseTreeCache.Key: ParseGate] = [:]

  private func parseGate(for key: ParseTreeCache.Key) -> ParseGate {
    if let gate = parseGates[key] { return gate }
    let gate = ParseGate()
    parseGates[key] = gate
    return gate
  }

  // MARK: - pure cache reads (the pull-model read side; no parse, no client build)

  /// Reads ONLY the span cache (`spans[Key(blobOID, queryName, syntaxThemeGen)]`) and
  /// returns the subset of cached entries whose key line falls inside `blobLines`. No
  /// `prepare`, no parse, no client build — a pure dictionary read for the draw/warm
  /// path. Returns `[:]` when the blob isn't cached at all.
  ///
  /// LINE SPACE: `blobLines` and the returned keys are **0-based blob lines** — exactly
  /// what `bucket` emits and `styleRuns` merges into the cache. Any 1-based↔0-based
  /// translation is the caller's job (the warmer owns it, via `blobWindow(forLineNumbers:)`),
  /// never this method's.
  func cachedRuns(blobOID: String, queryName: String, blobLines: Range<Int>) -> [Int: [StyleRun]] {
    guard let map = spans[.init(blobOID: blobOID, queryName: queryName, themeGen: syntaxThemeGen)] else { return [:] }
    // Iterate the REQUESTED range and probe the map (O(range)), NOT the whole map
    // (O(cache) — which grows to the whole file as you scroll, turning every read into a
    // full-file scan).
    var result: [Int: [StyleRun]] = [:]
    for line in blobLines where map[line] != nil {
      result[line] = map[line]
    }
    return result
  }

  /// Single-blob-line convenience for `SyntaxRunsProvider.live` — the HOT path (called
  /// per drawn row per frame). A direct O(1) dictionary probe: it must NOT fan out to the
  /// range version (that once iterated the entire span map for one line → O(cache) per
  /// row → the "gets slow everywhere after scrolling to the end" regression).
  func cachedRuns(blobOID: String, queryName: String, blobLine: Int) -> [StyleRun] {
    spans[.init(blobOID: blobOID, queryName: queryName, themeGen: syntaxThemeGen)]?[blobLine] ?? []
  }

  /// The coalesced sub-ranges of `blobLines` the warmer must still query — the lines NOT
  /// yet COVERED (queried). Covered is tracked separately from the runs map (`styleRuns`
  /// marks the whole requested range covered), so a line that was queried but produced no
  /// tokens counts as PRESENT and is never re-requested — without that the warm re-queries
  /// token-less / past-end lines every layout and never converges (the <60fps loop).
  ///
  /// LINE SPACE: 0-based blob lines, matching `cachedRuns` / the span cache.
  func missingBlobLines(blobOID: String, queryName: String, blobLines: Range<Int>) -> [Range<Int>] {
    spans.missingRanges(
      blobLines, for: .init(blobOID: blobOID, queryName: queryName, themeGen: syntaxThemeGen))
  }

  /// Grammar `queryName` for a file path (the span-cache key component), or `nil` when
  /// no bundled grammar matches (a plain render). `nonisolated` so the warmer / a test
  /// can resolve the key without hopping to the main actor.
  nonisolated static func grammarQueryName(forPath path: String) -> String? {
    GrammarRegistry.grammar(forPath: path)?.queryName
  }

  /// 1-based visible line-number range → the 0-based blob-line window the cache is
  /// keyed by (blob line `i` == source line number `i + 1`). An empty / degenerate
  /// range stays empty. `nonisolated` so the warmer / a test resolves it off the main
  /// actor — the single translation point between line-number space and blob-line space.
  nonisolated static func blobWindow(forLineNumbers lines: Range<Int>) -> Range<Int> {
    guard !lines.isEmpty else { return 0..<0 }
    let lower = max(0, lines.lowerBound - 1)
    let upper = max(lower, lines.upperBound - 1)
    return lower..<upper
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
      // Build the Swift String FIRST from the UTF-16 units, then derive the NSString
      // from IT (`string as NSString`) so `text.length == string.utf16.count` by
      // construction. The reverse (`NSString(fromRawUTF16) as String`) can re-normalize
      // and CHANGE the UTF-16 count, desyncing every consumer: `lineStarts` +
      // `windowRange` live in `NSString.length` space while neon parses `string` in
      // `String.utf16.count` space — a query range past the parse length makes
      // tree-sitter read past content (`location > end` crash). ONE UTF-16 space now.
      let string = String(decoding: input.utf16, as: UTF16.self)
      let text = string as NSString
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
    let config = languageConfiguration(for: grammar)
    let length = content.utf16.count
    // tree-sitter's parser reads a few UTF-16 units PAST the content end (lookahead /
    // EOF detection). SwiftTreeSitter's stock reader `assertionFailure`s on that in
    // DEBUG (`String+Data.swift "location is greater than end"`) but returns `nil`
    // (benign) in RELEASE. Our index math is already consistent —
    // `(content as NSString).length == content.utf16.count` by construction, since the
    // blob is built String-FIRST (see `prepare`), verified: the over-read is at
    // `unit > length` while `nsLength == length` — so this is NOT a length desync, it
    // is that third-party DEBUG assertion. Return `nil` past the end (release
    // behaviour) so DEBUG builds don't crash mid-parse.
    let stock = Parser.readFunction(for: content, limit: length)
    let read: Parser.DataSnapshotProvider = { byteOffset, point in
      byteOffset / 2 > length ? nil : stock(byteOffset, point)
    }
    let snapshot = LanguageLayer.ContentSnapshot(
      readHandler: read, textProvider: content.predicateTextSnapshotProvider)
    let client = try TreeSitterClient(
      rootLanguageConfig: config,
      configuration: .init(
        // neon resolves injected sublayers on its BACKGROUND processor, so this is a
        // NONISOLATED instance call — `MainActor.assumeIsolated` here crashed off the
        // main thread. Per-engine (via `self`) so each neon client's configs stay
        // isolated (a tree-sitter `Query` is bound to its parser).
        languageProvider: { [weak self] name in
          self?.injectedConfiguration(named: name)
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

  /// Resolve + cache a grammar's `LanguageConfiguration`. `nonisolated` because neon
  /// resolves injected sublayers on its BACKGROUND processor and calls this through
  /// the `languageProvider`; the `Mutex` cache makes that safe. Pure otherwise (bundle
  /// read + query compile), so it runs correctly off the main actor.
  nonisolated func languageConfiguration(for grammar: GrammarRegistry.Grammar) -> LanguageConfiguration {
    configCache.withLock { cache in
      if let cached = cache[grammar.queryName] { return cached }
      var queries: [Query.Definition: Query] = [:]
      if let highlights = Self.loadQuery(.highlights, grammar: grammar) { queries[.highlights] = highlights }
      // Injections are legitimately absent for most grammars (only html/markdown/php
      // etc. bundle one); a missing `injections.scm` is NOT an error.
      if let injections = Self.loadQuery(.injections, grammar: grammar) { queries[.injections] = injections }
      let config = LanguageConfiguration(grammar.language(), name: grammar.queryName, queries: queries)
      cache[grammar.queryName] = config
      return config
    }
  }

  /// Resolves an injected language name (e.g. `"javascript"`) to this engine's config
  /// for it — nonisolated so neon's `languageProvider` can call it off the main actor
  /// (a `MainActor.assumeIsolated` here crashed on neon's background processor). A
  /// missing grammar returns `nil` so the embedded region renders plain.
  nonisolated func injectedConfiguration(named name: String) -> LanguageConfiguration? {
    guard let grammar = GrammarRegistry.grammar(forInjectionName: name) else {
      Self.logger.info("no grammar for injected language \(name); embedded region renders plain")
      return nil
    }
    return languageConfiguration(for: grammar)
  }

  nonisolated static func loadQuery(_ definition: Query.Definition, grammar: GrammarRegistry.Grammar) -> Query? {
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
      // Drop non-color modifier captures (`@spell`/`@conceal`): they carry no
      // foreground, resolve to `labelColor`, and — arriving AFTER the real
      // `@comment`/`@string` capture for the same range — would override it and paint
      // e.g. comments in the default text color instead of the muted comment color.
      guard Self.isColorBearing(range.name) else { continue }
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

  /// tree-sitter modifier captures that mark a region for tooling (spell-checking,
  /// conceal) but carry NO foreground color. `highlights.scm` emits them alongside a
  /// real color capture over the SAME range, so without this filter they resolve to
  /// the default `labelColor` and clobber the real capture in array order.
  nonisolated static let nonColorCaptures: Set<String> = ["spell", "nospell", "conceal"]

  /// `false` for a non-color modifier capture (`@spell`, `@spell.foo`, `@conceal`, …),
  /// matched on the ROOT component so a namespaced variant is caught too.
  nonisolated static func isColorBearing(_ capture: String) -> Bool {
    let root = capture.split(separator: ".").first.map(String.init) ?? capture
    return !nonColorCaptures.contains(root)
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
