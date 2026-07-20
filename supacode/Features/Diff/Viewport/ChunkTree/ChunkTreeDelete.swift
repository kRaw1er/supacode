import CoreGraphics
import Foundation

// MARK: - Red-black delete (CLRS) + file-subtree replacement (Phase 9)

extension ChunkTree {
  /// Remove a node by id, restoring red-black + aggregate invariants. O(log n).
  /// The streaming consumer's incremental re-diff leans on this to splice out a
  /// changed file's sub-tree in place (unchanged siblings — and their measured
  /// heights — are never touched).
  @discardableResult
  func remove(_ id: ChunkID) -> Bool {
    guard let node = nodesByID[id] else { return false }
    removeNode(node)
    unregister(node)
    return true
  }

  /// The in-order predecessor node (parent-pointer walk), mirror of
  /// `inorderSuccessorNode`. `nil` at the first node.
  func inorderPredecessorNode(_ node: ChunkNode) -> ChunkNode? {
    if let left = node.left { return rightmost(left) }
    var current = node
    var parent = node.parent
    while let ancestor = parent, current === ancestor.left {
      current = ancestor
      parent = ancestor.parent
    }
    return parent
  }

  func rightmost(_ node: ChunkNode) -> ChunkNode {
    var current = node
    while let next = current.right { current = next }
    return current
  }

  /// The document-order node span of one file: its leading `.widget(fileHeader)`
  /// followed by every chunk up to (but excluding) the next file's header. Returns
  /// the in-order predecessor id (the insertion anchor for a replacement) and the
  /// ids that belong to the file, or `nil` when the file has no header node.
  func fileNodeSpan(fileID: FileID) -> (predecessor: ChunkID?, nodes: [ChunkID])? {
    guard let headerID = fileHeaderNodes[fileID], let header = nodesByID[headerID] else { return nil }
    let predecessor = inorderPredecessorNode(header)?.id
    var nodes: [ChunkID] = [headerID]
    var cursor = inorderSuccessorNode(header)
    while let node = cursor {
      if case .widget(let widget) = node.chunk, case .fileHeader = widget.key { break }
      nodes.append(node.id)
      cursor = inorderSuccessorNode(node)
    }
    return (predecessor, nodes)
  }

  /// The absolute y-offset of a node's own first row in `mode`, or `nil` when the
  /// id is not present. The consumer's below-fold-vs-intersecting decision.
  func nodeYOffset(_ id: ChunkID, mode: DiffViewMode) -> CGFloat? {
    guard let node = nodesByID[id] else { return nil }
    return rank(of: node, mode: mode).yOffset
  }

  /// Re-key a file's leading `.widget(fileHeader)` node in place (pierre
  /// `updateItemId`): the SAME node instance now answers to `new`, so a rename
  /// reuses the element rather than dropping + recreating it. Returns the reused
  /// header id (the anchor for re-splicing the renamed body), or `nil`.
  @discardableResult
  func retargetFileHeader(from old: FileID, to new: FileID) -> ChunkID? {
    guard let headerID = fileHeaderNodes[old], let node = nodesByID[headerID],
      let widget = node.chunk.widget, case .fileHeader = widget.key
    else { return nil }
    node.chunk = .widget(
      Widget(key: .fileHeader(fileID: new), estimatedHeight: widget.estimatedHeight, payload: .fileHeader(fileID: new)))
    fileHeaderNodes[old] = nil
    fileHeaderNodes[new] = headerID
    widgetNodes[.fileHeader(fileID: old)] = nil
    widgetNodes[.fileHeader(fileID: new)] = headerID
    return headerID
  }

  /// Insert `chunks` in document order after `anchor` (`nil` prepends), returning
  /// the last inserted id (the next insertion anchor). The multi-chunk splice
  /// primitive the consumer uses to materialize a file over a placeholder run.
  @discardableResult
  func insertChunks(_ chunks: [Chunk], after anchor: ChunkID?) -> ChunkID? {
    var after = anchor
    for chunk in chunks {
      after = insert(chunk, after: after)
    }
    return after
  }

  // MARK: - Internals

  private func unregister(_ node: ChunkNode) {
    nodesByID[node.id] = nil
    if case .widget(let widget) = node.chunk {
      if widgetNodes[widget.key] == node.id {
        widgetNodes[widget.key] = nil
      }
      if case .fileHeader(let fileID) = widget.key, fileHeaderNodes[fileID] == node.id {
        fileHeaderNodes[fileID] = nil
      }
    }
  }

