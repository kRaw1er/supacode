import Foundation

/// One rendered row of a leaf, derived on demand for the row-model projection
/// (golden) and the variable-height intra-leaf walk. Purely a view over the
/// segment's intrinsic `DiffLine` numbering — nothing is stored on the tree.
nonisolated struct RenderedRow: Equatable, Sendable {
  var oldNumber: Int?
  var newNumber: Int?
  var origin: DiffLineOrigin
  var isMarker: Bool

  /// The 1-based source number this row displays on `side` (`nil` when the row has
  /// no line on that side — an unpaired split-mode buffer slot).
  func number(on side: DiffSide) -> Int? {
    switch side {
    case .old: oldNumber
    case .new: newNumber
    }
  }
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

  /// How a leaf must be cut so a widget inserted after the left half lands directly
  /// UNDER a rendered row — the shape a comment thread anchors with.
  nonisolated enum SplitPlan: Equatable, Sendable {
    /// The row is the leaf's last rendered row: insert after the whole leaf, no cut.
    case none
    /// A contiguous window cut at this offset (the cheap COW-sharing split).
    case window(offset: Int)
    /// A split-mode PAIR cut. The leaf's canonical deletions-then-additions backing
    /// makes a pair boundary non-contiguous, so each half gets its own line array.
    case rebuild(left: [DiffLine], right: [DiffLine], leftRowCount: Int)
  }

  /// Where to cut so a widget lands directly below rendered row `localRow` in `mode`.
  ///
  /// The plan is MODE-AWARE because a change block renders differently per mode: in
  /// unified the rendered row IS the window offset (del-then-add order), while in
  /// split rendered row `r` pairs `deletions[r]` with `additions[r]`, so cutting at a
  /// window offset there would tear the columns apart.
  ///
  /// O(log window) for a marker-free leaf (the `windowDeletionCount` binary search
  /// only, resolving everything else by arithmetic) — the same "never materialize the
  /// ≤maxLeafSpan projection" rule the `visibleLineRange` hot path follows. Only a
  /// leaf carrying a no-newline marker (EOF, rare) falls back to the full projection,
  /// and only an actual pair cut copies lines, which it must.
  func splitPlan(afterRenderedRow localRow: Int, mode: DiffViewMode) -> SplitPlan {
    guard localRow >= 0 else { return .none }
    let deletionCount = windowDeletionCount
    guard !windowHasNoNewlineMarker(deletionCount: deletionCount) else {
      return markerSplitPlan(afterRenderedRow: localRow, mode: mode)
    }
    // Marker-free ⇒ the rendered row index IS the row index of the mode's projection,
    // so the prefix line count is `localRow + 1` with no scan.
    let additionCount = window.count - deletionCount
    let rowCount =
      classification == .change && mode == .split ? max(deletionCount, additionCount) : window.count
    guard localRow + 1 < rowCount else { return .none }
    return plan(prefixLines: localRow + 1, leftRows: localRow + 1, deletionCount: deletionCount, mode: mode)
  }

  /// The cut that keeps `prefixLines` backing lines (and `leftRows` RENDERED rows —
  /// the two differ only when a marker row is in play) on the left. Pure arithmetic +,
  /// for a pair cut only, the line copy.
  private func plan(prefixLines: Int, leftRows: Int, deletionCount: Int, mode: DiffViewMode) -> SplitPlan {
    let prefixRows = prefixLines
    switch classification {
    case .context, .contextExpanded:
      return .window(offset: prefixRows)
    case .change:
      // Unified renders the window in order, so the prefix row count IS the offset.
      if mode == .unified { return .window(offset: prefixRows) }
      // Every deletion already sits left of the cut ⇒ the pair boundary happens to be
      // contiguous in the backing, so the cheap COW-sharing window split is exact.
      if prefixRows >= deletionCount { return .window(offset: deletionCount + prefixRows) }
      // Canonical del-then-add order makes both sides O(1) slices — no filtering.
      let low = window.lowerBound
      let deletions = lines[low..<(low + deletionCount)]
      let additions = lines[(low + deletionCount)..<window.upperBound]
      let left = Array(deletions.prefix(prefixRows)) + Array(additions.prefix(prefixRows))
      let right = Array(deletions.dropFirst(prefixRows)) + Array(additions.dropFirst(prefixRows))
      guard !left.isEmpty, !right.isEmpty else { return .none }
      return .rebuild(left: left, right: right, leftRowCount: leftRows)
    }
  }

  /// The no-newline-marker fallback: a marker row has no backing line, so the rendered
  /// index no longer equals the row index and the projection has to be walked. Rare
  /// (git emits the marker only for a side's final line), hence the O(leaf) path.
  private func markerSplitPlan(afterRenderedRow localRow: Int, mode: DiffViewMode) -> SplitPlan {
    let rows = renderedRows(mode)
    guard localRow < rows.count else { return .none }
    // Keep a marker glued to the line it belongs to: the widget goes after the marker.
    var boundary = localRow
    while boundary + 1 < rows.count, rows[boundary + 1].isMarker { boundary += 1 }
    guard boundary + 1 < rows.count else { return .none }
    let prefixLines = rows[0...boundary].count(where: { !$0.isMarker })
    guard prefixLines > 0 else { return .none }
    return plan(
      prefixLines: prefixLines, leftRows: boundary + 1, deletionCount: windowDeletionCount, mode: mode)
  }

  /// The inclusive source-number span this leaf carries on `side`, or `nil` when it
  /// carries no line on that side (an all-addition block has no old span). O(1) — the
  /// canonical del-then-add order puts each side's first / last line at a known offset,
  /// and numbers are monotonic within a leaf. Lets a line-number lookup skip a leaf
  /// without materializing its projection.
  func numberSpan(on side: DiffSide, deletionCount: Int) -> (first: Int, last: Int)? {
    let low = window.lowerBound
    let high = window.upperBound
    let range: Range<Int>
    switch classification {
    case .context, .contextExpanded:
      range = low..<high
    case .change:
      range = side == .old ? low..<(low + deletionCount) : (low + deletionCount)..<high
    }
    guard !range.isEmpty,
      let first = lines[range.lowerBound].lineNumber(on: side),
      let last = lines[range.upperBound - 1].lineNumber(on: side)
    else { return nil }
    return (first, last)
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
