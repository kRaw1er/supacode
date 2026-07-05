import Foundation

@testable import supacode

/// Structural invariant checker for `ChunkTree`. Returns `[]` when every red-black
/// invariant and every aggregate invariant holds; otherwise a list of human
/// descriptions. Drives the Phase-1 property tests.
@MainActor
enum ChunkTreeInvariants {
  /// (1) root black, (2) no red node has a red child, (3) equal black-height on
  /// every root→nil path, (4) each node's `subtreeSummary` == left+own+right,
  /// (5) Σ node summaries == root aggregate (count + height, both modes).
  static func check(_ tree: ChunkTree) -> [String] {
    var issues: [String] = []
    guard let root = tree.root else { return issues }
    if root.color != .black { issues.append("root is not black") }
    _ = blackHeight(root, issues: &issues)
    checkAggregate(tree, root: root, issues: &issues)
    return issues
  }

  private static func blackHeight(_ node: ChunkNode?, issues: inout [String]) -> Int {
    guard let node else { return 1 }  // a nil leaf is black
    if node.color == .red {
      if node.left?.color == .red || node.right?.color == .red {
        issues.append("red-red violation at \(node.id.raw)")
      }
    }
    let expected = node.leftSubtree + node.summary + node.rightSubtree
    if expected != node.subtreeSummary {
      issues.append("stale subtreeSummary at \(node.id.raw)")
    }
    if let left = node.left, left.parent !== node {
      issues.append("broken left parent pointer at \(node.id.raw)")
    }
    if let right = node.right, right.parent !== node {
      issues.append("broken right parent pointer at \(node.id.raw)")
    }
    let leftHeight = blackHeight(node.left, issues: &issues)
    let rightHeight = blackHeight(node.right, issues: &issues)
    if leftHeight != rightHeight {
      issues.append("black-height mismatch at \(node.id.raw): \(leftHeight) vs \(rightHeight)")
    }
    return leftHeight + (node.color == .black ? 1 : 0)
  }

  private static func checkAggregate(_ tree: ChunkTree, root: ChunkNode, issues: inout [String]) {
    let sum = tree.inorderNodes().reduce(ChunkSummary.zero) { $0 + $1.summary }
    if sum != root.subtreeSummary {
      issues.append("Σ node summaries \(sum) != root aggregate \(root.subtreeSummary)")
    }
  }
}
