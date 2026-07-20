import Foundation
import Testing

@testable import supacode

/// Phase 4 — the size gate (`DiffHighlightPolicy`). Reads COUNTS the diff layer
/// already has, evaluated BEFORE any client is built, so a deep hunk in a huge file
/// never triggers the contiguous parse (neon windows the query but `processLocation`
/// forces a contiguous parse from byte 0 — windowing does NOT make a deep hunk cheap).
struct DiffHighlightPolicyTests {

  /// 4.7 — every gate. Pierre parity: `max(oldChanged, newChanged) > 100_000` → plain
  /// (BOTH sides); an absolute blob-size cap (2.5M UTF-16); a per-line cap (1000).
  @Test func sizeGateTripsBeforeParse() {
    // Small diff → highlight.
    #expect(
      DiffHighlightPolicy.isPlain(oldChangedLines: 40, newChangedLines: 50, oldBlobUTF16: 10_000, newBlobUTF16: 12_000)
        == false)

    // Massive on the NEW side only → plain (both-sides `max`).
    #expect(
      DiffHighlightPolicy.isPlain(oldChangedLines: 10, newChangedLines: 100_001, oldBlobUTF16: 0, newBlobUTF16: 0)
        == true)
    // Massive on the OLD side only → plain.
    #expect(
      DiffHighlightPolicy.isPlain(oldChangedLines: 100_001, newChangedLines: 10, oldBlobUTF16: 0, newBlobUTF16: 0)
        == true)
    // Exactly at the cap → still highlight (strictly greater trips).
    #expect(
      DiffHighlightPolicy.isPlain(oldChangedLines: 100_000, newChangedLines: 100_000, oldBlobUTF16: 0, newBlobUTF16: 0)
        == false)

    // Over the absolute blob-size cap (2.5M UTF-16) on either side → plain.
    #expect(
      DiffHighlightPolicy.isPlain(oldChangedLines: 1, newChangedLines: 1, oldBlobUTF16: 2_500_001, newBlobUTF16: 0)
        == true)
    #expect(
      DiffHighlightPolicy.isPlain(oldChangedLines: 1, newChangedLines: 1, oldBlobUTF16: 0, newBlobUTF16: 2_500_001)
        == true)

    // A single over-long line (>1000 UTF-16) trips the per-line gate.
    #expect(
      DiffHighlightPolicy.isPlain(
        oldChangedLines: 1, newChangedLines: 1, oldBlobUTF16: 100, newBlobUTF16: 100, longestLineUTF16: 1_001) == true)
    #expect(
      DiffHighlightPolicy.isPlain(
        oldChangedLines: 1, newChangedLines: 1, oldBlobUTF16: 100, newBlobUTF16: 100, longestLineUTF16: 1_000) == false)
  }

  /// The per-line skip helper (pierre `tokenizeMaxLineLength`).
  @Test func perLineSkipAtThousand() {
    #expect(DiffHighlightPolicy.isLineTooLong(1_000) == false)
    #expect(DiffHighlightPolicy.isLineTooLong(1_001) == true)
  }
}
