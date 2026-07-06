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
  @discardableResult
  func applyExpansion(gap: GapKey, region: ExpansionState.ResolvedRegion, revealedLines: [DiffLine]) -> Bool {
    // The gap's current first node: a tracked revealed segment (later expand) or the
    // expander widget (first expand).
    let trackedFirst = expansionNodes[gap]?.first.flatMap { tree.nodesByID[$0] }
    let expanderNode = tree.widgetNode(for: .expander(gap))
    guard let firstNode = trackedFirst ?? expanderNode else { return false }
    // Snapshot the full expander once, so `collapseExpansion` can restore it.
    if originalExpanders[gap] == nil, let expanderNode { originalExpanders[gap] = expanderNode.chunk }

    // Nothing revealed yet ⇒ leave the (full) expander in place.
    guard !revealedLines.isEmpty else { return true }

    let predecessorID = tree.inorderPredecessorNode(firstNode)?.id
    let fileID = gapFileID(near: firstNode)
    let scrollAnchor = captureScrollAnchor()

    // Remove the gap's current nodes (tracked segments + shrunken expander on a
    // later expand; the full expander on the first expand).
    if let tracked = expansionNodes[gap] {
      for id in tracked { tree.remove(id) }
    } else if let expanderNode {
      tree.remove(expanderNode.id)
    }
    expansionNodes[gap] = nil

    // Rebuild the gap region and splice it in after the (stable) predecessor.
    let chunks = Self.expansionChunks(
      gap: gap, region: region, revealedLines: revealedLines, fileID: fileID, metrics: tree.metrics)
    var inserted: [ChunkID] = []
    var after = predecessorID
    for chunk in chunks {
      let id = tree.insert(chunk, after: after)
      after = id
      inserted.append(id)
    }
    expansionNodes[gap] = inserted
    restoreScrollAnchor(scrollAnchor)
    axProvider?.reload()  // revealed lines grew the tree → re-read the now-visible rows
    return true
  }

  /// Re-hide a gap: remove its revealed segments + shrunken expander and restore the
  /// full expander leaf. O(log n), anchored. Returns whether the gap was expanded.
  @discardableResult
  func collapseExpansion(gap: GapKey) -> Bool {
    guard let tracked = expansionNodes[gap], let firstID = tracked.first,
      let firstNode = tree.nodesByID[firstID]
    else { return false }
    let predecessorID = tree.inorderPredecessorNode(firstNode)?.id
    let scrollAnchor = captureScrollAnchor()
    for id in tracked { tree.remove(id) }
    expansionNodes[gap] = nil
    if let expander = originalExpanders[gap] {
      tree.insert(expander, after: predecessorID)
    }
    originalExpanders[gap] = nil
    restoreScrollAnchor(scrollAnchor)
    axProvider?.reload()  // re-hiding the gap shrank the tree back to one expander row
    return true
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
    fileID: FileID,
    metrics: ChunkLayoutMetrics
  ) -> [Chunk] {
    let hunkID = HunkID(fileID: fileID, index: gap.hunkIndex)
    if region.collapsedLines <= 0 {
      return segmentChunks(revealedLines, hunkID: hunkID)
    }
    let headCount = min(max(region.fromStart, 0), revealedLines.count)
    let tailCount = min(max(region.fromEnd, 0), revealedLines.count - headCount)
    let head = Array(revealedLines.prefix(headCount))
    let tail = tailCount > 0 ? Array(revealedLines.suffix(tailCount)) : []
    var chunks: [Chunk] = []
    chunks += segmentChunks(head, hunkID: hunkID)
    chunks.append(shrunkenExpander(gap: gap, hidden: region.collapsedLines, head: head, tail: tail, metrics: metrics))
    chunks += segmentChunks(tail, hunkID: hunkID)
    return chunks
  }

  /// Split a revealed run into `≤ maxLeafSpan` `.contextExpanded` leaves over a
  /// shared COW backing (mirrors `ChunkTreeBuilder.appendSegments`).
  private static func segmentChunks(_ lines: [DiffLine], hunkID: HunkID) -> [Chunk] {
    guard !lines.isEmpty else { return [] }
    let span = ChunkLayoutMetrics.maxLeafSpan
    var chunks: [Chunk] = []
    var low = 0
    while low < lines.count {
      let high = min(low + span, lines.count)
      chunks.append(
        .lineSegment(LineSegment(hunkID: hunkID, lines: lines, window: low..<high, classification: .contextExpanded)))
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

  /// The `FileID` a gap's revealed context belongs to — read off the nearest
  /// preceding chunk that carries one (the hunk above / the file header). Falls back
  /// to a synthetic id (only reached on a degenerate tree with no such neighbor).
  private func gapFileID(near node: ChunkNode) -> FileID {
    var cursor: ChunkNode? = node
    while let current = cursor {
      if let fileID = Self.fileID(of: current.chunk) { return fileID }
      cursor = tree.inorderPredecessorNode(current)
    }
    cursor = tree.inorderSuccessorNode(node)
    while let current = cursor {
      if let fileID = Self.fileID(of: current.chunk) { return fileID }
      cursor = tree.inorderSuccessorNode(current)
    }
    return "expansion"
  }

  private static func fileID(of chunk: Chunk) -> FileID? {
    switch chunk {
    case .lineSegment(let segment):
      return segment.hunkID.fileID
    case .widget(let widget):
      switch widget.key {
      case .fileHeader(let fileID): return fileID
      case .hunkHeader(let hunkID): return hunkID.fileID
      case .plainFallback(let fileID, _): return fileID
      case .placeholder(let fileID): return fileID
      case .noNewlineMarker(let hunkID, _): return hunkID.fileID
      case .expander, .commentThread: return nil
      }
    }
  }
}
