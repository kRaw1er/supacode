import Foundation

/// The fully-changed-huge-file gate (brainstorm §Round-3 gap #1): a lockfile /
/// minified bundle / SQL dump where collapse saves nothing must still render —
/// virtualized, O(viewport) — but WITHOUT allocating a `TreeSitterClient` /
/// span-cache entry (highlight) or running an O(changed-lines) token diff
/// (word-diff), and WITHOUT a single 2MB minified line blowing the CTLine byte
/// ceiling. The decision is surfaced in the file header (never a silent drop) and
/// logged once.
///
/// Keys off flags the data layer already sets (no new git work): `isLargeFileCapped`
/// (byteCap / lineCap) + `hasLongLines` (longLineCap) plus the per-side changed-line
/// count and the longest rendered line. Pure / static, so it composes with the
/// per-side `DiffHighlightPolicy` (100k) / `WordDiffPolicy` (1000) gates it unifies
/// (pierre `maxLineDiffLength` / `tokenizeMaxLineLength` default 1000).
nonisolated enum LargeFileRenderPolicy {
  /// `> maxChangedLinesForHighlight` changed lines on a side ⇒ plain (pierre
  /// `DEFAULT_TOKENIZE_MAX_LENGTH` / `isDiffMassive`, `DiffHighlightPolicy` 100k).
  static let maxChangedLinesForHighlight = 100_000
  /// `> maxChangedLinesForWordDiff` changed lines on a side ⇒ no word-diff (pierre
  /// `maxLineDiffLength`, `WordDiffPolicy` 1000).
  static let maxChangedLinesForWordDiff = 1_000
  /// A line longer than this (UTF-16) ⇒ plain (pierre `tokenizeMaxLineLength`
  /// 1000; also what protects the CTLine byte ceiling from a 2MB minified line).
  static let maxLineLength = 1_000

  struct Decision: Equatable, Sendable {
    /// Run the Phase-4 neon highlight pass at all.
    var highlight: Bool
    /// Run the Phase-5 intra-line word-diff pass at all.
    var wordDiff: Bool
    /// The header affordance to show (never a silent drop), or `nil` when the file
    /// renders fully.
    var bannerKey: BannerKey?
  }

  /// Which header affordance a gated file shows. `→ localized header text` via
  /// `headerText`.
  enum BannerKey: Equatable, Sendable {
    /// Everything off — the biggest files (capped / >100k changed / a >1000-char
    /// line). Plain monospaced, still virtualized.
    case plain
    /// Highlight on, word-diff off (>1000 changed lines or long lines present).
    case wordDiffOff
    /// Highlight off but word-diff kept (reserved for a highlight-only gate).
    case highlightingOff

    /// The (English) header affordance text. Surfaced in the diff-tab header so the
    /// user always knows a render feature was dropped for size.
    var headerText: String {
      switch self {
      case .plain: "Large file — highlighting and word diff off"
      case .wordDiffOff: "Large file — word diff off"
      case .highlightingOff: "Large file — highlighting off"
      }
    }
  }

  /// Decide the render features for a file. `changedLines` is the PER-SIDE count
  /// (`max(removedLines, addedLines)`) so the thresholds line up 1:1 with
  /// `DiffHighlightPolicy` / `WordDiffPolicy`; `maxLineLength` is the longest
  /// rendered line's UTF-16 length.
  static func decide(file: FileChange, changedLines: Int, maxLineLength: Int) -> Decision {
    if file.isLargeFileCapped || changedLines > maxChangedLinesForHighlight || maxLineLength > Self.maxLineLength {
      // Everything off — still virtualized ⇒ O(viewport).
      return Decision(highlight: false, wordDiff: false, bannerKey: .plain)
    }
    if changedLines > maxChangedLinesForWordDiff || file.hasLongLines {
      return Decision(highlight: true, wordDiff: false, bannerKey: .wordDiffOff)
    }
    return Decision(highlight: true, wordDiff: true, bannerKey: nil)
  }
}
