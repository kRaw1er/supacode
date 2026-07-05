import Foundation
import Testing

@testable import supacode

/// Pure unit + property coverage for the `ChunkTree` red-black `SumTree`. No
/// AppKit, no store — hand-built and builder-built trees, dual-mode seeks, RB /
/// aggregate invariants.
@MainActor
struct ChunkTreeTests {
  // MARK: - Helpers

  /// A widget leaf with an explicit height (for hand-built height-walk trees).
  private func widget(_ index: Int, height: CGFloat) -> Chunk {
    .widget(
      Widget(
        key: .expander(GapKey(hunkIndex: index)),
        estimatedHeight: height,
        payload: .expander(anchor: index, range: index..<(index + 1), hidden: 1)
      )
    )
  }

  /// A context segment over lines numbered `1...count` on both sides.
  private func contextSegment(count: Int, classification: SegmentClass = .context) -> Chunk {
    let lines = (0..<count).map {
      DiffLine(origin: .context, oldLineNumber: $0 + 1, newLineNumber: $0 + 1, content: "x", noNewlineAtEof: false)
    }
    return .lineSegment(
      LineSegment(
        hunkID: HunkID(fileID: "f", index: 0), lines: lines, window: 0..<count, classification: classification)
    )
  }

  // MARK: - Seek

  @Test func seekByIndexReturnsLeafInBothModes() {
    let hunk = DiffFixture.hunk(
      [
        DiffFixture.line(.context, old: 1, new: 1, "keep"),
        DiffFixture.line(.deletion, old: 2, "gone"),
        DiffFixture.line(.addition, new: 2, "added"),
        DiffFixture.line(.context, old: 3, new: 3, "tail"),
      ],
      header: "@@ -1,3 +1,3 @@"
    )
    let tree = ChunkTreeBuilder.build(file: DiffFixture.file(), hunks: [hunk], mode: .unified, expanded: [])

    // Unified: fh, hh, ctx(1), del(2), add(2), ctx(3)
    #expect(tree.seek(index: 0, mode: .unified)?.chunk.widget?.reuseKind == .fileHeader)
    #expect(tree.seek(index: 2, mode: .unified)?.chunk.lineSegment?.classification == .context)
    #expect(tree.seek(index: 3, mode: .unified)?.chunk.lineSegment?.classification == .change)
    #expect(tree.seek(index: 5, mode: .unified)?.chunk.lineSegment?.windowedLines.first?.newLineNumber == 3)
    // Split: fh, hh, ctx(1), pair(2/2), ctx(3) — one fewer row than unified
    #expect(tree.seek(index: 3, mode: .split)?.chunk.lineSegment?.classification == .change)
    #expect(tree.seek(index: 4, mode: .split)?.chunk.lineSegment?.windowedLines.first?.newLineNumber == 3)
    #expect(tree.rowCount(.unified) == 6)
    #expect(tree.rowCount(.split) == 5)
    #expect(tree.seek(index: 6, mode: .unified) == nil)
  }

  @Test func seekByYReturnsLeafInBothModes() {
    let hunk = DiffFixture.hunk(
      [
        DiffFixture.line(.context, old: 1, new: 1),
        DiffFixture.line(.deletion, old: 2),
        DiffFixture.line(.addition, new: 2),
        DiffFixture.line(.context, old: 3, new: 3),
      ],
      header: "@@ -1,3 +1,3 @@"
    )
    let tree = ChunkTreeBuilder.build(file: DiffFixture.file(), hunks: [hunk], mode: .split)
    // fileHeader 44, hunkHeader 32, then 20-pt rows: ctx [76,96), then change/context.
    #expect(tree.seek(y: 10, mode: .unified)?.chunk.widget?.reuseKind == .fileHeader)
    #expect(tree.seek(y: 60, mode: .unified)?.chunk.widget?.reuseKind == .hunkHeader)
    #expect(tree.seek(y: 80, mode: .unified)?.chunk.lineSegment?.classification == .context)
    #expect(tree.seek(y: 100, mode: .unified)?.chunk.lineSegment?.classification == .change)
    // A y past the end clamps to the last row.
    let end = tree.totalHeight(.split)
    #expect(tree.seek(y: end + 500, mode: .split)?.chunk.lineSegment?.windowedLines.first?.newLineNumber == 3)
  }

