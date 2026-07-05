import Foundation
import SupacodeSettingsShared
import SwiftTreeSitter
import TreeSitterGrammars

/// Background parsing actor for the diff viewer's syntax highlighting. Swift 6:
/// raw `Parser`/`Tree`/`Query`/`QueryCursor` are not `Sendable`, so they are
/// confined here and never cross an isolation boundary — only value
/// `[LineHighlight]` escapes. The `@MainActor` view applies the returned spans as
/// `foregroundColor` attributes (system-color theme).
///
/// Performance shape (what keeps a 50k-line file smooth): the whole file is parsed
/// once per (file, content-hash) and the `Tree` is cached in a small LRU; each
/// per-viewport request only re-runs the highlights *query* scoped to the visible
/// byte range via `cursor.setRange`. Requests are cancellable — a superseding
/// viewport Task cancels the prior one and `Task.isCancelled` short-circuits.
actor SyntaxHighlighter {
  /// Shared instance so open diff tabs reuse one bounded parse cache across files.
  static let shared = SyntaxHighlighter()

  /// A capture span within one line, in **line-relative UTF-16 offsets** so it
  /// composes directly with the row's `AttributedString`.
  struct HighlightSpan: Sendable, Equatable {
    let range: Range<Int>
    let capture: String
  }

  /// Highlights for a single 1-based source line.
  struct LineHighlight: Sendable, Equatable {
    let line: Int
    let spans: [HighlightSpan]
  }

  /// One viewport-scoped highlight request. Grouped so the entry point stays a
  /// single argument (and the `@Sendable` language factory rides along).
  struct Request: Sendable {
    let fileKey: String
    let contentHash: Int
    let source: String
    let language: @Sendable () -> OpaquePointer
    let queryName: String
    let visibleLines: Range<Int>
  }

  /// Identifies a cached parse. `contentHash` invalidates the tree when the file
  /// changes under a live re-diff.
  private struct CacheKey: Hashable {
    let fileKey: String
    let contentHash: Int
  }

  /// A parsed file kept inside the actor (non-Sendable, never escapes).
  private struct ParsedFile {
    let tree: MutableTree
    /// UTF-16 offset of each 1-based line's start (`lineStarts[0]` == line 1).
    let lineStarts: [Int]
    /// Total UTF-16 length, for clamping the viewport range.
    let utf16Length: Int
  }

  private var cache: [CacheKey: ParsedFile] = [:]
  private var lruOrder: [CacheKey] = []
  private var queryCache: [String: Query] = [:]
  private let maxCachedFiles = 8
  private static let logger = SupaLogger("SyntaxHighlighter")

  /// Above this byte count the whole-file parse is skipped (SpecFlow 7.6). Mirrors
  /// `GrammarRegistry.byteCap`.
  private static let sourceByteCap = 2_000_000

  /// Computes highlights for the visible line range of a file.
  ///
  /// - Returns: one `LineHighlight` per visible line that has captures. Empty when
  ///   the grammar has no bundled query, the file is over the cap, parsing fails,
  ///   or the request was cancelled.
  func highlights(_ request: Request) -> [LineHighlight] {
    guard !request.visibleLines.isEmpty else { return [] }
    guard request.source.utf8.count <= Self.sourceByteCap else { return [] }
    if Task.isCancelled { return [] }

    guard let query = query(for: request.queryName, language: request.language) else { return [] }
    guard
      let parsed = parsedFile(
        fileKey: request.fileKey,
        contentHash: request.contentHash,
        source: request.source,
        language: request.language
      )
    else { return [] }
    if Task.isCancelled { return [] }

    let lineCount = parsed.lineStarts.count
    let window = max(1, request.visibleLines.lowerBound)...min(lineCount, request.visibleLines.upperBound - 1)
    guard window.lowerBound <= window.upperBound else { return [] }

    // Viewport as a UTF-16 NSRange (setRange converts to bytes internally).
    let startOffset = parsed.lineStarts[window.lowerBound - 1]
    let endOffset = window.upperBound < lineCount ? parsed.lineStarts[window.upperBound] : parsed.utf16Length
    let viewport = NSRange(location: startOffset, length: max(0, endOffset - startOffset))

    let cursor = query.execute(in: parsed.tree)
    cursor.setRange(viewport)
    let namedRanges = cursor.resolve(with: .init(string: request.source)).highlights()

    // Bucket each capture (byte range → UTF-16 range → line-relative spans).
    var spansByLine: [Int: [HighlightSpan]] = [:]
    for named in namedRanges {
      if Task.isCancelled { return [] }
      let byteRange = named.range
      let utf16Range = (byteRange.location / 2)..<(NSMaxRange(byteRange) / 2)
      guard utf16Range.upperBound > utf16Range.lowerBound else { continue }
      bucket(utf16Range, capture: named.name, lineStarts: parsed.lineStarts, window: window, into: &spansByLine)
    }

    return
      spansByLine
      .sorted { $0.key < $1.key }
      .map { LineHighlight(line: $0.key, spans: $0.value) }
  }

  /// Drops the cached parse(s) for a file — call when the tab closes or the file
  /// is no longer shown, so the tree isn't retained.
  func cancel(fileKey: String) {
    let keys = cache.keys.filter { $0.fileKey == fileKey }
    for key in keys {
      cache[key] = nil
      lruOrder.removeAll { $0 == key }
    }
  }

  // MARK: - Bucketing

  /// Splits one capture's UTF-16 range across the line(s) it overlaps, clipped to
  /// the visible window, appending line-relative spans.
  private func bucket(
    _ utf16Range: Range<Int>,
    capture: String,
    lineStarts: [Int],
    window: ClosedRange<Int>,
    into spansByLine: inout [Int: [HighlightSpan]]
  ) {
    let startLine = line(forOffset: utf16Range.lowerBound, lineStarts: lineStarts)
    let endLine = line(forOffset: utf16Range.upperBound - 1, lineStarts: lineStarts)
    for lineNumber in max(startLine, window.lowerBound)...min(endLine, window.upperBound) where lineNumber >= 1 {
      let lineStart = lineStarts[lineNumber - 1]
      let lineEnd = lineNumber < lineStarts.count ? lineStarts[lineNumber] : Int.max
      let spanLower = max(utf16Range.lowerBound, lineStart) - lineStart
      let spanUpper = min(utf16Range.upperBound, lineEnd) - lineStart
      guard spanUpper > spanLower else { continue }
      spansByLine[lineNumber, default: []].append(
        HighlightSpan(range: spanLower..<spanUpper, capture: capture)
      )
    }
  }

  /// 1-based line for a UTF-16 offset (binary search over `lineStarts`).
  private func line(forOffset offset: Int, lineStarts: [Int]) -> Int {
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
    return result + 1
  }

  // MARK: - Parse cache

  private func parsedFile(
    fileKey: String,
    contentHash: Int,
    source: String,
    language: @Sendable () -> OpaquePointer
  ) -> ParsedFile? {
    let key = CacheKey(fileKey: fileKey, contentHash: contentHash)
    if let cached = cache[key] {
      touch(key)
      return cached
    }
    let parser = Parser()
    do {
      try parser.setLanguage(Language(language()))
    } catch {
      Self.logger.error("setLanguage failed for \(fileKey): \(error)")
      return nil
    }
    guard let tree = parser.parse(source) else { return nil }
    let parsed = ParsedFile(
      tree: tree,
      lineStarts: Self.lineStarts(of: source),
      utf16Length: source.utf16.count
    )
    insert(key, parsed)
    return parsed
  }

  /// Result of locating a *resolved* grammar's bundled `highlights.scm`. A missing
  /// file here means `GrammarRegistry` already matched the file to `queryName` yet
  /// the query resource is absent — a stale/partial `TreeSitterGrammars` build, NOT
  /// a legitimate plain-text file — so the caller logs loudly instead of failing
  /// silently to plain text (the root cause of "highlighting doesn't work").
  enum QueryResource: Equatable {
    case available(URL)
    case missing(queryName: String)
  }

  /// Locates the bundled `highlights.scm` for a resolved grammar. Pure and
  /// `bundle`-injectable so the loud-vs-silent decision is unit-testable without a
  /// running actor. Mirrors the lookup the query loader uses at runtime.
  static func queryResource(for queryName: String, in bundle: Bundle = .main) -> QueryResource {
    guard
      let url = bundle.url(
        forResource: "highlights",
        withExtension: "scm",
        subdirectory: "TreeSitterQueries/\(queryName)"
      )
    else { return .missing(queryName: queryName) }
    return .available(url)
  }

  private func query(for queryName: String, language: @Sendable () -> OpaquePointer) -> Query? {
    if let cached = queryCache[queryName] { return cached }
    let url: URL
    switch Self.queryResource(for: queryName) {
    case .available(let resolvedURL):
      url = resolvedURL
    case .missing:
      // A grammar the registry resolved but whose query never made it into the
      // bundle: surface it loudly rather than degrading to plain text in silence.
      Self.logger.error(
        "missing bundled highlights.scm for resolved grammar '\(queryName)' — plain-text fallback "
          + "(stale/partial TreeSitterGrammars build?)"
      )
      return nil
    }
    do {
      let data = try Data(contentsOf: url)
      let query = try Query(language: Language(language()), data: data)
      queryCache[queryName] = query
      return query
    } catch {
      Self.logger.error("query load failed for \(queryName): \(error)")
      return nil
    }
  }

  private func insert(_ key: CacheKey, _ parsed: ParsedFile) {
    cache[key] = parsed
    lruOrder.append(key)
    while lruOrder.count > maxCachedFiles {
      let evicted = lruOrder.removeFirst()
      cache[evicted] = nil
    }
  }

  private func touch(_ key: CacheKey) {
    lruOrder.removeAll { $0 == key }
    lruOrder.append(key)
  }

  /// UTF-16 offset of each 1-based line start.
  private static func lineStarts(of source: String) -> [Int] {
    var starts = [0]
    var offset = 0
    for scalar in source.unicodeScalars {
      offset += scalar.value > 0xFFFF ? 2 : 1
      if scalar == "\n" {
        starts.append(offset)
      }
    }
    return starts
  }
}
