import Foundation
import SwiftTreeSitter
import Testing

@testable import supacode

/// Phase 4 — the diff-indirection bucketer: `NamedRange` (absolute UTF-16 file
/// offsets) → line-relative `StyleRun`s. Pure over `DiffHighlightEngine.bucket`, so
/// it needs no parser: the whole point is that neon hands back UTF-16 directly and
/// the bucketer must NOT re-divide it (C10). Three of these are the failing-first
/// regressions against the shipping bugs — RED on the old `SyntaxHighlighter`, GREEN
/// on the new engine.
struct DiffHighlightBucketTests {

  /// 🔴 4.1 — the single highest-value correction (C10). `NamedRange.range` is
  /// ALREADY UTF-16, so a `keyword` at UTF-16 `6..<9` must bucket to `6..<9` — NOT
  /// `3..<4`, which the shipping `SyntaxHighlighter.swift:109-110` produces by
  /// dividing an already-UTF-16 offset a SECOND time.
  @Test func bucketMapsNamedRangeWithoutDoubleHalving() {
    let named = [DiffFixture.namedRange("keyword", NSRange(location: 6, length: 3))]
    let byLine = DiffHighlightEngine.bucket(named, lineStarts: [0], textLength: 20, window: 0..<1)

    #expect(byLine[0] == [StyleRun(range: 6..<9, capture: "keyword")])
    // Explicit anti-regression on the double-`/2` result.
    #expect(byLine[0]?.first?.range != 3..<4)
  }

  /// 🔴 4.2 — both sides highlighted. The old path set `highlight.syntaxNew` only
  /// and `DiffCellView.swift:407` forced the old side `[]`. Over a fake old/new blob
  /// pair the OLD side must produce non-empty runs (not `[]`).
  @Test func bothSidesHighlighted() {
    // old blob "let x = 1" — `let` keyword at 0..<3 on line 0.
    let oldSide = DiffHighlightEngine.bucket(
      [DiffFixture.namedRange("keyword", NSRange(location: 0, length: 3))],
      lineStarts: [0], textLength: 9, window: 0..<1)
    // new blob "let y = 2" — `let` keyword at 0..<3 on line 0.
    let newSide = DiffHighlightEngine.bucket(
      [DiffFixture.namedRange("keyword", NSRange(location: 0, length: 3))],
      lineStarts: [0], textLength: 9, window: 0..<1)

    #expect(oldSide[0]?.isEmpty == false)  // regression: old side is NOT forced []
    #expect(newSide[0]?.isEmpty == false)
    #expect(oldSide[0] == [StyleRun(range: 0..<3, capture: "keyword")])
  }

  /// 4.4 — a capture spanning two lines buckets into a line-relative run on EACH
  /// line, clipped to line bounds.
  @Test func multiLineSpanSplitsAcrossLines() {
    // Two lines: [0,5) and [5,10). A span 3..<8 crosses the boundary at 5.
    let named = [DiffFixture.namedRange("string", NSRange(location: 3, length: 5))]
    let byLine = DiffHighlightEngine.bucket(named, lineStarts: [0, 5], textLength: 10, window: 0..<2)

    #expect(byLine[0] == [StyleRun(range: 3..<5, capture: "string")])
    #expect(byLine[1] == [StyleRun(range: 0..<3, capture: "string")])
  }

  /// 4.5 — only lines inside the passed `window` produce runs (windowed query). A
  /// span covering lines 0 AND 1 with a window of just line 1 yields a run on line 1
  /// only.
  @Test func bucketWindowsToVisibleLines() {
    let named = [DiffFixture.namedRange("comment", NSRange(location: 1, length: 7))]
    let byLine = DiffHighlightEngine.bucket(named, lineStarts: [0, 5], textLength: 10, window: 1..<2)

    #expect(byLine[0] == nil)  // line 0 is outside the window
    #expect(byLine[1] == [StyleRun(range: 0..<3, capture: "comment")])
  }

  /// D §2/§4 — extends 4.1 with Unicode. A `中文` (CJK, 2 UTF-16 units) span at
  /// `4..<6` must land at `4..<6`; an astral `𝕏` (2 UTF-16 units) at `0..<2` must
  /// land at `0..<2`. The double-`/2` would land on the space + half of 中 (`2..<3`)
  /// and on a lone high surrogate (`0..<1`).
  @Test func synBucketNoDoubleHalveOnCJKAndAstral() {
    // "foo 中文" → UTF-16 indices: f0 o1 o2 space3 中4 文5 → 中文 is 4..<6.
    let cjk = DiffHighlightEngine.bucket(
      [DiffFixture.namedRange("type", NSRange(location: 4, length: 2))],
      lineStarts: [0], textLength: 6, window: 0..<1)
    #expect(cjk[0] == [StyleRun(range: 4..<6, capture: "type")])
    #expect(cjk[0]?.first?.range != 2..<3)  // the double-`/2` landing

    // "𝕏 = 1" → 𝕏 is a surrogate pair at 0..<2.
    let astral = DiffHighlightEngine.bucket(
      [DiffFixture.namedRange("variable", NSRange(location: 0, length: 2))],
      lineStarts: [0], textLength: 6, window: 0..<1)
    #expect(astral[0] == [StyleRun(range: 0..<2, capture: "variable")])
    #expect(astral[0]?.first?.range != 0..<1)  // lone high surrogate
  }

  /// A zero-length capture and an empty line-start table are dropped, not crashed.
  @Test func bucketDropsEmptyAndDegenerate() {
    #expect(DiffHighlightEngine.bucket([], lineStarts: [0], textLength: 5, window: 0..<1).isEmpty)
    #expect(
      DiffHighlightEngine.bucket(
        [DiffFixture.namedRange("keyword", NSRange(location: 2, length: 0))],
        lineStarts: [0], textLength: 5, window: 0..<1
      ).isEmpty)
    #expect(
      DiffHighlightEngine.bucket(
        [DiffFixture.namedRange("keyword", NSRange(location: 0, length: 3))],
        lineStarts: [], textLength: 5, window: 0..<1
      ).isEmpty)
  }
}