  @Test func seekYWalksLeftSubtreeHeight() {
    let tree = ChunkTree()
    let nodeA = tree.insert(widget(0, height: 10), after: nil)
    let nodeB = tree.insert(widget(1, height: 20), after: nodeA)
    _ = tree.insert(widget(2, height: 30), after: nodeB)
    // The root's left-subtree height is the height of the leading widget.
    let root = tree.root!
    #expect(root.leftSubtree.height(.unified) == 10)
    // The y-walk subtracts leftSubtree.height before deciding.
    #expect(tree.seek(y: 5, mode: .unified)?.rowIndex == 0)
    #expect(tree.seek(y: 15, mode: .unified)?.rowIndex == 1)  // 15 - 10(left) lands in root's own row
    #expect(tree.seek(y: 40, mode: .unified)?.rowIndex == 2)  // 40 - 10 - 20 lands right
    #expect(tree.totalHeight(.unified) == 60)
  }

  // MARK: - Insert

  @Test func insertAfterKeepsInorderAndRBInvariants() {
    let tree = ChunkTree()
    var last: ChunkID?
    for index in 0..<12 {
      last = tree.insert(widget(index, height: 20), after: last)
    }
    // In-order == document order (the anchor indices ascend).
    let anchors = tree.inorderChunks().compactMap { chunk -> Int? in
      if case .widget(let widget) = chunk, case .expander(let gap) = widget.key { return gap.hunkIndex }
      return nil
    }
    #expect(anchors == Array(0..<12))
    #expect(ChunkTreeInvariants.check(tree).isEmpty)
    // Prepend lands at the front.
    _ = tree.insert(widget(99, height: 20), after: nil)
    if case .widget(let widget) = tree.inorderChunks().first, case .expander(let gap) = widget.key {
      #expect(gap.hunkIndex == 99)
    } else {
      Issue.record("prepend did not land at the front")
    }
    #expect(ChunkTreeInvariants.check(tree).isEmpty)
  }

  // MARK: - Split

  @Test func splitPreservesLineNumbers() {
    let tree = ChunkTree()
    let id = tree.insert(contextSegment(count: 6), after: nil)
    let (left, right) = tree.split(id, atLocalRow: 3)
    let leftLines = tree.nodesByID[left]!.chunk.lineSegment!.windowedLines.map(\.newLineNumber)
    let rightLines = tree.nodesByID[right]!.chunk.lineSegment!.windowedLines.map(\.newLineNumber)
    #expect(leftLines == [1, 2, 3])
    #expect(rightLines == [4, 5, 6])
    // Total row count is preserved by the split.
    #expect(tree.rowCount(.unified) == 6)
    #expect(ChunkTreeInvariants.check(tree).isEmpty)
  }

  @Test func splitPartitionsSparseHeightDeltas() {
    let tree = ChunkTree()
    let id = tree.insert(contextSegment(count: 8), after: nil)
    // Measure rows 1 and 4 (wrapped), producing sparse deltas.
    tree.setMeasuredHeight(40, chunk: id, localRow: 1, mode: .unified)
    tree.setMeasuredHeight(60, chunk: id, localRow: 4, mode: .unified)
    tree.nodesByID[id]!.checkpoints = [
      LayoutCheckpoint(localLine: 1, unifiedTop: 20, splitTop: 20),
      LayoutCheckpoint(localLine: 4, unifiedTop: 80, splitTop: 80),
    ]
    let (left, right) = tree.split(id, atLocalRow: 3)
    #expect(tree.nodesByID[left]!.heightDeltas?.keys.sorted() == [1])
    #expect(tree.nodesByID[right]!.heightDeltas?.keys.sorted() == [1])  // 4 → 4-3 == 1
    #expect(tree.nodesByID[left]!.checkpoints?.map(\.localLine) == [1])
    #expect(tree.nodesByID[right]!.checkpoints?.map(\.localLine) == [1])  // 4 → 1
    #expect(ChunkTreeInvariants.check(tree).isEmpty)
  }

  @Test func widgetLeafIsNotASegment() {
    // `split` preconditions on a `.lineSegment`; assert a widget id is not one
    // (the guard that would trap), without triggering the trap.
    let tree = ChunkTree()
    let id = tree.insert(widget(0, height: 20), after: nil)
    #expect(tree.nodesByID[id]?.chunk.lineSegment == nil)
    #expect(tree.nodesByID[id]?.chunk.widget != nil)
  }

