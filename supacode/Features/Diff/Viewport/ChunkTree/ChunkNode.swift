import Foundation

/// Red-black node colour.
nonisolated enum RBColor: Sendable {
  case red
  case black
}

/// One node of the `ChunkTree` red-black tree. In-order == document order
/// (leftmost leaf = top of file). Carries its OWN chunk summary plus the
/// aggregated `subtreeSummary` of the entire subtree rooted here — the augmented
/// aggregate that makes seek / rowCount / totalHeight O(log n) / O(1).
///
/// (CETV `TextLineStorage+Node` stores a left-only `leftSubtree{Offset,Height,
/// Count}`; we store the full `subtreeSummary` and derive the left aggregate as
/// `left?.subtreeSummary`. Equivalent, and rotations stay a two-node recompute
/// because a rotation preserves a subtree's aggregate.)
final class ChunkNode {
  let id: ChunkID
  var chunk: Chunk
  var summary: ChunkSummary  // this node's OWN chunk summary (incl. its measured deltas)
  var subtreeSummary: ChunkSummary  // aggregate of the ENTIRE subtree rooted here

  /// Sparse, leaf-only: only rows whose measured height ≠ estimate. Keyed by the
  /// local rendered-row index within the segment.
  var heightDeltas: [Int: LineHeightDelta]?
  /// Only on a maxed dense leaf (span == `maxLeafSpan`); nil otherwise.
  var checkpoints: [LayoutCheckpoint]?

  var left: ChunkNode?
  var right: ChunkNode?
  weak var parent: ChunkNode?
  var color: RBColor

  init(
    id: ChunkID,
    chunk: Chunk,
    summary: ChunkSummary,
    heightDeltas: [Int: LineHeightDelta]? = nil,
    checkpoints: [LayoutCheckpoint]? = nil,
    color: RBColor = .red
  ) {
    self.id = id
    self.chunk = chunk
    self.summary = summary
    self.subtreeSummary = summary
    self.heightDeltas = heightDeltas
    self.checkpoints = checkpoints
    self.color = color
  }

  /// Aggregate of the left subtree (CETV `leftSubtree*`), derived from the child.
  var leftSubtree: ChunkSummary { left?.subtreeSummary ?? .zero }

  /// Aggregate of the right subtree, derived from the child.
  var rightSubtree: ChunkSummary { right?.subtreeSummary ?? .zero }

  /// Recompute `subtreeSummary` from own summary + children. O(1). The single
  /// primitive every re-aggregate (insert / split / rotate / measure) leans on.
  func recomputeSubtreeSummary() {
    subtreeSummary = leftSubtree + summary + rightSubtree
  }
}
