import Foundation

// MARK: - Node construction & registration

extension ChunkTree {
  func allocID() -> ChunkID {
    defer { nextRaw += 1 }
    return ChunkID(raw: nextRaw)
  }

  func makeNode(for chunk: Chunk, heightDeltas: [Int: LineHeightDelta]?) -> ChunkNode {
    let summary = leafSummary(for: chunk, heightDeltas: heightDeltas)
    return ChunkNode(id: allocID(), chunk: chunk, summary: summary, heightDeltas: heightDeltas, color: .red)
  }

  /// The dual-mode summary of a leaf: base estimate + Σ measured deltas.
  func leafSummary(for chunk: Chunk, heightDeltas: [Int: LineHeightDelta]?) -> ChunkSummary {
    var summary = chunk.baseSummary(metrics: metrics)
    if let deltas = heightDeltas, !deltas.isEmpty {
      summary.unifiedMeasuredDelta = deltas.values.reduce(0) { $0 + $1.unified }
      summary.splitMeasuredDelta = deltas.values.reduce(0) { $0 + $1.split }
    }
    return summary
  }

  /// Index the node for O(1) lookup, register a file header for file-nav, and
  /// index any widget by its per-instance `WidgetKey` (Phase 6 model + measured-
  /// height resolution).
  func register(_ node: ChunkNode) {
    nodesByID[node.id] = node
    if case .widget(let widget) = node.chunk {
      widgetNodes[widget.key] = node.id
      if case .fileHeader(let fileID) = widget.key {
        fileHeaderNodes[fileID] = node.id
      }
    }
  }
}

// MARK: - BST link & traversal

extension ChunkTree {
  /// Link `node` as the in-order successor of `after` (`nil` → prepend). Pure BST
  /// link; the caller runs `insertFixup` + re-aggregate.
  func bstInsertAsSuccessor(_ node: ChunkNode, after id: ChunkID?) {
    guard let root else {
      self.setRoot(node)
      return
    }
    if let id, let anchor = nodesByID[id] {
      if let anchorRight = anchor.right {
        let successor = leftmost(anchorRight)
        successor.left = node
        node.parent = successor
      } else {
        anchor.right = node
        node.parent = anchor
      }
    } else {
      let head = leftmost(root)
      head.left = node
      node.parent = head
    }
  }

  func setRoot(_ node: ChunkNode?) {
    updateRoot(node)
    node?.parent = nil
  }

  func leftmost(_ node: ChunkNode) -> ChunkNode {
    var current = node
    while let next = current.left { current = next }
    return current
  }

  /// The in-order successor node (parent-pointer walk).
  func inorderSuccessorNode(_ node: ChunkNode) -> ChunkNode? {
    if let right = node.right { return leftmost(right) }
    var current = node
    var parent = node.parent
    while let ancestor = parent, current === ancestor.right {
      current = ancestor
      parent = ancestor.parent
    }
    return parent
  }

  func appendInorder(_ node: ChunkNode?, into out: inout [Chunk]) {
    guard let node else { return }
    appendInorder(node.left, into: &out)
    out.append(node.chunk)
    appendInorder(node.right, into: &out)
  }

  func appendInorderNodes(_ node: ChunkNode?, into out: inout [ChunkNode]) {
    guard let node else { return }
    appendInorderNodes(node.left, into: &out)
    out.append(node)
    appendInorderNodes(node.right, into: &out)
  }
}

// MARK: - Re-aggregate & rank

extension ChunkTree {
  /// Recompute `subtreeSummary` from `node` up to the root — touches the root
  /// path only (siblings untouched). O(log n). This is our `metaFixup`.
  func reaggregatePath(from node: ChunkNode?) {
    var current = node
    while let cursor = current {
      cursor.recomputeSubtreeSummary()
      current = cursor.parent
    }
  }

  /// The node's own start (rendered index, y) in `mode` — a rank query up the
  /// parent chain. O(log n).
  func rank(of node: ChunkNode, mode: DiffViewMode) -> (index: Int, yOffset: CGFloat) {
    var index = node.leftSubtree.count(mode)
    var yOffset = node.leftSubtree.height(mode)
    var current = node
    while let parent = current.parent {
      if current === parent.right {
        index += parent.leftSubtree.count(mode) + parent.summary.count(mode)
        yOffset += parent.leftSubtree.height(mode) + parent.summary.height(mode)
      }
      current = parent
    }
    return (index, yOffset)
  }
}

// MARK: - Red-black rotations & fixup (CETV blueprint)

extension ChunkTree {
  func color(of node: ChunkNode?) -> RBColor { node?.color ?? .black }

