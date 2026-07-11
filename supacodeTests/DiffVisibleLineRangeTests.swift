import AppKit
import Testing

@testable import supacode

/// CAT 1 — the coordinate-mapping invariants that the "all text white" bug violated.
/// `fireVisibleRange` used to hand the highlighter `tree.indexRange` — RENDERED-ROW
/// indices, shifted by every file-header / hunk-header / expander widget and shared
/// across both blob sides. `tree.visibleLineRange` resolves the visible rows back to
/// the 1-based `DiffLine.old/newLineNumber` space the blob highlighter must be queried
/// with. These pin that resolution so the wrong coordinate can never be fed again.
@MainActor
struct DiffVisibleLineRangeTests {
  /// A rect tall enough to cover the whole tree (the walk stops at `maxY`).
  private let fullRect = CGRect(x: 0, y: 0, width: 800, height: 1_000_000)

  private func fullContextFile(path: String, oldStart: Int, newStart: Int, contents: [String]) -> ChunkTree {
    let lines = contents.enumerated().map { offset, text in
      DiffFixture.line(.context, old: oldStart + offset, new: newStart + offset, text)
    }
    let hunk = DiffFixture.hunk(
      lines, oldStart: oldStart, newStart: newStart, header: "@@ -\(oldStart) +\(newStart) @@")
    return ChunkTreeFixture.files([.init(file: DiffFixture.file(path: path), hunks: [hunk])])
  }

  /// The visible window is the 1-based SOURCE line numbers on screen — NOT the
  /// rendered-row indices. A leading file-header (and hunk-header) widget shifts the
  /// rendered indices to start at 0 while the source lines start at 10; the two must
  /// NOT coincide, which is exactly why feeding `indexRange` to a blob query was wrong.
  @Test func visibleWindowIsSourceLineNumbersNotRenderedRowIndices() {
    let tree = fullContextFile(
      path: "a.swift", oldStart: 10, newStart: 10, contents: ["let a = 1", "let b = 2", "let c = 3"])

    let window = tree.visibleLineRange(in: fullRect, mode: .unified)
    #expect(window.new == 10..<13, "the new side must span the visible NEW line numbers 10...12")
    #expect(window.old == 10..<13, "context rows carry both sides, so the old side spans 10...12 too")

    // The rendered-row index range starts at 0 (the file-header widget), proving the
    // two coordinates diverge — the crux of the bug.
    let rendered = tree.indexRange(in: fullRect, mode: .unified).rows
    #expect(rendered.lowerBound == 0)
    #expect(rendered != window.new, "rendered-row indices must NOT be mistaken for source line numbers")
  }

  /// An addition-only hunk shows no OLD lines, so the old side is empty (the reducer
  /// then skips the old-blob query) while the new side spans the added lines.
  @Test func additionOnlyHunkHasEmptyOldSide() {
    let adds = [
      DiffFixture.line(.addition, old: nil, new: 5, "added one"),
      DiffFixture.line(.addition, old: nil, new: 6, "added two"),
    ]
    let hunk = DiffFixture.hunk(adds, oldStart: 4, newStart: 5, header: "@@ -4,0 +5,2 @@")
    let tree = ChunkTreeFixture.files([.init(file: DiffFixture.file(path: "b.swift"), hunks: [hunk])])

    let window = tree.visibleLineRange(in: fullRect, mode: .unified)
    #expect(window.old.isEmpty, "no old lines are visible in an addition-only hunk")
    #expect(window.new == 5..<7, "the new side spans the two added lines 5...6")
  }

  /// An empty tree resolves to the empty window (no crash, no phantom lines).
  @Test func emptyTreeYieldsEmptyWindow() {
    #expect(ChunkTree().visibleLineRange(in: fullRect, mode: .unified) == .empty)
  }

  // MARK: - O(1) number resolver (the visibleLineRange fast path)

  /// A change + context multi-hunk tree with NO no-newline markers, for exercising the
  /// marker-free fast path in both modes.
  private func mixedChangeTree() -> ChunkTree {
    let lines = [
      DiffFixture.line(.context, old: 1, new: 1, "ctx one"),
      DiffFixture.line(.deletion, old: 2, new: nil, "del a"),
      DiffFixture.line(.deletion, old: 3, new: nil, "del b"),
      DiffFixture.line(.addition, old: nil, new: 2, "add x"),
      DiffFixture.line(.addition, old: nil, new: 3, "add y"),
      DiffFixture.line(.addition, old: nil, new: 4, "add z"),
      DiffFixture.line(.context, old: 4, new: 5, "ctx two"),
    ]
    let hunk = DiffFixture.hunk(lines, oldStart: 1, newStart: 1, header: "@@ -1,4 +1,5 @@")
    return ChunkTreeFixture.files([.init(file: DiffFixture.file(path: "c.swift"), hunks: [hunk])])
  }

