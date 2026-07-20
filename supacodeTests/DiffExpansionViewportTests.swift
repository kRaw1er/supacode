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
      controller.applyExpansion(
        gap: GapKey(fileID: "a.swift", hunkIndex: 1), region: region, revealedLines: Self.revealedContext(4..<40)))

    // The full slice now materializes the whole gap contiguously — no skip. hunk 0
    // renders new 1…3, the revealed gap 4…39, hunk 1's addition new 40 → 1…40.
    #expect(Self.renderedNewNumbers(tree) == Array(1...40))
    #expect(tree.totalHeight(.unified) > heightBefore)  // the document grew
    #expect(tree.widgetNode(for: .expander(GapKey(fileID: "a.swift", hunkIndex: 1))) == nil)  // expander removed

    // A narrow window straddling the middle of the expanded region materializes it.
    controller.scroll(toY: tree.totalHeight(.unified) / 2)
    let visible = tree.indexRange(in: controller.visibleRect, mode: .unified)
    #expect(!visible.rows.isEmpty)
    #expect(controller.totalUsedViewCount > 0)  // the viewport did NOT skip the region
  }

  /// A gap's nodes are found through the tree's own region index, so there is no
  /// second copy of that state to keep in step — and nothing to go stale when the
  /// tree is replaced. Pinned directly: the index tracks a splice, and a fresh tree
  /// knows nothing about the previous one's gap.
  @Test func gapNodesComeFromTheTreesOwnRegionIndex() {
    let (file, hunks) = Self.twoHunkFixture()
    let gap = GapKey(fileID: "a.swift", hunkIndex: 1)
    let tree = ChunkTreeFixture.files([.init(file: file, hunks: hunks)])
    let controller = ViewportTestSupport.controller()
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)

    // Collapsed: the gap is exactly its expander.
    #expect(tree.nodes(in: .gap(gap)).count == 1)
    #expect(tree.nodes(in: .gap(gap)).first?.chunk.widget?.key == .expander(gap))

    // Revealed: the index now holds the spliced segments instead.
    let region = ExpansionState.ResolvedRegion(fromStart: 36, fromEnd: 0, collapsedLines: 0, renderAll: true)
    #expect(controller.applyExpansion(gap: gap, region: region, revealedLines: Self.revealedContext(4..<40)))
    let revealed = tree.nodes(in: .gap(gap))
    #expect(!revealed.isEmpty)
    #expect(revealed.allSatisfy { $0.chunk.lineSegment != nil })

    // A fresh tree shares none of it — the index belongs to the tree, not the gap.
    let reprojected = ChunkTreeFixture.files([.init(file: file, hunks: hunks)])
    #expect(reprojected.nodes(in: .gap(gap)).count == 1)  // collapsed again, its own expander
    #expect(Set(reprojected.nodes(in: .gap(gap)).map(\.id)).isDisjoint(with: Set(revealed.map(\.id))))
  }

  /// Re-projecting (saving a comment re-projects) and then re-applying the live
  /// expansion state must not disturb the fresh tree's own nodes.
  ///
  /// The expansion bookkeeping is keyed by `ChunkID` and a fresh tree allocates ids
  /// FROM ZERO, so ids tracked against the previous tree address unrelated nodes in
  /// the new one. Carrying them over made the re-apply pass delete whatever held
  /// those ids — which is how a just-saved comment vanished with no trace, and how
  /// the document ended up torn (jumping scroll, clipped tail).
  @Test func reprojectionDropsStaleExpansionIDsSoReapplyKeepsTheNewTreeIntact() {
    let (file, hunks) = Self.twoHunkFixture()
    let controller = ViewportTestSupport.controller()
    let region = ExpansionState.ResolvedRegion(fromStart: 36, fromEnd: 0, collapsedLines: 0, renderAll: true)
    let gap = GapKey(fileID: "a.swift", hunkIndex: 1)

    controller.apply(
      tree: ChunkTreeFixture.files([.init(file: file, hunks: hunks)]), mode: .unified, scrollPreserving: false)
    #expect(controller.applyExpansion(gap: gap, region: region, revealedLines: Self.revealedContext(4..<40)))

    // Save a comment: the tree is re-projected (now carrying the thread widget) and
    // the live expansion state is re-applied on top.
    let comment = ReviewComment(
      filePath: "a.swift", side: .new, startLine: 40, endLine: 40,
      anchorSnippet: "z-new", contextBefore: "", body: "please fix")
    let reprojected = ChunkTreeBuilder.build(
      file: file, hunks: hunks, mode: .unified, comments: [comment])
    controller.apply(tree: reprojected, mode: .unified, scrollPreserving: false)
    #expect(controller.applyExpansion(gap: gap, region: region, revealedLines: Self.revealedContext(4..<40)))

    // The comment survived, and the document is whole: every line 1…40 renders once.
    #expect(reprojected.widgetNode(for: .commentThread(anchorID: comment.id)) != nil)
    #expect(Self.renderedNewNumbers(reprojected) == Array(1...40))
  }

  /// The end-to-end shape of "comment on a file with a big expanded gap": scrolled
  /// deep into the revealed region, a re-projection (opening the composer, then
  /// saving) rebuilds a COLLAPSED tree, re-applies the expansion, and re-lands the
  /// anchor. The viewport must come back to the same line at the same pixel.
  @Test func commentingInsideABigRevealedGapKeepsTheScrollPosition() {
    let file = DiffFixture.file()
    let hunks = [Self.changeHunk(newStart: 1), Self.changeHunk(newStart: 145)]
    let gap = GapKey(fileID: "a.swift", hunkIndex: 1)  // new lines 2…144 — a 143-line gap
    let revealed = Self.revealedContext(2..<145)
    let region = ExpansionState.ResolvedRegion(
      fromStart: revealed.count, fromEnd: 0, collapsedLines: 0, renderAll: true)
    let controller = ViewportTestSupport.controller()

    controller.apply(
      tree: ChunkTreeBuilder.build(file: file, hunks: hunks, mode: .unified), mode: .unified,
      scrollPreserving: false)
    #expect(controller.applyExpansion(gap: gap, region: region, revealedLines: revealed))

    // Scroll deep into the revealed region and remember where we are.
    controller.scroll(toY: 1600)
    let before = controller.visibleRect.minY
    let anchor = controller.captureScrollAnchor()
    #expect(anchor != nil)

    // Re-project (composer open / comment saved) → re-apply expansion → re-land.
    let comment = ReviewComment(
      filePath: "a.swift", side: .new, startLine: 145, endLine: 145,
      anchorSnippet: "new", contextBefore: "", body: "please fix")
    let reprojected = ChunkTreeBuilder.build(file: file, hunks: hunks, mode: .unified, comments: [comment])
    controller.apply(tree: reprojected, mode: .unified, scrollPreserving: false)
    #expect(controller.applyExpansion(gap: gap, region: region, revealedLines: revealed))
    controller.restoreScrollAnchor(anchor)

    #expect(controller.visibleRect.minY == before)
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
      controller.applyExpansion(
        gap: GapKey(fileID: "a.swift", hunkIndex: 1), region: region, revealedLines: Self.revealedContext(4..<14)))
    let rendered = Self.renderedNewNumbers(tree)
    #expect(rendered == [1, 2, 3] + Array(4...13) + [40])  // hunk0, head 4…13, hunk1
    #expect(tree.widgetNode(for: .expander(GapKey(fileID: "a.swift", hunkIndex: 1))) != nil)  // still collapsed in part

    // Collapse restores the full expander and re-hides the revealed lines.
    #expect(
      controller.collapseExpansion(
        gap: GapKey(fileID: "a.swift", hunkIndex: 1), hiddenLines: 36, anchor: 4, range: 4..<40))
    #expect(Self.renderedNewNumbers(tree) == [1, 2, 3, 40])
    #expect(tree.widgetNode(for: .expander(GapKey(fileID: "a.swift", hunkIndex: 1))) != nil)
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
    let gap2Before = tree.widgetNode(for: .expander(GapKey(fileID: "a.swift", hunkIndex: 2)))?.id
    let hunk2HeaderBefore = tree.widgetNode(for: .hunkHeader(hunkID: HunkID(fileID: file.id, index: 2)))?.id
    #expect(gap2Before != nil)
    #expect(hunk2HeaderBefore != nil)

    // Resolve (fully expand) gap 1 (new lines 2…39, 38 lines).
    let region = ExpansionState.ResolvedRegion(fromStart: 38, fromEnd: 0, collapsedLines: 0, renderAll: true)
    #expect(
      controller.applyExpansion(
        gap: GapKey(fileID: "a.swift", hunkIndex: 1), region: region, revealedLines: Self.revealedContext(2..<40)))

    // Splice locality: gap 2's expander + hunk 2's header keep their EXACT node ids —
    // the O(log n) insert never re-mints or touches its siblings.
    #expect(tree.widgetNode(for: .expander(GapKey(fileID: "a.swift", hunkIndex: 2)))?.id == gap2Before)
    #expect(tree.widgetNode(for: .hunkHeader(hunkID: HunkID(fileID: file.id, index: 2)))?.id == hunk2HeaderBefore)
    // Gap 1's expander is gone (fully revealed); gap 2 stays collapsed.
    #expect(tree.widgetNode(for: .expander(GapKey(fileID: "a.swift", hunkIndex: 1))) == nil)
    #expect(tree.widgetNode(for: .expander(GapKey(fileID: "a.swift", hunkIndex: 2))) != nil)
    // Gap 2's hidden interior is still hidden — its slice was not materialized.
    #expect(!Self.renderedNewNumbers(tree).contains(60))
  }
}
