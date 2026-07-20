import Foundation
import Testing

@testable import supacode

/// Deep variable-height geometry for the `ChunkTree` intra-leaf walk — the native
/// analog of pierre's sparse layout checkpoints
/// (`virtualizedFileDiffEstimatedHeights.test.ts` / `sparseLayoutCheckpoints.test.ts`
/// "builds layout checkpoints lazily for deep geometry lookups").
///
/// DOCUMENTED DIVERGENCE from pierre's lazy checkpoint cache. Pierre lazily builds
/// `cache.checkpoints` on the FIRST deep `getLinePosition` — checkpoints are ABSENT
/// before the deep lookup and PRESENT after. Our stack does NOT lazily build them:
///
///  - `ChunkTreeBuilder` span-caps every dense run at `ChunkLayoutMetrics.maxLeafSpan`
///    (5_000) STRUCTURALLY at build time (`appendSegments`), so a deep seek is
///    O(log n) tree navigation to a `≤ maxLeafSpan`-row leaf plus a bounded intra-leaf
///    linear walk.
///  - `seek` only READS `node.checkpoints` (`checkpointResume`); it never writes them.
///  - `setMeasuredHeight` writes `heightDeltas`, not checkpoints.
///  - `split` only PARTITIONS pre-existing checkpoints (`partitionCheckpoints`).
///
/// So `node.checkpoints` stays `nil` in production. The pierre "checkpoints PRESENT
/// after a deep lookup" assertion is therefore inapplicable. What we CAN pin — and
/// what actually guards the same user-visible invariant pierre's checkpoints protect —
/// is that a deep variable-height seek resolves to the EXACT linear-walk geometry
/// (`deepVariableHeightSeekMatchesLinearWalk`) and that the seek stays a pure read
/// (`deepSeekDoesNotLazilyBuildCheckpoints`).
@MainActor
struct DiffLazyCheckpointTests {
  private let metrics = ChunkLayoutMetrics.production  // lineHeight 20

  /// Sparse "wrapped" rule mirroring soft-wrapped source lines: every 7th row is
  /// taller than the estimate, dual-mode (a wide unified row and a narrow split row
  /// wrap by different amounts).
  private func isWrapped(_ row: Int) -> Bool { row % 7 == 0 }
  private func wrapDelta(_ mode: DiffViewMode) -> CGFloat { mode == .unified ? 13 : 5 }

  /// The cumulative top of row `upTo` computed by an INDEPENDENT linear walk — the
  /// oracle the tree's O(log n) deep seek must reproduce exactly.
  private func linearTop(upTo: Int, mode: DiffViewMode) -> CGFloat {
    var yOffset: CGFloat = 0
    for row in 0..<upTo {
      yOffset += metrics.lineHeight + (isWrapped(row) ? wrapDelta(mode) : 0)
    }
    return yOffset
  }

  /// A single dense `.context` leaf of `rows` rows with sparse dual-mode measured
  /// deltas — deliberately filled to `maxLeafSpan` so the intra-leaf variable walk is
  /// exercised at its production ceiling (this is the "maxed dense leaf" the
  /// `LayoutCheckpoint` accelerator exists for).
  private func variableLeaf(rows: Int) -> (tree: ChunkTree, id: ChunkID) {
    let tree = ChunkTree(metrics: metrics)
    let lines = (0..<rows).map {
      DiffLine(origin: .context, oldLineNumber: $0 + 1, newLineNumber: $0 + 1, content: "x", noNewlineAtEof: false)
    }
    let segment = LineSegment(
      hunkID: HunkID(fileID: "f", index: 0), lines: lines, window: 0..<rows, classification: .context)
    let id = tree.insert(.lineSegment(segment), after: nil)
    let node = tree.nodesByID[id]!
    var deltas: [Int: LineHeightDelta] = [:]
    for row in 0..<rows where isWrapped(row) {
      deltas[row] = LineHeightDelta(unified: wrapDelta(.unified), split: wrapDelta(.split))
    }
    node.heightDeltas = deltas
    node.summary = tree.leafSummary(for: node.chunk, heightDeltas: deltas)
    tree.reaggregate(from: id)
    return (tree, id)
  }

  /// Mirrors pierre "uses checkpoints for deep variable-height line positions":
  /// a DEEP seek into a variable-height leaf resolves to the exact linear-walk top,
  /// with NO checkpoint present (proving the bounded intra-leaf walk is correct on its
  /// own), in BOTH modes, and the index-seek and y-seek round-trip agree.
  @Test func deepVariableHeightSeekMatchesLinearWalk() {
    let span = ChunkLayoutMetrics.maxLeafSpan  // 5_000 — a maxed dense leaf
    let (tree, id) = variableLeaf(rows: span)
    // The accelerator is absent — exactness must hold from the linear walk alone.
    #expect(tree.nodesByID[id]!.checkpoints == nil)

    let deep = 3_990  // deep (near the leaf's far end) AND wrapped (3_990 % 7 == 0)
    #expect(isWrapped(deep))

    for mode in [DiffViewMode.unified, .split] {
      let expectedTop = linearTop(upTo: deep, mode: mode)
      let expectedHeight = metrics.lineHeight + wrapDelta(mode)  // the deep row is wrapped

      let byIndex = tree.seek(index: deep, mode: mode)!
      #expect(byIndex.rowIndex == deep)
      #expect(byIndex.yOrigin == expectedTop)
      #expect(byIndex.rowHeight == expectedHeight)

      // The inverse lookup (pierre `getNumericScrollAnchor`): seeking the exact top
      // returns the same row and origin — a y↔index round-trip through the deep walk.
      let byY = tree.seek(y: expectedTop, mode: mode)!
      #expect(byY.rowIndex == deep)
      #expect(byY.yOrigin == expectedTop)
      #expect(byY.id == byIndex.id)
    }
  }

  /// DOCUMENTED DIVERGENCE guard. Where pierre would have BUILT `cache.checkpoints`
  /// during the first deep lookup, our seek is a pure read: `node.checkpoints` stays
  /// `nil` (absent) BEFORE and AFTER a deep index-seek and y-seek, and no other tree
  /// geometry is perturbed — only `diagnostics.seekCount` advances.
  @Test func deepSeekDoesNotLazilyBuildCheckpoints() {
    let span = ChunkLayoutMetrics.maxLeafSpan
    let (tree, id) = variableLeaf(rows: span)
    let node = tree.nodesByID[id]!

    #expect(node.checkpoints == nil)  // absent before any deep lookup

    let totalUnifiedBefore = tree.totalHeight(.unified)
    let totalSplitBefore = tree.totalHeight(.split)
    let rowsBefore = tree.rowCount(.unified)
    let nodesBefore = tree.nodeCount
    let deltasBefore = node.heightDeltas
    tree.diagnostics.seekCount = 0

    _ = tree.seek(index: 3_990, mode: .unified)
    _ = tree.seek(y: 40_000, mode: .split)

    // No lazy checkpoint build — the pierre "PRESENT after" assertion is inapplicable.
    #expect(node.checkpoints == nil)
    // The deep seek mutated nothing but the seek counter.
    #expect(tree.totalHeight(.unified) == totalUnifiedBefore)
    #expect(tree.totalHeight(.split) == totalSplitBefore)
    #expect(tree.rowCount(.unified) == rowsBefore)
    #expect(tree.nodeCount == nodesBefore)
    #expect(node.heightDeltas == deltasBefore)
    #expect(tree.diagnostics.seekCount == 2)
  }
}
