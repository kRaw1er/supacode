import Foundation
import Testing

@testable import supacode

/// Backfill of pierre's estimated-height regression suite for our dense-segment
/// chunk-tree analog. Mirrors the INVARIANTS of
/// `packages/diffs/test/computeEstimatedDiffHeights.test.ts`,
/// `virtualFileMetricsPadding.test.ts`, and
/// `virtualizedFileDiffEstimatedHeights.test.ts` — not their DOM/CSS mechanics.
///
/// pierre's `computeEstimatedDiffHeights` up-front estimate maps to our
/// `ChunkTreeBuilder.estimatedHeights(file:hunks:options:)`; pierre's laid-out
/// `getLinePosition(...).top` / `getVirtualizedHeight()` maps to the REAL tree
/// geometry (`ChunkTree.seek` yOrigin / `totalHeight`). The two are deliberately
/// different in our stack: the estimate reserves line-info separator heights
/// (`separatorHeight ± spacing`) while the materialized tree carries explicit
/// expander (`expanderHeight`) + hunk-header (`separatorHeight`) widget rows — so
/// each assertion below is composed from the metric constants it actually depends
/// on rather than a single opaque literal.
@MainActor
struct DiffEstimateHeightsTests {
  private var metrics: ChunkLayoutMetrics { .production }

  /// pierre `createTwoHunkDiff`: a file with two single-line changes separated by
  /// collapsed context, so a leading gap (before hunk 1), a middle gap (between
  /// the hunks), and — when the total line count is known — a trailing gap all
  /// exist. Each hunk carries `edgeContext` context lines on both sides plus a
  /// del/add pair. `newStart` values leave `collapsedBefore > 0` for both hunks.
  private func twoHunkFile() -> (file: FileChange, hunks: [DiffHunk]) {
    let hunk1 = DiffFixture.hunk(
      [
        DiffFixture.line(.context, old: 38, new: 38, "c38"),
        DiffFixture.line(.context, old: 39, new: 39, "c39"),
        DiffFixture.line(.deletion, old: 40, "old-40"),
        DiffFixture.line(.addition, new: 40, "changed-40"),
        DiffFixture.line(.context, old: 41, new: 41, "c41"),
        DiffFixture.line(.context, old: 42, new: 42, "c42"),
      ],
      oldStart: 38, newStart: 38, header: "@@ -38,5 +38,5 @@"
    )
    let hunk2 = DiffFixture.hunk(
      [
        DiffFixture.line(.context, old: 98, new: 98, "c98"),
        DiffFixture.line(.context, old: 99, new: 99, "c99"),
        DiffFixture.line(.deletion, old: 100, "old-100"),
        DiffFixture.line(.addition, new: 100, "changed-100"),
        DiffFixture.line(.context, old: 101, new: 101, "c101"),
        DiffFixture.line(.context, old: 102, new: 102, "c102"),
      ],
      oldStart: 98, newStart: 98, header: "@@ -98,5 +98,5 @@"
    )
    return (DiffFixture.file(), [hunk1, hunk2])
  }

  /// The known new-file line count for the two-hunk fixture — large enough that a
  /// trailing collapsed gap exists after hunk 2 (its `newEnd` is 103). Enabling
  /// this is what makes our builder reserve the trailing separator (pierre reserves
  /// it whenever the diff is NOT partial).
  private var twoHunkTotalNewLines: Int { 140 }

  // MARK: - Item 1: two-hunk separator geometry

