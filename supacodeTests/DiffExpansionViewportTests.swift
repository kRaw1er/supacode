import AppKit
import Testing

@testable import supacode

/// Phase 7 — the viewport side of incremental collapse/expand: `applyExpansion` /
/// `collapseExpansion` splice a gap's revealed blob slice into the tree O(log n)
/// with an anchored relayout. NSVIEW-HEADLESS (a real `NSScrollView` with no
/// window). Extends P2's differential oracle over an expanded region + the
/// splice-locality (tree-invariant) oracle for accept/reject.
@MainActor
struct DiffExpansionViewportTests {

  // MARK: - Fixtures

  /// hunk 0 covers new lines 1…3 (context 1, change at 2, context 3); hunk 1 starts
  /// at new line 40 — the inter-hunk gap `GapKey(1)` is new lines 4…39 (36 lines).
  private static func twoHunkFixture() -> (FileChange, [DiffHunk]) {
    let file = DiffFixture.file()
    let hunk0 = DiffHunk(
      oldStart: 1, oldCount: 3, newStart: 1, newCount: 3, header: "@@ -1,3 +1,3 @@",
      lines: [
        DiffLine(origin: .context, oldLineNumber: 1, newLineNumber: 1, content: "a", noNewlineAtEof: false),
        DiffLine(origin: .deletion, oldLineNumber: 2, newLineNumber: nil, content: "b-old", noNewlineAtEof: false),
        DiffLine(origin: .addition, oldLineNumber: nil, newLineNumber: 2, content: "b-new", noNewlineAtEof: false),
        DiffLine(origin: .context, oldLineNumber: 3, newLineNumber: 3, content: "c", noNewlineAtEof: false),
      ])
    let hunk1 = DiffHunk(
      oldStart: 40, oldCount: 1, newStart: 40, newCount: 1, header: "@@ -40 +40 @@",
      lines: [
        DiffLine(origin: .deletion, oldLineNumber: 40, newLineNumber: nil, content: "z-old", noNewlineAtEof: false),
        DiffLine(origin: .addition, oldLineNumber: nil, newLineNumber: 40, content: "z-new", noNewlineAtEof: false),
      ])
    return (file, [hunk0, hunk1])
  }

  /// A single change hunk starting at `newStart` (creates the inter-hunk gaps).
  private static func changeHunk(newStart: Int) -> DiffHunk {
    DiffHunk(
      oldStart: newStart, oldCount: 1, newStart: newStart, newCount: 1, header: "@@",
      lines: [
        DiffLine(origin: .deletion, oldLineNumber: newStart, newLineNumber: nil, content: "old", noNewlineAtEof: false),
        DiffLine(origin: .addition, oldLineNumber: nil, newLineNumber: newStart, content: "new", noNewlineAtEof: false),
      ])
  }

  private static func revealedContext(_ range: Range<Int>) -> [DiffLine] {
    range.map {
      DiffLine(origin: .context, oldLineNumber: $0, newLineNumber: $0, content: "gap\($0)", noNewlineAtEof: false)
    }
  }

  /// Every rendered line-segment row's new-side number in document order (widgets /
  /// deletion rows contribute nothing) — the differential oracle's projection.
  private static func renderedNewNumbers(_ tree: ChunkTree, mode: DiffViewMode = .unified) -> [Int] {
    var out: [Int] = []
    var hit = tree.seek(index: 0, mode: mode)
    while let current = hit {
      if let segment = current.chunk.lineSegment {
        let rows = segment.renderedRows(mode)
        if current.localRow < rows.count, let number = rows[current.localRow].newNumber { out.append(number) }
      }
      hit = tree.successor(of: current, mode: mode)
    }
    return out
  }

  // MARK: - A §9 window over an expanded region == the full slice (must NOT skip)

  @Test func windowOverExpandedRegionEqualsFullSlice() {
    let (file, hunks) = Self.twoHunkFixture()
    let tree = ChunkTreeFixture.files([.init(file: file, hunks: hunks)])
    let controller = ViewportTestSupport.controller(clipHeight: 120)  // tiny clip → must straddle
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)

    // Collapsed: the gap interior (e.g. new 20) is NOT rendered.
    #expect(!Self.renderedNewNumbers(tree).contains(20))
    let heightBefore = tree.totalHeight(.unified)