  /// The O(1) `LineSegment.lineNumbers(atRenderedRow:)` resolver (which replaced the
  /// per-leaf `renderedRows` array build in `visibleLineRange`) must agree, row for row,
  /// with the golden `renderedRows` projection — for context, unified change (del-then-add
  /// order), AND split change (del ↔ add column pairing). Guards the fast path against
  /// drift from the projection it stands in for. `windowDeletionCount` (binary search) is
  /// the pairing pivot, so this also pins it.
  @Test func lineNumberResolverMatchesRenderedRowsForEveryLeaf() {
    for mode in [DiffViewMode.unified, .split] {
      for node in mixedChangeTree().inorderNodes() {
        guard let segment = node.chunk.lineSegment else { continue }
        let deletionCount = segment.windowDeletionCount
        #expect(!segment.windowHasNoNewlineMarker(deletionCount: deletionCount), "fixture must be marker-free")
        let golden = segment.renderedRows(mode)
        for (localRow, row) in golden.enumerated() {
          let resolved = segment.lineNumbers(atRenderedRow: localRow, mode: mode, deletionCount: deletionCount)
          #expect(
            resolved.old == row.oldNumber && resolved.new == row.newNumber,
            "resolver diverged from renderedRows at leaf row \(localRow) in \(mode): \(resolved) vs \(row)")
        }
      }
    }
  }

  /// A change hunk's visible window splits cleanly per side: the old side spans only the
  /// deletion numbers, the new side only the addition numbers — the resolver never leaks a
  /// deletion's (nil) new number or an addition's (nil) old number into the wrong side.
  @Test func changeHunkResolvesOldAndNewSidesIndependently() {
    for mode in [DiffViewMode.unified, .split] {
      let window = mixedChangeTree().visibleLineRange(in: fullRect, mode: mode)
      // old: context 1 + deletions 2,3 + trailing context 4 ⇒ 1...4. new: context 1 +
      // additions 2,3,4 + trailing context 5 ⇒ 1...5.
      #expect(window.old == 1..<5, "old side spans context + deletion numbers in \(mode)")
      #expect(window.new == 1..<6, "new side spans context + addition numbers in \(mode)")
    }
  }

  /// PERF GUARD (algorithmic, machine-independent): `visibleLineRange` must resolve the
  /// visible rows' numbers via the O(1) per-row resolver and build ZERO full `renderedRows`
  /// arrays for marker-free content — the O(leaf)-per-visible-leaf materialization (~75% of
  /// the per-frame scroll cost) that the resolver replaced. A regression that reintroduces a
  /// per-leaf full projection grows `renderedRowsBuildCount` and fails here.
  @Test func visibleLineRangeBuildsNoFullLeafForMarkerFreeContent() {
    // 20k marker-free context lines ⇒ ~4 ≤maxLeafSpan leaves over a shared backing.
    let contents = (0..<20_000).map { "let x\($0) = \($0)" }
    let tree = fullContextFile(path: "big.swift", oldStart: 1, newStart: 1, contents: contents)
    // A viewport-sized band deep in the file (crosses a maxLeafSpan leaf boundary).
    let midY = tree.seek(index: 10_000, mode: .unified)?.yOrigin ?? 0
    let viewport = CGRect(x: 0, y: midY, width: 800, height: 800)

    let before = LineSegment.renderedRowsBuildCount
    let window = tree.visibleLineRange(in: viewport, mode: .unified)
    let built = LineSegment.renderedRowsBuildCount - before

    #expect(!window.new.isEmpty, "the viewport must actually intersect visible lines")
    #expect(
      built == 0,
      "visibleLineRange built \(built) full renderedRows array(s) — the O(1) number resolver regressed to O(leaf)")
  }

  /// A leaf whose final line carries a no-newline marker takes the FALLBACK path
  /// (rendered-row ≠ window offset once the marker row is inserted). The resolved window
  /// must still be exact — the fallback builds the full `renderedRows`, so the marker (a
  /// number-duplicating row) never shifts the min/max.
  @Test func noNewlineMarkerLeafResolvesViaFallback() {
    let lines = [
      DiffFixture.line(.context, old: 1, new: 1, "ctx"),
      DiffFixture.line(.addition, old: nil, new: 2, "last line", noNewline: true),
    ]
    let hunk = DiffFixture.hunk(lines, oldStart: 1, newStart: 1, header: "@@ -1,1 +1,2 @@")
    let tree = ChunkTreeFixture.files([.init(file: DiffFixture.file(path: "d.swift"), hunks: [hunk])])
    let window = tree.visibleLineRange(in: fullRect, mode: .unified)
    #expect(window.new == 1..<3, "the new side spans the context + added line, marker not double-counted")
    #expect(window.old == 1..<2, "only the context line carries an old number")
  }
}