  /// Left rotation about `pivot`. After the pointer swap, the two involved nodes'
  /// aggregates are recomputed bottom-up (`pivot` first, then the promoted
  /// `raised`) — a rotation preserves a subtree's aggregate, so ancestors stay valid.
  func rotateLeft(_ pivot: ChunkNode) {
    guard let raised = pivot.right else { return }
    pivot.right = raised.left
    raised.left?.parent = pivot
    raised.parent = pivot.parent
    if pivot.parent == nil {
      updateRoot(raised)
    } else if pivot === pivot.parent?.left {
      pivot.parent?.left = raised
    } else {
      pivot.parent?.right = raised
    }
    raised.left = pivot
    pivot.parent = raised
    pivot.recomputeSubtreeSummary()
    raised.recomputeSubtreeSummary()
  }

  /// Right rotation about `pivot` (mirror of `rotateLeft`).
  func rotateRight(_ pivot: ChunkNode) {
    guard let raised = pivot.left else { return }
    pivot.left = raised.right
    raised.right?.parent = pivot
    raised.parent = pivot.parent
    if pivot.parent == nil {
      updateRoot(raised)
    } else if pivot === pivot.parent?.right {
      pivot.parent?.right = raised
    } else {
      pivot.parent?.left = raised
    }
    raised.right = pivot
    pivot.parent = raised
    pivot.recomputeSubtreeSummary()
    raised.recomputeSubtreeSummary()
  }

  /// Restore red-black invariants after a red-node insert (CLRS / CETV `insertFixup`).
  func insertFixup(_ node: ChunkNode) {
    var current = node
    while color(of: current.parent) == .red, let parent = current.parent, let grandparent = parent.parent {
      if parent === grandparent.left {
        current = fixupInsertLeft(current, parent: parent, grandparent: grandparent)
      } else {
        current = fixupInsertRight(current, parent: parent, grandparent: grandparent)
      }
    }
    root?.color = .black
  }

  private func fixupInsertLeft(_ start: ChunkNode, parent: ChunkNode, grandparent: ChunkNode) -> ChunkNode {
    let uncle = grandparent.right
    if color(of: uncle) == .red {
      parent.color = .black
      uncle?.color = .black
      grandparent.color = .red
      return grandparent
    }
    var node = start
    if node === parent.right {
      node = parent
      rotateLeft(node)
    }
    node.parent?.color = .black
    grandparent.color = .red
    rotateRight(grandparent)
    return node
  }

  private func fixupInsertRight(_ start: ChunkNode, parent: ChunkNode, grandparent: ChunkNode) -> ChunkNode {
    let uncle = grandparent.left
    if color(of: uncle) == .red {
      parent.color = .black
      uncle?.color = .black
      grandparent.color = .red
      return grandparent
    }
    var node = start
    if node === parent.left {
      node = parent
      rotateRight(node)
    }
    node.parent?.color = .black
    grandparent.color = .red
    rotateLeft(grandparent)
    return node
  }
}

// MARK: - Split mechanics

extension ChunkTree {
  /// Shrink the existing node to the left window and produce the right node.
  func performSplit(node: ChunkNode, segment: LineSegment, low: Int, high: Int, offset: Int) -> ChunkNode {
    let leftSegment = LineSegment(
      hunkID: segment.hunkID,
      lines: segment.lines,
      window: low..<(low + offset),
      classification: segment.classification
    )
    let rightSegment = LineSegment(
      hunkID: segment.hunkID,
      lines: segment.lines,
      window: (low + offset)..<high,
      classification: segment.classification
    )
    let (leftDeltas, rightDeltas) = partitionDeltas(node.heightDeltas, at: offset)
    let (leftCheckpoints, rightCheckpoints) = partitionCheckpoints(node.checkpoints, at: offset)

    node.chunk = .lineSegment(leftSegment)
    node.heightDeltas = leftDeltas
    node.checkpoints = leftCheckpoints
    node.summary = leafSummary(for: node.chunk, heightDeltas: leftDeltas)

    let rightNode = ChunkNode(
      id: allocID(),
      chunk: .lineSegment(rightSegment),
      summary: leafSummary(for: .lineSegment(rightSegment), heightDeltas: rightDeltas),
      heightDeltas: rightDeltas,
      checkpoints: rightCheckpoints,
      color: .red
    )
    return rightNode
  }

  /// Partition sparse deltas at `offset`: `< offset` stay left, `>= offset` move
  /// right re-based by `−offset`.
  func partitionDeltas(
    _ deltas: [Int: LineHeightDelta]?,
    at offset: Int
  ) -> (left: [Int: LineHeightDelta]?, right: [Int: LineHeightDelta]?) {
    guard let deltas, !deltas.isEmpty else { return (nil, nil) }
    var left: [Int: LineHeightDelta] = [:]
    var right: [Int: LineHeightDelta] = [:]
    for (index, delta) in deltas {
      if index < offset { left[index] = delta } else { right[index - offset] = delta }
    }
    return (left.isEmpty ? nil : left, right.isEmpty ? nil : right)
  }

