import Foundation

/// One rendered row of a leaf, derived on demand for the row-model projection
/// (golden) and the variable-height intra-leaf walk. Purely a view over the
/// segment's intrinsic `DiffLine` numbering — nothing is stored on the tree.
nonisolated struct RenderedRow: Equatable, Sendable {
  var oldNumber: Int?
  var newNumber: Int?
  var origin: DiffLineOrigin
  var isMarker: Bool
}

extension LineSegment {
  /// The window line at a 0-based offset (`0` == the leaf's first line). Use this
  /// instead of subscripting `windowedLines`, which keeps the original indices.
  func windowLine(at offset: Int) -> DiffLine { lines[window.lowerBound + offset] }

  /// Deletions in the window, in git order (deletions precede additions).
  var windowDeletions: [DiffLine] { windowedLines.filter { $0.origin == .deletion } }
  /// Additions in the window, in git order.
  var windowAdditions: [DiffLine] { windowedLines.filter { $0.origin == .addition } }

  /// The no-newline metadata-row counts this segment contributes, per pierre
  /// `getNoNewlineMetadataLineCounts`: unified shows one per flagged SIDE; split
  /// shares a single row when both sides of an aligned pair are flagged.
  func noNewlineCounts() -> (unified: Int, split: Int) {
    switch classification {
    case .context, .contextExpanded:
      let flagged = windowedLines.filter(\.noNewlineAtEof).count
      return (flagged, flagged)  // context is 1:1, so a marker is shared
    case .change:
      let dels = windowDeletions
      let adds = windowAdditions
      let unified = dels.filter(\.noNewlineAtEof).count + adds.filter(\.noNewlineAtEof).count
      var split = 0
      for index in 0..<max(dels.count, adds.count) {
        let oldFlagged = index < dels.count && dels[index].noNewlineAtEof
        let newFlagged = index < adds.count && adds[index].noNewlineAtEof
        if oldFlagged || newFlagged { split += 1 }
      }
      return (unified, split)
    }
  }

  /// The dual-mode base summary (counts + estimate heights). Measured deltas are
  /// layered on by the tree from `heightDeltas`; this is the estimate seed only.
  func baseSummary(metrics: ChunkLayoutMetrics) -> ChunkSummary {
    let (noNewlineUnified, noNewlineSplit) = noNewlineCounts()
    let unifiedCount: Int
    let splitCount: Int
    switch classification {
    case .context, .contextExpanded:
      let base = window.count
      unifiedCount = base + noNewlineUnified
      splitCount = base + noNewlineSplit
    case .change:
      let dels = windowDeletions.count
      let adds = windowAdditions.count
      unifiedCount = dels + adds + noNewlineUnified
      splitCount = max(dels, adds) + noNewlineSplit
    }
    return ChunkSummary(
      unifiedCount: unifiedCount,
      splitCount: splitCount,
      unifiedEstHeight: CGFloat(unifiedCount) * metrics.lineHeight,
      splitEstHeight: CGFloat(splitCount) * metrics.lineHeight
    )
  }

  /// The ordered rendered rows in `mode`. `count == baseSummary().count(mode)`
  /// by construction. For the golden projection + the variable-height walk.
  func renderedRows(_ mode: DiffViewMode) -> [RenderedRow] {
    switch classification {
    case .context, .contextExpanded:
      return contextRows()
    case .change:
      return mode == .unified ? unifiedChangeRows() : splitChangeRows()
    }
  }

  private func contextRows() -> [RenderedRow] {
    var rows: [RenderedRow] = []
    for line in windowedLines {
      rows.append(
        RenderedRow(oldNumber: line.oldLineNumber, newNumber: line.newLineNumber, origin: .context, isMarker: false)
      )
      if line.noNewlineAtEof {
        rows.append(
          RenderedRow(
            oldNumber: line.oldLineNumber,
            newNumber: line.newLineNumber,
            origin: .noNewlineMarker,
            isMarker: true
          )
        )
      }
    }
    return rows
  }

  private func unifiedChangeRows() -> [RenderedRow] {
    var rows: [RenderedRow] = []
    for line in windowDeletions + windowAdditions {
      rows.append(
        RenderedRow(oldNumber: line.oldLineNumber, newNumber: line.newLineNumber, origin: line.origin, isMarker: false)
      )
      if line.noNewlineAtEof {
        rows.append(
          RenderedRow(
            oldNumber: line.oldLineNumber,
            newNumber: line.newLineNumber,
            origin: .noNewlineMarker,
            isMarker: true
          )
        )
      }
    }
    return rows
  }

  private func splitChangeRows() -> [RenderedRow] {
    let dels = windowDeletions
    let adds = windowAdditions
    var rows: [RenderedRow] = []
    for index in 0..<max(dels.count, adds.count) {
      let old = index < dels.count ? dels[index] : nil
      let new = index < adds.count ? adds[index] : nil
      let origin: DiffLineOrigin = new != nil ? .addition : .deletion
      rows.append(
        RenderedRow(oldNumber: old?.oldLineNumber, newNumber: new?.newLineNumber, origin: origin, isMarker: false)
      )
      if (old?.noNewlineAtEof ?? false) || (new?.noNewlineAtEof ?? false) {
        rows.append(
          RenderedRow(
            oldNumber: old?.oldLineNumber,
            newNumber: new?.newLineNumber,
            origin: .noNewlineMarker,
            isMarker: true
          )
        )
      }
    }
    return rows
  }
}

extension Chunk {
  /// The dual-mode base summary for this leaf (segment counts × lineHeight, or a
  /// widget's single row at its `estimatedHeight`). Measured deltas are layered
  /// on separately by the tree.
  func baseSummary(metrics: ChunkLayoutMetrics) -> ChunkSummary {
    switch self {
    case .lineSegment(let segment):
      return segment.baseSummary(metrics: metrics)
    case .widget(let widget):
      return ChunkSummary(
        unifiedCount: 1,
        splitCount: 1,
        unifiedEstHeight: widget.estimatedHeight,
        splitEstHeight: widget.estimatedHeight
      )
    }
  }

  /// Rendered rows for the row-model projection. A widget is a single row.
  func renderedRows(_ mode: DiffViewMode) -> [RenderedRow] {
    switch self {
    case .lineSegment(let segment):
      return segment.renderedRows(mode)
    case .widget:
      return [RenderedRow(oldNumber: nil, newNumber: nil, origin: .context, isMarker: false)]
    }
  }
}
