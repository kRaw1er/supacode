import Foundation
import Testing

@testable import supacode

/// Phase 4 — the two content-identity caches. Parse trees are keyed by
/// `(blobOID, queryName)` so the base blob parses ONCE across every worktree diff and
/// an appearance flip never invalidates a parse; spans add `themeGen` so a user-theme
/// swap invalidates colors without touching parse trees.
@MainActor
struct DiffHighlightCacheTests {

  /// 4.8 — the parse-tree cache key is `(blobOID, queryName)` and NOTHING else. The
  /// same blob under two `styleGeneration`s is ONE cache entry (parsed once).
  @Test func parseTreeCacheKeyedByBlobOIDNotStyle() {
    let key = ParseTreeCache.Key(blobOID: "oid-1", queryName: "swift")
    let same = ParseTreeCache.Key(blobOID: "oid-1", queryName: "swift")
    #expect(key == same)  // no styleGeneration / font / theme component to make them differ
    #expect(key.hashValue == same.hashValue)
    // Different content identity ⇒ different key.
    #expect(key != ParseTreeCache.Key(blobOID: "oid-2", queryName: "swift"))
    #expect(key != ParseTreeCache.Key(blobOID: "oid-1", queryName: "python"))
  }

  /// E 2.3 — first-existence pin: an appearance flip bumps the Phase-3 CTLine
  /// `styleGeneration` (invalidating CTLine + heights) but the parse-tree key has NO
  /// `styleGeneration` field, so the parse survives. Phase 13 owns the end-to-end.
  @Test func styleGenPreservesParseTree() {
    // A CTLine key DOES carry styleGeneration → an appearance flip is a cache miss.
    let ctLo = CTLineCache.Key(contentHash: 42, styleGeneration: 0, widthBucket: 10)
    let ctHi = CTLineCache.Key(contentHash: 42, styleGeneration: 1, widthBucket: 10)
    #expect(ctLo != ctHi)

    // The parse-tree key for the SAME blob is invariant across that flip.
    let parseA = ParseTreeCache.Key(blobOID: "oid-1", queryName: "swift")
    let parseB = ParseTreeCache.Key(blobOID: "oid-1", queryName: "swift")
    #expect(parseA == parseB)
  }

  /// 4.9 — the span cache carries `themeGen`, so bumping it is a miss for the same
  /// blob; the engine's `bumpSyntaxTheme()` advances the generation used for span
  /// keys, and the parse-tree key (no `themeGen`) is untouched.
  @Test func spanCacheInvalidatesOnSyntaxThemeGen() {
    let cache = HighlightSpanCache(capacity: 8)
    let window: [Int: [StyleRun]] = [0: [StyleRun(range: 0..<3, capture: "keyword")]]
    cache.merge(window, into: .init(blobOID: "oid-1", queryName: "swift", themeGen: 0))

    #expect(cache[.init(blobOID: "oid-1", queryName: "swift", themeGen: 0)] != nil)
    #expect(cache[.init(blobOID: "oid-1", queryName: "swift", themeGen: 1)] == nil)  // theme bump ⇒ miss

    // The engine's theme generation advances; parse-tree keys never carry it.
    let engine = DiffHighlightEngine()
    #expect(engine.syntaxThemeGen == 0)
    engine.bumpSyntaxTheme()
    #expect(engine.syntaxThemeGen == 1)
  }

  /// The span cache unions new windows into a blob's file map and evicts LRU.
  @Test func spanCacheMergesWindowsAndEvictsLRU() {
    let cache = HighlightSpanCache(capacity: 2)
    let key = HighlightSpanCache.Key(blobOID: "oid-1", queryName: "swift", themeGen: 0)
    cache.merge([0: [StyleRun(range: 0..<1, capture: "a")]], into: key)
    cache.merge([5: [StyleRun(range: 0..<1, capture: "b")]], into: key)  // unions, same entry
    let map = cache[key]
    #expect(map?[0] != nil)
    #expect(map?[5] != nil)
    #expect(cache.count == 1)

    // Overflow past capacity 2 evicts the least-recently-used blob.
    cache.merge([0: []], into: .init(blobOID: "oid-2", queryName: "swift", themeGen: 0))
    cache.merge([0: []], into: .init(blobOID: "oid-3", queryName: "swift", themeGen: 0))
    #expect(cache.count == 2)
    #expect(cache[.init(blobOID: "oid-1", queryName: "swift", themeGen: 0)] == nil)  // evicted
  }

  // MARK: - Perf guard: merge is O(window), NOT O(accumulated)

  /// The scroll-fps regression: `merge` did `var map = store[key]; map[line] = …` which
  /// COW-copied the WHOLE accumulated map on the first mutation — O(lines-visited) per
  /// merge, so scrolling a big file's window across N lines was O(N²) on the main
  /// actor. Merging in place keeps it O(window). 40k single-line windows into one key
  /// is a few ms at O(window); the old O(N²) is ~8×10^8 element copies (seconds).
  @Test func mergeIsConstantPerWindowNotLinearInAccumulatedSize() {
    let cache = HighlightSpanCache(capacity: 4)
    let key = HighlightSpanCache.Key(blobOID: "oid-1", queryName: "swift", themeGen: 0)
    let run = [StyleRun(range: 0..<1, capture: "keyword")]
    let elapsed = ContinuousClock().measure {
      for line in 0..<40_000 { cache.merge([line: run], into: key) }
    }
    let millis = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    #expect(cache[key]?.count == 40_000, "merge lost accumulated lines — the union is wrong")
    #expect(
      millis < 1_000, "merging 40k windows took \(millis)ms — `merge` COW-copies the whole accumulated map (O(n²))")
  }
}