  // MARK: - Measured height

  @Test func setMeasuredHeightReaggregatesAncestorsOnly() {
    let tree = ChunkTree()
    var last: ChunkID?
    var ids: [ChunkID] = []
    for index in 0..<7 {
      last = tree.insert(widget(index, height: 20), after: last)
      ids.append(last!)
    }
    let target = ids[1]
    // A node in a different subtree from `target`.
    let siblingID = ids[5]
    let siblingBefore = tree.nodesByID[siblingID]!.subtreeSummary
    let rootBefore = tree.totalHeight(.unified)

    tree.setMeasuredHeight(35, chunk: target, localRow: 0, mode: .unified)

    #expect(tree.nodesByID[siblingID]!.subtreeSummary == siblingBefore)  // byte-equal, untouched
    #expect(tree.totalHeight(.unified) == rootBefore + 15)  // 35 - 20
    #expect(tree.totalHeight(.split) == rootBefore)  // split untouched
    #expect(ChunkTreeInvariants.check(tree).isEmpty)
  }

  // MARK: - Mode toggle

  @Test func modeToggleIsReseekNotReproject() {
    let tree = ChunkTreeFixture.uniform(rows: 20_000)
    tree.diagnostics.seekCount = 0
    let anchor = tree.locate(rowIndex: 15_000, mode: .unified)!
    let toggled = tree.rowIndex(for: anchor, mode: .split)!
    // Uniform context is 1:1, so the row index is preserved and the chunk is the same.
    #expect(toggled == 15_000)
    #expect(tree.seek(index: 15_000, mode: .split)?.id == anchor.chunk)
    // The toggle cost a single O(log n) seek — NOT an O(n) reproject.
    #expect(tree.diagnostics.seekCount <= 2)
  }

  // MARK: - File navigation

  @Test func offsetForFileReturnsHeaderOffset() {
    let fileA = DiffFixture.file(path: "a.swift")
    let fileB = DiffFixture.file(path: "b.swift")
    let hunk = DiffFixture.hunk([DiffFixture.line(.addition, new: 1, "x"), DiffFixture.line(.addition, new: 2, "y")])
    let tree = ChunkTreeFixture.files([
      .init(file: fileA, hunks: [hunk]),
      .init(file: fileB, hunks: [hunk]),
    ])
    let hit = tree.offsetForFile(fileB.id, mode: .unified)
    #expect(hit?.chunk.widget?.key == .fileHeader(fileID: fileB.id))
    // fileA rendered rows: fileHeader + hunkHeader + change segment (2 unified rows) = 4.
    #expect(hit?.rowIndex == 4)
    let expectedY: CGFloat = 44 + 32 + 40  // fileHeader + hunkHeader + 2×20
    #expect(hit?.yOrigin == expectedY)
  }

  // MARK: - Totals & aggregates

  @Test func totalHeightEqualsSumOfLeafHeights() {
    let hunk = DiffFixture.hunk(
      [
        DiffFixture.line(.context, old: 1, new: 1),
        DiffFixture.line(.deletion, old: 2),
        DiffFixture.line(.addition, new: 2),
        DiffFixture.line(.addition, new: 3),
      ],
      header: "@@ -1,2 +1,3 @@"
    )
    let tree = ChunkTreeBuilder.build(file: DiffFixture.file(), hunks: [hunk], mode: .unified)
    for mode in [DiffViewMode.unified, .split] {
      let leafSum = tree.inorderNodes().reduce(CGFloat.zero) { $0 + $1.summary.height(mode) }
      #expect(tree.totalHeight(mode) == leafSum)
    }
    #expect(ChunkTreeInvariants.check(tree).isEmpty)
  }

