import Foundation
import Testing

@testable import supacode

/// CAT 1 — the blob-line ↔ 1-based-line-number conversion the highlight client owns.
/// This is the ONE place the `+1` skew (engine buckets 0-based, the row reads 1-based)
/// is corrected; these pin it as pure functions so the fix can never silently regress
/// into the "runs land one line off (or, at line 1, nowhere)" state.
struct DiffHighlightClientConversionTests {
  /// 1-based visible line numbers → the 0-based blob-line window the engine queries.
  @Test func blobWindowShiftsOneBasedLinesToZeroBasedBlobRange() {
    #expect(DiffHighlightClient.blobWindow(forLineNumbers: 1..<2) == 0..<1)  // line 1 → blob line 0
    #expect(DiffHighlightClient.blobWindow(forLineNumbers: 10..<13) == 9..<12)
    #expect(DiffHighlightClient.blobWindow(forLineNumbers: 0..<0) == 0..<0)  // empty stays empty
    // A degenerate 0-based line number clamps to 0 rather than underflowing to -1.
    #expect(DiffHighlightClient.blobWindow(forLineNumbers: 0..<1).lowerBound == 0)
  }

  /// 0-based blob-line keys (engine output) → 1-based source line numbers. Line-0 runs
  /// (which a 1-based row lookup NEVER fetched pre-fix) must surface at key 1.
  @Test func lineNumberKeyedShiftsBlobKeysToLineNumbers() {
    let byBlobLine: [Int: [StyleRun]] = [
      0: [StyleRun(range: 0..<3, capture: "keyword")],
      4: [StyleRun(range: 2..<8, capture: "string")],
    ]
    let byLineNumber = DiffHighlightClient.lineNumberKeyed(byBlobLine)
    #expect(byLineNumber[1] == [StyleRun(range: 0..<3, capture: "keyword")])  // blob line 0 → line 1
    #expect(byLineNumber[5] == [StyleRun(range: 2..<8, capture: "string")])
    #expect(byLineNumber[0] == nil)  // nothing keyed 0 any more — that was the bug
    #expect(byLineNumber.count == byBlobLine.count)  // a pure re-key, no runs lost/merged
  }

  /// The round trip is identity on the line coordinate: query window `N..<M`, the
  /// engine answers on blob lines `(N-1)...(M-2)`, re-keying restores `N...(M-1)`.
  @Test func windowAndKeyingRoundTripOnLineCoordinate() {
    let lines = 10..<13
    let blob = DiffHighlightClient.blobWindow(forLineNumbers: lines)  // 9..<12
    // Simulate the engine bucketing one run per queried blob line.
    let engineOut = Dictionary(uniqueKeysWithValues: blob.map { ($0, [StyleRun(range: 0..<1, capture: "x")]) })
    let rekeyed = DiffHighlightClient.lineNumberKeyed(engineOut)
    #expect(Set(rekeyed.keys) == Set(lines))  // keys land back exactly on the queried line numbers
  }
}
