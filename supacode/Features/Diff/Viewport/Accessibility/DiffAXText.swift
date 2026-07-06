import Foundation

/// The VoiceOver string logic for the diff viewer, moved **verbatim** out of the
/// deleted `DiffCellView.configureAccessibility` / `axLabel` / `lineLabel` /
/// `commentAnchor` (Phase 12 — a recycled view republishing role/label on every
/// `configure` is the pool-coupled model we reject). A caseless `enum` (CLAUDE.md:
/// no free functions); pure, so it is unit-tested in isolation (`DiffAXTextTests`)
/// against the ported strings. Consumed by `DiffAXProvider`, which reconstructs the
/// `DiffRow` a materialized tree row displays and hands it here for the label.
///
/// pierre's diff body has **zero ARIA** (nothing to copy) — every row is greenfield
/// against Apple's model; only the strings port from the (now legacy) table cell.
enum DiffAXText {
  /// The spoken label for a `DiffRow`. Line rows read "<origin> line <n>: <content>";
  /// split rows name each side; comment threads read the anchored range + body.
  /// (Ported from `DiffCellView.axLabel(for:mode:)`.)
  static func label(for row: DiffAXRow, mode: DiffViewMode) -> String {
    switch row {
    case .line(let line):
      return lineLabel(line)
    case .splitLine(_, let old, let new):
      var parts: [String] = []
      if let old { parts.append("old, \(lineLabel(old))") }
      if let new { parts.append("new, \(lineLabel(new))") }
      return parts.isEmpty ? "blank line" : parts.joined(separator: ", ")
    case .plainFallback(let number, let text):
      return "line \(number): \(text)"
    case .placeholder(let placeholder):
      return placeholderText(placeholder)
    case .commentThread(let comment):
      let sideWord = comment.side == .old ? "old" : "new"
      let range =
        comment.startLine == comment.endLine
        ? "\(comment.startLine)" : "\(comment.startLine) to \(comment.endLine)"
      let orphan = comment.orphaned ? "Orphaned — original line no longer present. " : ""
      return "\(orphan)Comment on \(sideWord) line \(range): \(comment.body)"
    case .hunkHeader(_, let text):
      return "Hunk header, \(text)"
    case .expander(_, _, let hiddenCount):
      return "Show \(hiddenCount) hidden line\(hiddenCount == 1 ? "" : "s")"
    }
  }

  /// One line's spoken label. (Ported from `DiffCellView.lineLabel`.)
  private static func lineLabel(_ line: DiffLine) -> String {
    let origin: String
    switch line.origin {
    case .addition: origin = "added"
    case .deletion: origin = "removed"
    case .context: origin = "context"
    case .noNewlineMarker: return line.content
    }
    if let number = line.newLineNumber ?? line.oldLineNumber {
      return "\(origin) line \(number): \(line.content)"
    }
    return "\(origin): \(line.content)"
  }

  /// The `(side, line)` the gutter "+" would target for a line/split row, or nil
  /// for a gap / marker cell. Unified deletions anchor on the old side; additions
  /// and context on the new side. Split rows prefer the new side when present.
  /// (Ported from `DiffCellView.commentAnchor(for:)`.)
  static func commentAnchor(for row: DiffAXRow) -> (side: DiffSide, line: Int)? {
    switch row {
    case .line(let line):
      guard line.origin != .noNewlineMarker else { return nil }
      if line.origin == .deletion, let old = line.oldLineNumber { return (.old, old) }
      if let new = line.newLineNumber { return (.new, new) }
      if let old = line.oldLineNumber { return (.old, old) }
      return nil
    case .splitLine(_, let old, let new):
      if let new, new.origin != .noNewlineMarker, let line = new.newLineNumber { return (.new, line) }
      if let old, old.origin != .noNewlineMarker, let line = old.oldLineNumber { return (.old, line) }
      return nil
    default:
      return nil
    }
  }

  /// The spoken text for a whole-file placeholder. (Ported from
  /// `DiffCellView.placeholderText`; the render layer keeps its own copy for
  /// drawing so the two stay decoupled.)
  static func placeholderText(_ placeholder: FilePlaceholder) -> String {
    switch placeholder {
    case .binaryFile: return "Binary file not shown"
    case .deletedFile: return "File deleted"
    case .addedEmpty: return "New empty file"
    case .noChanges: return "No changes"
    case .modeChangeOnly(let oldMode, let newMode):
      return oldMode.isEmpty || newMode.isEmpty ? "File mode changed" : "File mode changed \(oldMode) → \(newMode)"
    case .submodule(let oldSHA, let newSHA):
      return oldSHA.isEmpty || newSHA.isEmpty ? "Submodule changed" : "Submodule \(oldSHA) → \(newSHA)"
    case .imageCompare: return "Image file — before and after compare"
    case .conflict: return "Merge conflict"
    }
  }

  /// The spoken label for a file-header widget row. **Net-new** — pierre / the old
  /// table renderer had no file-header a11y (file headers weren't `DiffRow`s), so
  /// this is greenfield against the resolved `FileHeaderWidget.Model` the Files
  /// rotor hops between. Reads "File <path>, <status>[, N added, M removed]".
  static func fileHeaderLabel(_ model: FileHeaderWidget.Model) -> String {
    var parts: [String] = ["File \(model.path)", model.statusText]
    if model.addedLines > 0 || model.removedLines > 0 {
      parts.append("\(model.addedLines) added, \(model.removedLines) removed")
    }
    return parts.joined(separator: ", ")
  }
}