  @Test func checkpointResumeMatchesLinearWalk() {
    let tree = ChunkTree()
    let id = tree.insert(contextSegment(count: 100), after: nil)
    let node = tree.nodesByID[id]!
    // Sparse wrapped rows every 7th line, dual-mode.
    var deltas: [Int: LineHeightDelta] = [:]
    for row in stride(from: 0, to: 100, by: 7) {
      deltas[row] = LineHeightDelta(unified: 13, split: 5)
    }
    node.heightDeltas = deltas
    node.summary = tree.leafSummary(for: node.chunk, heightDeltas: deltas)
    tree.reaggregate(from: id)
    // A correct checkpoint at row 50 (cumulative top of row 50, both modes).
    let top50Unified = linearTop(deltas: deltas, upTo: 50, mode: .unified)
    let top50Split = linearTop(deltas: deltas, upTo: 50, mode: .split)
    node.checkpoints = [LayoutCheckpoint(localLine: 50, unifiedTop: top50Unified, splitTop: top50Split)]

    for mode in [DiffViewMode.unified, .split] {
      let resumed = tree.seek(index: 80, mode: mode)!
      let expectedY = linearTop(deltas: deltas, upTo: 80, mode: mode)
      #expect(resumed.yOrigin == expectedY)
      #expect(resumed.rowHeight == 20 + (deltas[80]?.value(mode) ?? 0))
    }
  }

  private func linearTop(deltas: [Int: LineHeightDelta], upTo: Int, mode: DiffViewMode) -> CGFloat {
    var yOffset: CGFloat = 0
    for row in 0..<upTo {
      yOffset += 20 + (deltas[row]?.value(mode) ?? 0)
    }
    return yOffset
  }

  // MARK: - Property tests

  @Test func sumOfLeafSummariesEqualsRootAggregate() {
    var rng = SeededRNG(seed: 0xC0FF_EE00)
    for _ in 0..<20 {
      let tree = ChunkTreeFixture.uniform(rows: 40)
      runRandomOps(on: tree, count: 60, rng: &rng)
      #expect(ChunkTreeInvariants.check(tree).isEmpty)
    }
  }

  @Test func rbInvariantsHoldAfterRandomOps() {
    var rng = SeededRNG(seed: 0x1234_5678)
    for _ in 0..<20 {
      let tree = ChunkTree()
      var last: ChunkID?
      for index in 0..<6 {
        last = tree.insert(contextSegment(count: 8), after: last)
        _ = index
      }
      runRandomOps(on: tree, count: 80, rng: &rng)
      #expect(ChunkTreeInvariants.check(tree).isEmpty)
    }
  }

  private func runRandomOps(on tree: ChunkTree, count: Int, rng: inout SeededRNG) {
    for _ in 0..<count {
      let nodes = tree.inorderNodes()
      guard let node = nodes.randomElement(using: &rng) else { continue }
      switch Int.random(in: 0..<3, using: &rng) {
      case 0:
        _ = tree.insert(widget(Int.random(in: 0..<9_999, using: &rng), height: 24), after: node.id)
      case 1:
        if let segment = node.chunk.lineSegment, segment.window.count >= 2 {
          let offset = Int.random(in: 1..<segment.window.count, using: &rng)
          _ = tree.split(node.id, atLocalRow: offset)
        }
      default:
        let mode: DiffViewMode = Bool.random(using: &rng) ? .unified : .split
        let localRow = Int.random(in: 0..<max(node.summary.count(mode), 1), using: &rng)
        tree.setMeasuredHeight(
          CGFloat(Int.random(in: 10...80, using: &rng)), chunk: node.id, localRow: localRow, mode: mode)
      }
    }
  }

  // MARK: - Scale

  @Test func millionLineTreeHasNodeCountFarBelowLineCount() {
    let rows = 1_000_000
    let tree = ChunkTreeFixture.uniform(rows: rows)
    let expectedLeaves = (rows + ChunkLayoutMetrics.maxLeafSpan - 1) / ChunkLayoutMetrics.maxLeafSpan
    #expect(tree.nodeCount == expectedLeaves)
    #expect(tree.nodeCount < rows / 1_000)  // node count ≪ line count
    for mode in [DiffViewMode.unified, .split] {
      let hit = tree.seek(index: 999_999, mode: mode)
      let segment = hit?.chunk.lineSegment
      #expect(segment?.windowLine(at: hit!.localRow).newLineNumber == 1_000_000)
    }
    #expect(tree.seek(y: tree.totalHeight(.unified) - 1, mode: .unified)?.rowIndex == 999_999)
  }
}

/// Deterministic PRNG for the property tests (splitmix64).
nonisolated struct SeededRNG: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state = state &+ 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}
