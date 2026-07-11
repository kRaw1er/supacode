import Foundation

/// The size gate that decides — BEFORE any tree-sitter client is built or any parse
/// runs — whether a diff is highlighted at all. Evaluated on the counts the diff
/// layer already has (`git_patch_line_stats`, Phase 9's `unified/splitLineCount`),
/// so a deep hunk in a huge file never triggers a multi-second **contiguous** parse
/// (neon windows the *query* but `processLocation` forces a contiguous parse from
/// byte 0 up to the deepest queried location — the crux). Pure / static — no free
/// functions, and `nonisolated` so the reducer's load-gate and the controller warmer
/// can call it off the main actor.
nonisolated enum DiffHighlightPolicy {
  /// Pierre parity: `packages/diffs/src/constants.ts:60`
  /// `DEFAULT_TOKENIZE_MAX_LENGTH = 100_000`, applied on BOTH sides
  /// (`DiffHunksRenderer.ts:1757-1766` `isDiffMassive`).
  static let maxChangedLinesPerSide = 100_000
  /// Absolute blob-size gate pierre lacks (~5MB UTF-8 ≈ 2.5M UTF-16 code units).
  static let maxBlobUTF16 = 2_500_000
  /// Pierre `DiffHunksRenderer.ts:369` `tokenizeMaxLineLength = 1000`: a single line
  /// longer than this is not tokenized.
  static let maxLineLength = 1_000

  /// `true` ⇒ render plain (no client built, no parse). Mirror of pierre
  /// `isDiffMassive` but on BOTH sides, plus the absolute blob-size gate and the
  /// per-line cap. `longestLineUTF16` defaults to `0` so a caller that only has file
  /// counts still gets the file-level gate.
  static func isPlain(
    oldChangedLines: Int,
    newChangedLines: Int,
    oldBlobUTF16: Int,
    newBlobUTF16: Int,
    longestLineUTF16: Int = 0
  ) -> Bool {
    if max(oldChangedLines, newChangedLines) > maxChangedLinesPerSide { return true }
    if max(oldBlobUTF16, newBlobUTF16) > maxBlobUTF16 { return true }
    if longestLineUTF16 > maxLineLength { return true }
    return false
  }

  /// Per-line skip (pierre `tokenizeMaxLineLength`): a line longer than `maxLineLength`
  /// UTF-16 code units is rendered plain even inside an otherwise-highlighted file.
  static func isLineTooLong(_ utf16Length: Int) -> Bool {
    utf16Length > maxLineLength
  }
}
