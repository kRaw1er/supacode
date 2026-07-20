import AppKit

/// Phase 7 — the viewport side of incremental collapse/expand. The reducer owns
/// the declarative `ExpansionState` and the blob slices (`document.revealed`); THIS
/// is the imperative consumer that projects a gap's revealed slice into the tree
/// with O(log n) `insert`/`remove` and an anchored relayout (no scroll jump). It is
/// the `tree.insert(after: expanderChunk, lineSegment)` the plan's Mechanism §
/// describes — never a `[DiffRow]` rebuild, never a re-diff.
extension DiffViewportController {
  /// Reveal a gap's slice. Rebuilds the gap's rendered region O(log n) as
  /// `[head context] [shrunken expander] [tail context]` for a partial reveal, or a
  /// single `.contextExpanded` segment (expander removed) when fully revealed.
  /// `revealedLines` is the reducer's sorted `revealed[gap]`; `region` is the
  /// resolved geometry. Idempotent — safe to call on each expand with the growing
  /// revealed set. Anchored on the top-visible chunk so there is no scroll jump.
  /// Returns whether the gap was found.
  /// The gap's current nodes come from the TREE's own region index, never from ids
  /// cached out here: a re-projection mints a new tree, and a cached id list would
  /// then address unrelated nodes (or none). The index is maintained by
  /// `register` / `unregister`, so it cannot disagree with the tree it belongs to.
  @discardableResult
  func applyExpansion(gap: GapKey, region: ExpansionState.ResolvedRegion, revealedLines: [DiffLine]) -> Bool {
    let existing = tree.nodes(in: .gap(gap))
    guard let firstNode = existing.first else { return false }
    // Nothing revealed yet ⇒ leave the (full) expander in place.
    guard !revealedLines.isEmpty else { return true }

    let predecessorID = tree.inorderPredecessorNode(firstNode)?.id
    let scrollAnchor = captureScrollAnchor()
    for node in existing { tree.remove(node.id) }
    spliceGap(
      Self.expansionChunks(gap: gap, region: region, revealedLines: revealedLines, metrics: tree.metrics),
      after: predecessorID, scrollAnchor: scrollAnchor)
    return true
  }

  /// Re-hide a gap: drop its revealed segments + shrunken expander and put the full
  /// expander back. O(log n), anchored. The expander is REBUILT from the gap's own
  /// geometry rather than restored from a snapshot — one construction path (the
  /// builder's), and no second copy of the gap's state to keep in step.
  /// Returns whether the gap was expanded.
  @discardableResult
  func collapseExpansion(gap: GapKey, hiddenLines: Int, anchor: Int, range: Range<Int>) -> Bool {
    let existing = tree.nodes(in: .gap(gap))
    guard let firstNode = existing.first, existing.contains(where: { $0.chunk.lineSegment != nil }) else {
      return false  // nothing revealed — already just an expander
    }
    let predecessorID = tree.inorderPredecessorNode(firstNode)?.id
    let scrollAnchor = captureScrollAnchor()
    for node in existing { tree.remove(node.id) }
    let expander = ChunkTreeBuilder.expanderWidget(
      fileID: gap.fileID, hunkIndex: gap.hunkIndex, anchor: anchor, range: range, hidden: hiddenLines,
      ChunkTreeBuilder.Options(metrics: tree.metrics))
    spliceGap([expander], after: predecessorID, scrollAnchor: scrollAnchor)
    return true
  }

  /// Insert a gap's freshly-built chunks after `predecessor`, then re-land the scroll
  /// anchor and re-read the accessibility rows (the row count changed either way).
  private func spliceGap(_ chunks: [Chunk], after predecessor: ChunkID?, scrollAnchor: ScrollAnchor?) {
    var after = predecessor
    for chunk in chunks { after = tree.insert(chunk, after: after) }
    restoreScrollAnchor(scrollAnchor)
    axProvider?.reload()
  }

  // MARK: - Chunk construction

  /// The ordered chunks for a gap's revealed region. Fully revealed
  /// (`collapsedLines == 0`) ⇒ one `.contextExpanded` segment, no expander (the
  /// eager-slice cap means a whole-file expand's remaining lines window in on
  /// scroll, a separate mechanism). Partial ⇒ `head + shrunken expander + tail`.
  /// `revealedLines` is guaranteed non-empty by the caller.
  static func expansionChunks(
    gap: GapKey,
    region: ExpansionState.ResolvedRegion,
    revealedLines: [DiffLine],
    metrics: ChunkLayoutMetrics
  ) -> [Chunk] {
    if region.collapsedLines <= 0 {
      return segmentChunks(revealedLines, gap: gap)
    }
    let headCount = min(max(region.fromStart, 0), revealedLines.count)
    let tailCount = min(max(region.fromEnd, 0), revealedLines.count - headCount)
    let head = Array(revealedLines.prefix(headCount))
    let tail = tailCount > 0 ? Array(revealedLines.suffix(tailCount)) : []
    var chunks: [Chunk] = []
    chunks += segmentChunks(head, gap: gap)
    chunks.append(shrunkenExpander(gap: gap, hidden: region.collapsedLines, head: head, tail: tail, metrics: metrics))
    chunks += segmentChunks(tail, gap: gap)
    return chunks
  }

  /// Split a revealed run into `≤ maxLeafSpan` `.contextExpanded` leaves over a
  /// shared COW backing (mirrors `ChunkTreeBuilder.appendSegments`).
  private static func segmentChunks(_ lines: [DiffLine], gap: GapKey) -> [Chunk] {
    guard !lines.isEmpty else { return [] }
    let span = ChunkLayoutMetrics.maxLeafSpan
    var chunks: [Chunk] = []
    var low = 0
    while low < lines.count {
      let high = min(low + span, lines.count)
      chunks.append(
        .lineSegment(
          LineSegment(region: .gap(gap), lines: lines, window: low..<high, classification: .contextExpanded)))
      low = high
    }
    return chunks
  }

  /// The still-hidden expander leaf for a partial reveal — same `WidgetKey` (so the
  /// gap identity survives) with the shrunken `hidden` count and a best-effort range
  /// derived from the revealed edges.
  private static func shrunkenExpander(
    gap: GapKey, hidden: Int, head: [DiffLine], tail: [DiffLine], metrics: ChunkLayoutMetrics
  ) -> Chunk {
    let anchor = head.last?.newLineNumber ?? tail.first?.newLineNumber ?? 0
    let lower = (head.last?.newLineNumber).map { $0 + 1 } ?? anchor
    let upper = tail.first?.newLineNumber ?? (lower + hidden)
    return .widget(
      Widget(
        key: .expander(gap),
        estimatedHeight: metrics.expanderHeight,
        payload: .expander(anchor: anchor, range: lower..<max(upper, lower), hidden: hidden)
      )
    )
  }

}
