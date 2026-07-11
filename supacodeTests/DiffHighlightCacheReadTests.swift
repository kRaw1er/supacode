import Foundation
import Testing

@testable import supacode

/// Phase A — the pull-model READ side. Warms a REAL `DiffHighlightEngine` through the
/// async `styleRuns` write path (the only thing that fills the span cache today), then
/// asserts the additive pure reads (`cachedRuns`, `missingBlobLines`) and the
/// `SyntaxRunsProvider` seam observe exactly what was written, in the 0-based blob-line
/// space the cache stores. `@MainActor` because the engine is.
@MainActor
struct DiffHighlightCacheReadTests {

  /// A multi-line Swift blob whose warmed lines carry real, keyword-bearing runs — so a
  /// non-empty `cachedRuns` result is MEANINGFUL (the query classified `struct`/`let`,
  /// not just tokenized whitespace).
  private static let swiftSource = """
    struct Foo {
      let bar = 42
      func baz() -> Int { bar }
    }

    """

  private var queryName: String {
    DiffHighlightEngine.grammarQueryName(forPath: "a.swift") ?? ""
  }

  private func warmedEngine(blobOID: String, lines: Range<Int>) async -> DiffHighlightEngine {
    let engine = DiffHighlightEngine()
    let input = HighlightBlobInput(blobOID: blobOID, utf16: DiffFixture.blob(Self.swiftSource), path: "a.swift")
    _ = await engine.styleRuns(for: input, visibleLines: lines)
    return engine
  }

  /// `grammarQueryName` resolves the swift grammar for a `.swift` path and `nil` for a
  /// path with no bundled grammar.
  @Test func grammarQueryNameResolvesByPath() {
    #expect(DiffHighlightEngine.grammarQueryName(forPath: "a.swift") == "swift")
    #expect(DiffHighlightEngine.grammarQueryName(forPath: "notes.unknownext") == nil)
  }

  /// `cachedRuns` returns non-empty, keyword-bearing runs for the warmed blob lines and
  /// `[:]` for an unknown blobOID (nothing warmed) — a pure read of what `styleRuns`
  /// merged.
  @Test func cachedRunsHitAndMiss() async {
    let engine = await warmedEngine(blobOID: "cache-read-hit", lines: 0..<4)

    let hit = engine.cachedRuns(blobOID: "cache-read-hit", queryName: queryName, blobLines: 0..<4)
    let runs = hit.values.flatMap { $0 }
    #expect(!runs.isEmpty)
    #expect(runs.contains { $0.capture.hasPrefix("keyword") })

    // Unknown blob ⇒ nothing cached.
    #expect(engine.cachedRuns(blobOID: "never-warmed", queryName: queryName, blobLines: 0..<4).isEmpty)
    // Every returned key is inside the requested range (subset semantics).
    #expect(hit.keys.allSatisfy { (0..<4).contains($0) })
  }

  /// `cachedRuns` returns only the subset of cached lines that intersect the requested
  /// range: a range past what was warmed yields `[:]`.
  @Test func cachedRunsPartialWindow() async {
    let engine = await warmedEngine(blobOID: "cache-read-partial", lines: 0..<4)
    // Lines 0..<2 were warmed and carry runs; 100..<200 was never queried.
    #expect(!engine.cachedRuns(blobOID: "cache-read-partial", queryName: queryName, blobLines: 0..<2).isEmpty)
    #expect(engine.cachedRuns(blobOID: "cache-read-partial", queryName: queryName, blobLines: 100..<200).isEmpty)
  }

  /// After warming `0..<N`, `missingBlobLines` over `0..<N` is empty (every line was
  /// queried — a token-less line is PRESENT, not missing); a not-yet-queried range is
  /// returned whole; an entirely-uncached blob reports the whole input range missing.
  @Test func missingBlobLinesCoalescing() async {
    let engine = await warmedEngine(blobOID: "cache-read-missing", lines: 0..<4)

    // Fully warmed range ⇒ nothing missing.
    #expect(engine.missingBlobLines(blobOID: "cache-read-missing", queryName: queryName, blobLines: 0..<4).isEmpty)

    // A range never queried ⇒ returned as-is.
    #expect(
      engine.missingBlobLines(blobOID: "cache-read-missing", queryName: queryName, blobLines: 4..<54) == [4..<54])

    // An entirely-uncached blob ⇒ the whole input range.
    #expect(engine.missingBlobLines(blobOID: "cold", queryName: queryName, blobLines: 0..<50) == [0..<50])

    // An empty input range is trivially fully covered.
    #expect(engine.missingBlobLines(blobOID: "cold", queryName: queryName, blobLines: 5..<5).isEmpty)
  }

  /// `SyntaxRunsProvider.live(engine)` returns the SAME runs as `cachedRuns` for a warmed
  /// line, and `.empty` returns `[]`.
  @Test func providerLiveMatchesCacheAndEmptyIsBlank() async {
    let engine = await warmedEngine(blobOID: "provider-live", lines: 0..<4)
    let name = queryName

    // Pick a warmed line that actually has runs.
    let cached = engine.cachedRuns(blobOID: "provider-live", queryName: name, blobLines: 0..<4)
    let line = cached.first { !$0.value.isEmpty }?.key ?? 0

    let live = SyntaxRunsProvider.live(engine)
    #expect(
      live.runs("provider-live", name, line)
        == engine.cachedRuns(blobOID: "provider-live", queryName: name, blobLine: line))
    #expect(!live.runs("provider-live", name, line).isEmpty)

    // A miss (unknown blob) is empty, and the stub is always empty.
    #expect(live.runs("never-warmed", name, line).isEmpty)
    #expect(SyntaxRunsProvider.empty.runs("provider-live", name, line).isEmpty)
  }
}
