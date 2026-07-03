import Foundation

/// One rendered row of the virtualized diff viewer. `Hashable` compares FULL
/// content (used by `CollectionDifference` for the incremental row delta); the
/// separate coarse `id: RowID` is a *logical* identity keyed on line numbers,
/// stable across content edits, and used by the scroll anchor + reload-in-place.
enum DiffRow: Equatable, Identifiable, Sendable {
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
  /// Phase 5 stub — renders nothing yet.
  case commentThread(id: UUID)

  /// Coarse *logical* identity (line numbers / anchors), stable across content
  /// edits so the scroll anchor re-lands the same line after an agent edit.
  var id: RowID {
    switch self {
    case .hunkHeader(let anchor, _):
      return .hunkHeader(anchor)
    case .line(let line):
      return .line(old: line.oldLineNumber, new: line.newLineNumber, origin: line.origin)
    case .splitLine(let pairID, _, _):
      return .splitLine(pairID)
    case .expander(let anchor, _, _):
      return .expander(anchor)
    case .placeholder(let placeholder):
      return .placeholder(placeholder)
    case .plainFallback(let lineNumber, _):
      return .plainFallback(lineNumber)
    case .commentThread(let uuid):
      return .commentThread(uuid)
    }
  }
}

/// The coarse logical identity of a `DiffRow`. Deliberately excludes the mutable
/// text content so a content-only edit keeps the same `RowID` (anchor survives)
/// while `DiffRow`'s full-content `==` still flags it for reload-in-place.
enum RowID: Hashable, Sendable {
  case hunkHeader(Int)
  case line(old: Int?, new: Int?, origin: DiffLineOrigin)
  case splitLine(Int)
  case expander(Int)
  case placeholder(FilePlaceholder)
  case plainFallback(Int)
  case commentThread(UUID)
}

/// A whole-file placeholder shown in place of a line list when there is no
/// textual diff to render.
enum FilePlaceholder: Hashable, Sendable {
  case binaryFile
  case deletedFile
  case addedEmpty
  case noChanges
  case modeChangeOnly(oldMode: String, newMode: String)
  case submodule(oldSHA: String, newSHA: String)
}
