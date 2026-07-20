import Foundation
import Testing

@testable import supacode

/// CAT 1 — the 1-based-line-number → 0-based blob-line window conversion the warmer
/// owns (`DiffHighlightEngine.blobWindow`). This is the ONE place the `-1` shift (the
/// engine keys / queries 0-based, the row reads 1-based) is applied; these pin it as a
/// pure function so the fix can never silently regress into the "runs land one line off
/// (or, at line 1, nowhere)" state.
struct DiffHighlightBlobWindowTests {
  /// 1-based visible line numbers → the 0-based blob-line window the engine queries.
  @Test func blobWindowShiftsOneBasedLinesToZeroBasedBlobRange() {
    #expect(DiffHighlightEngine.blobWindow(forLineNumbers: 1..<2) == 0..<1)  // line 1 → blob line 0
    #expect(DiffHighlightEngine.blobWindow(forLineNumbers: 10..<13) == 9..<12)
    #expect(DiffHighlightEngine.blobWindow(forLineNumbers: 0..<0) == 0..<0)  // empty stays empty
    // A degenerate 0-based line number clamps to 0 rather than underflowing to -1.
    #expect(DiffHighlightEngine.blobWindow(forLineNumbers: 0..<1).lowerBound == 0)
  }
}