    // Fully reveal the gap (renderAll) via the viewport splice.
    let region = ExpansionState.ResolvedRegion(fromStart: 36, fromEnd: 0, collapsedLines: 0, renderAll: true)
    #expect(
      controller.applyExpansion(gap: GapKey(hunkIndex: 1), region: region, revealedLines: Self.revealedContext(4..<40)))

    // The full slice now materializes the whole gap contiguously — no skip. hunk 0
    // renders new 1…3, the revealed gap 4…39, hunk 1's addition new 40 → 1…40.
    #expect(Self.renderedNewNumbers(tree) == Array(1...40))
    #expect(tree.totalHeight(.unified) > heightBefore)  // the document grew
    #expect(tree.widgetNode(for: .expander(GapKey(hunkIndex: 1))) == nil)  // expander removed

    // A narrow window straddling the middle of the expanded region materializes it.
    controller.scroll(toY: tree.totalHeight(.unified) / 2)
    let visible = tree.indexRange(in: controller.visibleRect, mode: .unified)
    #expect(!visible.rows.isEmpty)
    #expect(controller.totalUsedViewCount > 0)  // the viewport did NOT skip the region
  }

  // MARK: - partial reveal → head + shrunken expander + tail, then collapse restores

  @Test func partialExpandKeepsExpanderThenCollapseRestores() {
    let (file, hunks) = Self.twoHunkFixture()
    let tree = ChunkTreeFixture.files([.init(file: file, hunks: hunks)])
    let controller = ViewportTestSupport.controller()
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)

    // Reveal only the top 10 of the 36-line gap → head materializes, the expander
    // stays (shrunken) for the remaining 26 hidden lines.
    let region = ExpansionState.ResolvedRegion(fromStart: 10, fromEnd: 0, collapsedLines: 26, renderAll: false)
    #expect(
      controller.applyExpansion(gap: GapKey(hunkIndex: 1), region: region, revealedLines: Self.revealedContext(4..<14)))
    let rendered = Self.renderedNewNumbers(tree)
    #expect(rendered == [1, 2, 3] + Array(4...13) + [40])  // hunk0, head 4…13, hunk1
    #expect(tree.widgetNode(for: .expander(GapKey(hunkIndex: 1))) != nil)  // still collapsed in part

    // Collapse restores the full expander and re-hides the revealed lines.
    #expect(controller.collapseExpansion(gap: GapKey(hunkIndex: 1)))
    #expect(Self.renderedNewNumbers(tree) == [1, 2, 3, 40])
    #expect(tree.widgetNode(for: .expander(GapKey(hunkIndex: 1))) != nil)
  }

  // MARK: - B §23 resolving one gap leaves other chunk identities + slices intact

  @Test func otherHunksStableAfterResolve() {
    // A three-hunk file → two inter-hunk gaps, GapKey(1) and GapKey(2).
    let file = DiffFixture.file()
    let hunks = [Self.changeHunk(newStart: 1), Self.changeHunk(newStart: 40), Self.changeHunk(newStart: 80)]
    let tree = ChunkTreeFixture.files([.init(file: file, hunks: hunks)])
    let controller = ViewportTestSupport.controller()
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)

    // Snapshot the identities + slices of everything NOT belonging to gap 1.
    let gap2Before = tree.widgetNode(for: .expander(GapKey(hunkIndex: 2)))?.id
    let hunk2HeaderBefore = tree.widgetNode(for: .hunkHeader(hunkID: HunkID(fileID: file.id, index: 2)))?.id
    #expect(gap2Before != nil)
    #expect(hunk2HeaderBefore != nil)

    // Resolve (fully expand) gap 1 (new lines 2…39, 38 lines).
    let region = ExpansionState.ResolvedRegion(fromStart: 38, fromEnd: 0, collapsedLines: 0, renderAll: true)
    #expect(
      controller.applyExpansion(gap: GapKey(hunkIndex: 1), region: region, revealedLines: Self.revealedContext(2..<40)))

    // Splice locality: gap 2's expander + hunk 2's header keep their EXACT node ids —
    // the O(log n) insert never re-mints or touches its siblings.
    #expect(tree.widgetNode(for: .expander(GapKey(hunkIndex: 2)))?.id == gap2Before)
    #expect(tree.widgetNode(for: .hunkHeader(hunkID: HunkID(fileID: file.id, index: 2)))?.id == hunk2HeaderBefore)
    // Gap 1's expander is gone (fully revealed); gap 2 stays collapsed.
    #expect(tree.widgetNode(for: .expander(GapKey(hunkIndex: 1))) == nil)
    #expect(tree.widgetNode(for: .expander(GapKey(hunkIndex: 2))) != nil)
    // Gap 2's hidden interior is still hidden — its slice was not materialized.
    #expect(!Self.renderedNewNumbers(tree).contains(60))
  }
}