  /// Mirrors computeEstimatedDiffHeights.test.ts
  /// "accounts for collapsed leading and trailing line-info separators" +
  /// virtualFileMetricsPadding.test.ts "keeps hunk separator gaps": the full-file
  /// estimate is exactly header + firstSep + hunk1 rows + middleSep + hunk2 rows +
  /// trailingSep + paddingBottom, in BOTH modes.
  @Test func twoHunkEstimateComposesEverySeparator() {
    let fixture = twoHunkFile()
    let options = ChunkTreeBuilder.Options(totalNewLines: twoHunkTotalNewLines)
    let heights = ChunkTreeBuilder.estimatedHeights(file: fixture.file, hunks: fixture.hunks, options: options)

    let header = metrics.diffHeaderHeight + metrics.paddingTop
    let firstSep = ChunkTreeBuilder.separatorHeight(.first, style: .lineInfo, metrics: metrics)
    let middleSep = ChunkTreeBuilder.separatorHeight(.middle, style: .lineInfo, metrics: metrics)
    let trailingSep = ChunkTreeBuilder.separatorHeight(.trailing, style: .lineInfo, metrics: metrics)
    let counts1 = ChunkTreeBuilder.hunkCounts(fixture.hunks[0])
    let counts2 = ChunkTreeBuilder.hunkCounts(fixture.hunks[1])

    // Sanity on the fixture geometry (pierre asserts collapsedBefore > 0 for both).
    #expect(fixture.hunks[0].newStart > 1)  // leading gap ⇒ first separator
    #expect(fixture.hunks[1].newStart > fixture.hunks[0].newStart + fixture.hunks[0].newCount)  // middle gap
    #expect(twoHunkTotalNewLines >= fixture.hunks[1].newStart + fixture.hunks[1].newCount)  // trailing gap

    let separators = firstSep + middleSep + trailingSep
    let expectedSplit =
      header + firstSep + CGFloat(counts1.split) * metrics.lineHeight
      + middleSep + CGFloat(counts2.split) * metrics.lineHeight
      + trailingSep + metrics.paddingBottom
    let expectedUnified =
      header + firstSep + CGFloat(counts1.unified) * metrics.lineHeight
      + middleSep + CGFloat(counts2.unified) * metrics.lineHeight
      + trailingSep + metrics.paddingBottom

    #expect(heights.split == expectedSplit)
    #expect(heights.unified == expectedUnified)

    // Concrete values for the production metric set (44/20/32/8) — a change to the
    // arithmetic that still balances the composition above would not survive here.
    #expect(separators == 128)  // 40 + 48 + 40
    #expect(heights.split == 380)  // 44 + 40 + 10*20 + 48 + 40 + 8
    #expect(heights.unified == 420)  // 44 + 40 + 12*20 + 48 + 40 + 8
  }

  /// Mirrors virtualFileMetricsPadding.test.ts
  /// "keeps current line-info separator estimates for first, middle, and trailing
  /// collapsed context": the second hunk's first CODE row sits below the file
  /// header + leading gap separator + hunk-1 header + all of hunk 1's rows + the
  /// middle gap separator + hunk-2 header. Asserted on the REAL tree geometry
  /// (`seek` yOrigin over the materialized expander/hunk-header widget rows).
  @Test func secondHunkFirstRowTopIncludesFirstHunkAndMiddleSeparator() {
    let fixture = twoHunkFile()
    let options = ChunkTreeBuilder.Options(totalNewLines: twoHunkTotalNewLines)
    let tree = ChunkTreeBuilder.build(file: fixture.file, hunks: fixture.hunks, mode: .unified, options: options)

    let hunk2HeaderKey = WidgetKey.hunkHeader(hunkID: HunkID(fileID: fixture.file.id, index: 1))
    let hunk2Header = tree.widgetNode(for: hunk2HeaderKey)
    #expect(hunk2Header != nil)
    let headerRow = tree.rowIndex(for: (hunk2Header!.id, 0), mode: .unified)
    #expect(headerRow != nil)

    let firstBodyRow = headerRow! + 1
    let hit = tree.seek(index: firstBodyRow, mode: .unified)
    #expect(hit != nil)
    // The first row of the second hunk's body is real code, not another widget.
    #expect(hit?.chunk.lineSegment != nil)
    #expect(hit?.chunk.lineSegment?.windowedLines.first?.newLineNumber == 98)

    let counts1 = ChunkTreeBuilder.hunkCounts(fixture.hunks[0])
    let expectedTop =
      metrics.diffHeaderHeight  // file header widget
      + metrics.expanderHeight  // leading collapsed-gap separator
      + metrics.separatorHeight  // hunk 1 header widget
      + CGFloat(counts1.unified) * metrics.lineHeight  // all of hunk 1's rows
      + metrics.expanderHeight  // middle collapsed-gap separator
      + metrics.separatorHeight  // hunk 2 header widget
    #expect(hit?.yOrigin == expectedTop)
    #expect(expectedTop == 284)  // 44 + 28 + 32 + 120 + 28 + 32
  }

  // MARK: - Item 2: unknown-tail diffs reserve no trailing separator

