import Foundation

/// The a11y-only reconstruction of the row a materialized tree line displays,
/// consumed by `DiffAXText` for its VoiceOver labels. This is the accessibility
/// bridge type — the render path never builds it (the CoreText `LineRowView`
/// draws straight off `LineSegment`); it exists only so the ported
/// `DiffCellView` label strings keep their exact shape. It carries the line
/// CONTENT the rendered projection drops.
///
/// (Renamed out of the deleted flat `DiffRow` in the Phase-13 seam swap: the old
/// `DiffRow` was the table viewer's row model and is gone; only this a11y bridge
/// survives, under a distinct name so the render layer never resurrects a flat
/// row list.)
nonisolated enum DiffAXRow: Equatable, Sendable {
  /// `"@@ -a,b +c,d @@ ctx"` header.
  case hunkHeader(anchor: Int, text: String)
  /// Unified stream line (context / addition / deletion / no-newline marker).
  case line(DiffLine)
  /// Split-view aligned pair; a `nil` side is a gap row (blank cell).
  case splitLine(pairID: Int, old: DiffLine?, new: DiffLine?)
  /// A collapsed run of unchanged lines (inter-hunk gap or long intra-hunk run).
  case expander(anchor: Int, collapsedRange: Range<Int>, hiddenCount: Int)
  /// Whole-file placeholder (binary / mode / deleted / submodule / empty).
  case placeholder(FilePlaceholder)
  /// Large-file / long-line cap: plain monospaced text, no gutter, no tint.
  case plainFallback(lineNumber: Int, text: String)
  /// An inline review-comment thread, anchored below its owner line.
  case commentThread(ReviewComment)
}
