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
}