  /// Mirrors computeEstimatedDiffHeights.test.ts
  /// "does not estimate trailing collapsed context for partial diffs". Our builder
  /// has no `isPartial` flag; the semantic analog is `totalNewLines == nil` (the
  /// new-file length is unknown, so the tail is unknown). With no known total, the
  /// estimate reserves the leading + middle separators but NOT a trailing one; the
  /// delta against the known-total estimate is exactly one trailing separator.
  @Test func estimateReservesNoTrailingSeparatorForUnknownTail() {
    let fixture = twoHunkFile()

    // Unknown tail (totalNewLines == nil): no trailing separator reserved.
    let unknownTail = ChunkTreeBuilder.estimatedHeights(file: fixture.file, hunks: fixture.hunks)
    // Known tail: the trailing separator IS reserved.
    let knownTail = ChunkTreeBuilder.estimatedHeights(
      file: fixture.file, hunks: fixture.hunks,
      options: ChunkTreeBuilder.Options(totalNewLines: twoHunkTotalNewLines)
    )

    let header = metrics.diffHeaderHeight + metrics.paddingTop
    let firstSep = ChunkTreeBuilder.separatorHeight(.first, style: .lineInfo, metrics: metrics)
    let middleSep = ChunkTreeBuilder.separatorHeight(.middle, style: .lineInfo, metrics: metrics)
    let trailingSep = ChunkTreeBuilder.separatorHeight(.trailing, style: .lineInfo, metrics: metrics)
    let counts1 = ChunkTreeBuilder.hunkCounts(fixture.hunks[0])
    let counts2 = ChunkTreeBuilder.hunkCounts(fixture.hunks[1])

    let expectedSplitNoTrailing =
      header + firstSep + CGFloat(counts1.split + counts2.split) * metrics.lineHeight
      + middleSep + metrics.paddingBottom
    let expectedUnifiedNoTrailing =
      header + firstSep + CGFloat(counts1.unified + counts2.unified) * metrics.lineHeight
      + middleSep + metrics.paddingBottom

    #expect(unknownTail.split == expectedSplitNoTrailing)
    #expect(unknownTail.unified == expectedUnifiedNoTrailing)

    // The only difference between unknown and known tail is one trailing separator.
    #expect(knownTail.split - unknownTail.split == trailingSep)
    #expect(knownTail.unified - unknownTail.unified == trailingSep)
    #expect(trailingSep == 40)  // 8 (spacing) + 32 (separator body)
  }

  // MARK: - Item 3: estimate grows on hunk expansion for BOTH modes

  /// Mirrors virtualizedFileDiffEstimatedHeights.test.ts
  /// "recomputes paired estimates when hunk expansion changes": a partial reveal of
  /// `revealedRows` context lines grows BOTH the unified AND the split total height
  /// by exactly `revealedRows * lineHeight`, while the collapsed-gap expander leaf
  /// stays in place (so the growth is purely the revealed rows, not a separator
  /// swap). Driven through the real viewport `applyExpansion` splice.
  @Test func hunkExpansionGrowsBothModeTotalsByRevealedRows() {
    let controller = ViewportTestSupport.controller()
    // A single hunk far down the file ⇒ a leading collapsed gap (GapKey 0) of 200
    // hidden lines before the hunk body.
    let hunk = DiffFixture.hunk(
      [
        DiffFixture.line(.context, old: 201, new: 201, "c201"),
        DiffFixture.line(.deletion, old: 202, "old-202"),
        DiffFixture.line(.addition, new: 202, "new-202"),
        DiffFixture.line(.context, old: 203, new: 203, "c203"),
      ],
      oldStart: 201, newStart: 201, header: "@@ -201,3 +201,3 @@"
    )
    let tree = ChunkTreeFixture.files([ChunkTreeFixture.FileSpec(file: DiffFixture.file(), hunks: [hunk])])
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)

    let gap = GapKey(hunkIndex: 0)
    #expect(controller.tree.widgetNode(for: .expander(gap)) != nil)
    let rangeSize = 200
    let revealedRows = 5

    // Partial reveal of the top `revealedRows` lines of the gap (fromStart), so the
    // expander is shrunken but NOT removed (collapsedLines stays > 0).
    var state = ExpansionState.collapsed
    state.expand(gap: gap.hunkIndex, by: .lines(revealedRows), direction: .up)
    let region = state.resolve(gap: gap.hunkIndex, rangeSize: rangeSize)
    #expect(region.collapsedLines > 0)  // partial ⇒ expander survives
    #expect(region.fromStart == revealedRows)
    let revealed = (1...revealedRows).map { DiffFixture.line(.context, old: $0, new: $0, "ctx\($0)") }

    let unifiedBefore = controller.tree.totalHeight(.unified)
    let splitBefore = controller.tree.totalHeight(.split)

    let applied = controller.applyExpansion(gap: gap, region: region, revealedLines: revealed)
    #expect(applied)

    let expectedDelta = CGFloat(revealedRows) * metrics.lineHeight  // 5 * 20 = 100
    #expect(controller.tree.totalHeight(.unified) - unifiedBefore == expectedDelta)
    #expect(controller.tree.totalHeight(.split) - splitBefore == expectedDelta)
    #expect(expectedDelta == 100)

    // The gap's expander is still present (partial reveal) — growth was purely the
    // revealed rows, not a separator height change.
    #expect(controller.tree.widgetNode(for: .expander(gap)) != nil)
  }
}
