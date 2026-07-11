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

  /// The FIRST rendered row in `mode` — the same value as `renderedRows(mode).first`
  /// but WITHOUT building the whole ≤maxLeafSpan array (the leaf's canonical
  /// deletions-then-additions order makes it O(1) for the common case). The scroll
  /// anchor keys off this every place, so building the full array there was an
  /// O(leaf)-per-frame cost.
  func firstRenderedRow(_ mode: DiffViewMode) -> RenderedRow? {
    switch classification {
    case .context, .contextExpanded:
      guard let line = windowedLines.first else { return nil }
      return RenderedRow(
        oldNumber: line.oldLineNumber, newNumber: line.newLineNumber, origin: .context, isMarker: false)
    case .change:
      // Lines are canonicalized deletions-then-additions, so `firstDel` is O(1).
      let firstDel = windowedLines.first { $0.origin == .deletion }
      let firstAdd = windowedLines.first { $0.origin == .addition }
      if mode == .unified {
        guard let line = firstDel ?? firstAdd else { return nil }
        return RenderedRow(
          oldNumber: line.oldLineNumber, newNumber: line.newLineNumber, origin: line.origin, isMarker: false)
      }
      guard firstDel != nil || firstAdd != nil else { return nil }
      return RenderedRow(
        oldNumber: firstDel?.oldLineNumber, newNumber: firstAdd?.newLineNumber,
        origin: firstAdd != nil ? .addition : .deletion, isMarker: false)
    }
  }

  /// The number of deletion rows in the window — the `.change` window is canonicalized
  /// deletions-then-additions (`ChunkTreeBuilder.appendChange`), so this is a **binary
  /// search** for the first addition: O(log window), NOT the O(window) `windowDeletions`
  /// filter. `0` for a context leaf (no deletion/addition split there).
  var windowDeletionCount: Int {
    guard classification == .change else { return 0 }
    var low = window.lowerBound
    var high = window.upperBound
    while low < high {
      let mid = low + (high - low) / 2
      if lines[mid].origin == .deletion { low = mid + 1 } else { high = mid }
    }
    return low - window.lowerBound
  }

  /// Whether the window carries a no-newline marker — which inserts an EXTRA rendered
  /// row and so breaks the 1:1 rendered-row ↔ window-offset mapping the O(1) number
  /// resolver relies on. Git emits "\ No newline at end of file" ONLY for a side's
  /// FINAL content line, which in del-then-add canonical order is the last deletion
  /// and/or the last window line — so this probes just those O(1) positions instead of
  /// scanning the whole ≤maxLeafSpan window. A leaf that trips it falls back to the
  /// full `renderedRows` projection (rare — EOF only).
  func windowHasNoNewlineMarker(deletionCount: Int) -> Bool {
    guard !window.isEmpty else { return false }
    if lines[window.upperBound - 1].noNewlineAtEof { return true }
    if classification == .change, deletionCount > 0, deletionCount < window.count,
      lines[window.lowerBound + deletionCount - 1].noNewlineAtEof
    {
      return true
    }
    return false
  }

  /// The `(old, new)` 1-based source numbers a rendered row displays, resolved in O(1)
  /// from the leaf's intrinsic `DiffLine` numbering WITHOUT building the whole
  /// ≤maxLeafSpan `RenderedRow` array (the dominant per-frame `visibleLineRange` cost).
  /// Valid ONLY for a marker-free leaf (`windowHasNoNewlineMarker == false`), where the
  /// rendered-row index equals the window offset. `deletionCount` is the caller-memoized
  /// `windowDeletionCount`. The number *ranges* this feeds are monotonic per side, so a
  /// min/max accumulation over the visible rows is exact even though markers are skipped
  /// (a marker duplicates its parent row's numbers).
  func lineNumbers(atRenderedRow localRow: Int, mode: DiffViewMode, deletionCount: Int) -> (old: Int?, new: Int?) {
    switch classification {
    case .context, .contextExpanded:
      let line = windowLine(at: localRow)
      return (line.oldLineNumber, line.newLineNumber)
    case .change:
      // Unified: rendered order == window order (del-then-add), so the row IS the window line.
      if mode == .unified {
        let line = windowLine(at: localRow)
        return (line.oldLineNumber, line.newLineNumber)
      }
      // Split: rendered row `i` pairs deletion[i] (old column) with addition[i] (new column).
      let old = localRow < deletionCount ? windowLine(at: localRow).oldLineNumber : nil
      let addOffset = deletionCount + localRow
      let new = addOffset < window.count ? windowLine(at: addOffset).newLineNumber : nil
      return (old, new)
    }
  }

  /// Perf spy (mirrors `LineRowView.projectCount` / `CTLineCache.buildCount`): total
  /// `renderedRows` array builds — a full O(leaf) materialization of a ≤maxLeafSpan leaf.
  /// The `visibleLineRange` hot path resolves numbers in O(1) and must NOT grow this
  /// (only the rare no-newline-marker fallback may); `DiffVisibleLineRangeTests` pins that
  /// a marker-free scroll builds ZERO full leaves.
  nonisolated(unsafe) static var renderedRowsBuildCount = 0

  /// The ordered rendered rows in `mode`. `count == baseSummary().count(mode)`
  /// by construction. For the golden projection + the variable-height walk.
  func renderedRows(_ mode: DiffViewMode) -> [RenderedRow] {
    Self.renderedRowsBuildCount += 1
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