  /// Partition checkpoints at `offset`, re-basing the right side by `−offset`.
  func partitionCheckpoints(
    _ checkpoints: [LayoutCheckpoint]?,
    at offset: Int
  ) -> (left: [LayoutCheckpoint]?, right: [LayoutCheckpoint]?) {
    guard let checkpoints, !checkpoints.isEmpty else { return (nil, nil) }
    var left: [LayoutCheckpoint] = []
    var right: [LayoutCheckpoint] = []
    for checkpoint in checkpoints {
      if checkpoint.localLine < offset {
        left.append(checkpoint)
      } else {
        right.append(
          LayoutCheckpoint(
            localLine: checkpoint.localLine - offset,
            unifiedTop: checkpoint.unifiedTop,
            splitTop: checkpoint.splitTop
          )
        )
      }
    }
    return (left.isEmpty ? nil : left, right.isEmpty ? nil : right)
  }
}

// MARK: - Hit resolution

extension ChunkTree {
  /// Resolve a full `ChunkHit` at a node whose own-row start is `(startIndex, startY)`.
  func resolveHit(
    _ node: ChunkNode,
    startIndex: Int,
    startY: CGFloat,
    local: ChunkTreeLocalTarget,
    mode: DiffViewMode
  ) -> ChunkHit {
    let resolved = resolveRow(node, local: local, mode: mode)
    return ChunkHit(
      id: node.id,
      chunk: node.chunk,
      rowIndex: startIndex + resolved.localRow,
      localRow: resolved.localRow,
      yOrigin: startY + resolved.rowY,
      rowHeight: resolved.rowHeight
    )
  }

  /// A `ChunkHit` for a specific local row of a node (used by successor / file-nav).
  func makeHit(for node: ChunkNode, localRow: Int, mode: DiffViewMode) -> ChunkHit {
    let start = rank(of: node, mode: mode)
    return resolveHit(node, startIndex: start.index, startY: start.yOffset, local: .index(localRow), mode: mode)
  }

  /// Resolve a within-leaf row for an index or y target.
  func resolveRow(_ node: ChunkNode, local: ChunkTreeLocalTarget, mode: DiffViewMode) -> RowResolution {
    if node.chunk.widget != nil {
      return RowResolution(localRow: 0, rowY: 0, rowHeight: node.summary.height(mode))
    }
    let count = max(node.summary.count(mode), 1)
    let lineHeight = metrics.lineHeight
    if node.heightDeltas?.isEmpty ?? true {
      switch local {
      case .index(let target):
        let row = min(max(target, 0), count - 1)
        return RowResolution(localRow: row, rowY: CGFloat(row) * lineHeight, rowHeight: lineHeight)
      case .offset(let target):
        let row = min(max(Int((target / lineHeight).rounded(.down)), 0), count - 1)
        return RowResolution(localRow: row, rowY: CGFloat(row) * lineHeight, rowHeight: lineHeight)
      }
    }
    return resolveVariableRow(node, local: local, mode: mode, count: count)
  }

  /// Variable-height intra-leaf walk (bounded by `maxLeafSpan`), optionally
  /// resumed from the nearest `LayoutCheckpoint`.
  func resolveVariableRow(
    _ node: ChunkNode,
    local: ChunkTreeLocalTarget,
    mode: DiffViewMode,
    count: Int
  ) -> RowResolution {
    let deltas = node.heightDeltas ?? [:]
    let lineHeight = metrics.lineHeight
    func height(_ row: Int) -> CGFloat { lineHeight + (deltas[row]?.value(mode) ?? 0) }

    var resume = checkpointResume(node, local: local, mode: mode)
    var row = resume.row
    switch local {
    case .index(let target):
      let clamped = min(max(target, 0), count - 1)
      while row < clamped {
        resume.yOffset += height(row)
        row += 1
      }
      return RowResolution(localRow: row, rowY: resume.yOffset, rowHeight: height(row))
    case .offset(let target):
      while row < count - 1 && resume.yOffset + height(row) <= target {
        resume.yOffset += height(row)
        row += 1
      }
      return RowResolution(localRow: row, rowY: resume.yOffset, rowHeight: height(row))
    }
  }

  /// The nearest checkpoint at-or-before the target (binary search), or `(0, 0)`.
  private func checkpointResume(
    _ node: ChunkNode,
    local: ChunkTreeLocalTarget,
    mode: DiffViewMode
  ) -> (row: Int, yOffset: CGFloat) {
    guard let checkpoints = node.checkpoints, !checkpoints.isEmpty else { return (0, 0) }
    var best: (row: Int, yOffset: CGFloat) = (0, 0)
    for checkpoint in checkpoints {
      switch local {
      case .index(let target) where checkpoint.localLine <= target:
        best = (checkpoint.localLine, checkpoint.top(mode))
      case .offset(let target) where checkpoint.top(mode) <= target:
        best = (checkpoint.localLine, checkpoint.top(mode))
      default:
        continue
      }
    }
    return best
  }
}
