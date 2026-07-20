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
      ChunkTreeBuilder.gapChunks(gap: gap, region: region, revealedLines: revealedLines, metrics: tree.metrics),
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
}