  /// Standard BST/RB delete with explicit `xParent` tracking (x may be nil).
  /// Aggregates are re-established by reaggregating the structural-change path
  /// BEFORE `deleteFixup` (whose rotations self-maintain the two pivots).
  private func removeNode(_ target: ChunkNode) {
    var mover = target
    var moverOriginalColor = mover.color
    let child: ChunkNode?
    let childParent: ChunkNode?

    if target.left == nil {
      child = target.right
      childParent = target.parent
      transplant(target, with: target.right)
    } else if target.right == nil {
      child = target.left
      childParent = target.parent
      transplant(target, with: target.left)
    } else {
      mover = leftmost(target.right!)  // in-order successor
      moverOriginalColor = mover.color
      child = mover.right
      if mover.parent === target {
        childParent = mover
        child?.parent = mover
      } else {
        childParent = mover.parent
        transplant(mover, with: mover.right)
        mover.right = target.right
        mover.right?.parent = mover
      }
      transplant(target, with: mover)
      mover.left = target.left
      mover.left?.parent = mover
      mover.color = target.color
    }

    // Every node whose subtree changed lies on the root-path from `childParent`
    // (which sits inside the moved sub-tree in the two-child case).
    reaggregatePath(from: childParent)

    if moverOriginalColor == .black {
      deleteFixup(child, parent: childParent)
    }
    root?.color = .black

    target.left = nil
    target.right = nil
    target.parent = nil
  }

  /// Replace the subtree rooted at `removed` with `replacement` (CLRS
  /// `RB-TRANSPLANT`), fixing the parent pointers. `replacement` may be nil.
  private func transplant(_ removed: ChunkNode, with replacement: ChunkNode?) {
    if removed.parent == nil {
      updateRoot(replacement)
    } else if removed === removed.parent?.left {
      removed.parent?.left = replacement
    } else {
      removed.parent?.right = replacement
    }
    replacement?.parent = removed.parent
  }

  /// Restore red-black invariants after removing a black node (CLRS
  /// `RB-DELETE-FIXUP`), tracking `parent` explicitly because the doubly-black
  /// cursor can be nil. Recolors change no aggregate; rotations self-maintain
  /// their two pivots.
  private func deleteFixup(_ start: ChunkNode?, parent: ChunkNode?) {
    var cursor = start
    var cursorParent = parent
    while cursor !== root, color(of: cursor) == .black {
      guard let parent = cursorParent else { break }
      if cursor === parent.left {
        cursor = deleteFixupLeft(cursor, parent: parent, updatedParent: &cursorParent)
      } else {
        cursor = deleteFixupRight(cursor, parent: parent, updatedParent: &cursorParent)
      }
    }
    cursor?.color = .black
  }

  private func deleteFixupLeft(
    _ cursor: ChunkNode?, parent: ChunkNode, updatedParent childParent: inout ChunkNode?
  ) -> ChunkNode? {
    var sibling = parent.right
    if color(of: sibling) == .red {
      sibling?.color = .black
      parent.color = .red
      rotateLeft(parent)
      sibling = parent.right
    }
    if color(of: sibling?.left) == .black, color(of: sibling?.right) == .black {
      sibling?.color = .red
      childParent = parent.parent
      return parent
    }
    if color(of: sibling?.right) == .black {
      sibling?.left?.color = .black
      sibling?.color = .red
      if let sibling { rotateRight(sibling) }
      sibling = parent.right
    }
    sibling?.color = parent.color
    parent.color = .black
    sibling?.right?.color = .black
    rotateLeft(parent)
    childParent = nil
    return root
  }

  private func deleteFixupRight(
    _ cursor: ChunkNode?, parent: ChunkNode, updatedParent childParent: inout ChunkNode?
  ) -> ChunkNode? {
    var sibling = parent.left
    if color(of: sibling) == .red {
      sibling?.color = .black
      parent.color = .red
      rotateRight(parent)
      sibling = parent.left
    }
    if color(of: sibling?.right) == .black, color(of: sibling?.left) == .black {
      sibling?.color = .red
      childParent = parent.parent
      return parent
    }
    if color(of: sibling?.left) == .black {
      sibling?.right?.color = .black
      sibling?.color = .red
      if let sibling { rotateLeft(sibling) }
      sibling = parent.left
    }
    sibling?.color = parent.color
    parent.color = .black
    sibling?.left?.color = .black
    rotateRight(parent)
    childParent = nil
    return root
  }
}
