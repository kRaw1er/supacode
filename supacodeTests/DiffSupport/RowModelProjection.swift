import Foundation

@testable import supacode

/// The row-model projection the I5 golden snapshots: a `seek(index:)` +
/// `successor` walk of the tree, one deterministic line per rendered row —
/// `(rowIndex, chunkKind, old/new, class, y, height)`. Pure model, never pixels.
/// Phase 8 extends this with the split-column projection.
@MainActor
enum RowModelProjection {
  /// One `\n`-joined line per rendered row in `mode`.
  static func rowModel(_ tree: ChunkTree, mode: DiffViewMode) -> String {
    var lines: [String] = []
    var hit = tree.seek(index: 0, mode: mode)
    while let current = hit {
      lines.append(describe(current, mode: mode))
      hit = tree.successor(of: current, mode: mode)
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func describe(_ hit: ChunkHit, mode: DiffViewMode) -> String {
    let kind: String
    let old: String
    let new: String
    let classification: String
    switch hit.chunk {
    case .widget(let widget):
      kind = widgetKind(widget.reuseKind)
      old = "-"
      new = "-"
      classification = "widget"
    case .lineSegment(let segment):
      let rows = segment.renderedRows(mode)
      let row = rows[min(hit.localRow, rows.count - 1)]
      kind = row.isMarker ? "marker" : "line"
      old = row.oldNumber.map(String.init) ?? "-"
      new = row.newNumber.map(String.init) ?? "-"
      classification = segmentClass(segment.classification)
    }
    let position = "y=\(fmt(hit.yOrigin)) h=\(fmt(hit.rowHeight))"
    return "\(hit.rowIndex) \(kind) old=\(old) new=\(new) class=\(classification) \(position)"
  }

  private static func fmt(_ value: CGFloat) -> String {
    String(format: "%.1f", Double(value))
  }

  private static func widgetKind(_ kind: WidgetReuseKind) -> String {
    switch kind {
    case .fileHeader: "fileHeader"
    case .hunkHeader: "hunkHeader"
    case .expander: "expander"
    case .commentThread: "commentThread"
    case .placeholder: "placeholder"
    case .noNewlineMarker: "noNewlineMarker"
    case .plainFallback: "plainFallback"
    }
  }

  private static func segmentClass(_ classification: SegmentClass) -> String {
    switch classification {
    case .context: "context"
    case .contextExpanded: "contextExpanded"
    case .change: "change"
    }
  }

  // MARK: - Split add/del column projection (Phase 8, I5)

  /// One `\n`-joined line per SPLIT rendered row, describing the aligned old/new
  /// COLUMNS: a present side is `L<n>` / `R<n>`; a nil side is `buffer` (the 45°
  /// empty-side hatch); the row is typed `single` for a pure-add / pure-delete pair
  /// (pierre `data-diff-type single`), `context` when both sides carry the same
  /// line, `change` when both sides differ, and `marker` for a no-newline row. Pure
  /// model, engine/theme-independent — the P1 row-model golden's split arm.
  static func splitColumnModel(_ tree: ChunkTree) -> String {
    var lines: [String] = []
    var hit = tree.seek(index: 0, mode: .split)
    while let current = hit {
      lines.append(describeSplitColumns(current))
      hit = tree.successor(of: current, mode: .split)
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func describeSplitColumns(_ hit: ChunkHit) -> String {
    switch hit.chunk {
    case .widget(let widget):
      return "\(hit.rowIndex) widget=\(widgetKind(widget.reuseKind)) old=- new=- type=widget"
    case .lineSegment(let segment):
      let rows = segment.renderedRows(.split)
      let row = rows[min(hit.localRow, rows.count - 1)]
      let old = row.oldNumber.map { "L\($0)" } ?? "buffer"
      let new = row.newNumber.map { "R\($0)" } ?? "buffer"
      let type = splitRowType(row, classification: segment.classification)
      return "\(hit.rowIndex) old=\(old) new=\(new) type=\(type)"
    }
  }

  private static func splitRowType(_ row: RenderedRow, classification: SegmentClass) -> String {
    if row.isMarker { return "marker" }
    switch classification {
    case .context, .contextExpanded:
      return "context"
    case .change:
      let hasOld = row.oldNumber != nil
      let hasNew = row.newNumber != nil
      if hasOld && hasNew { return "change" }
      return "single"  // pure-add / pure-delete pair — one column is a buffer
    }
  }
}
