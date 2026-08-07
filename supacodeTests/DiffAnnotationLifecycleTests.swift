import AppKit
import Testing

@testable import supacode

/// pierre-backfill Batch B — annotation/widget reserved-height RELEASE
/// (NSVIEW-HEADLESS).
///
/// The existing `fileLevelAnnotationNotReservedUntilMeasured` covers RESERVE-on-
/// measure but never the release. These mirror the release half:
///   • Removing a measured annotation frees its reserved height and the document
///     shrinks back — pierre `virtualizedFileDiffEstimatedHeights.test.ts` "clears
///     measured file-level annotation height when annotations change" (351 → 326)
///     and `FileDiff.partialRender.test.ts` "removes file-level annotations".
///   • Scrolling a measured annotation off-window recycles its pooled VIEW (the
///     live resource is released) while the tree KEEPS the reserved height so the
///     scrollbar stays stable — pierre "preserves measured file-level annotation
///     height when the row is not rendered".
@MainActor
struct DiffAnnotationLifecycleTests {

  // MARK: - Remove → reserved height released, document shrinks back
  //          (mirrors "clears measured ... when annotations change" / "removes
  //           file-level annotations")

  @Test func removingMeasuredAnnotationReleasesReservedHeight() {
    let controller = ViewportTestSupport.controller()
    let tree = ChunkTree(metrics: .production)
    let lineHeight = ChunkLayoutMetrics.production.lineHeight

    // A file-level annotation (comment widget, zero estimate → reserves only on
    // measure) above a 400-row source region.
    let anchorID = UUID()
    let widgetID = tree.insert(WidgetTreeFixture.commentWidget(id: anchorID, estimatedHeight: 0), after: nil)
    var after: ChunkID? = widgetID
    for line in 1...400 { after = tree.insert(WidgetTreeFixture.contextLeaf(line), after: after) }
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)

    let base = CGFloat(400) * lineHeight  // 8_000 — the source rows alone
    #expect(tree.totalHeight(.unified) == base)  // nothing reserved yet

    // Measure it (LayoutCoalescer write-back) → reserves 120, document grows.
    controller.setMeasuredHeight(
      .commentThread(anchorID: anchorID), width: controller.documentView.bounds.width, height: 120)
    controller.restoreScrollAnchor(controller.captureScrollAnchor())
    #expect(tree.totalHeight(.unified) == base + 120)

    // Remove the annotation (cancel / annotations-changed path) → the reserved
    // height is RELEASED: totalHeight shrinks back and the document frame follows.
    #expect(controller.removeCommentWidget(anchorID: anchorID))
    #expect(tree.totalHeight(.unified) == base)
    #expect(abs(controller.documentView.frame.height - base) < 0.5)
    // The widget is gone, so no reserved height lingers.
    #expect(controller.measuredHeight(forWidget: .commentThread(anchorID: anchorID)) == nil)
    #expect(tree.widgetNode(for: .commentThread(anchorID: anchorID)) == nil)
  }

  // MARK: - Scroll out → pooled view recycles, reserved height PRESERVED
  //          (mirrors "preserves measured ... when the row is not rendered")

  @Test func scrollingAnnotationOutRecyclesViewButPreservesReservedHeight() {
    let controller = ViewportTestSupport.controller()
    let tree = ChunkTree(metrics: .production)

    // A comment widget at the very top (reserves 120) above a tall 2_000-row region
    // so a modest scroll pushes it well past the window + overscan.
    let anchorID = UUID()
    let widgetID = tree.insert(WidgetTreeFixture.commentWidget(id: anchorID, estimatedHeight: 120), after: nil)
    var after: ChunkID? = widgetID
    for line in 1...2000 { after = tree.insert(WidgetTreeFixture.contextLeaf(line), after: after) }
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)

    // Materialized at the top: its pooled view is in use.
    let pool = controller.pools[.widget(.commentThread)]
    #expect(pool?.getView(forKey: widgetID) != nil)
    let heightWithWidget = tree.totalHeight(.unified)
    #expect(heightWithWidget == 120 + CGFloat(2000) * ChunkLayoutMetrics.production.lineHeight)

    // Scroll far below the widget (y 0…120) + the 1_000 px overscan → the widget
    // leaves the window and its pooled view is recycled (prepareForReuse).
    controller.scroll(toY: 10_000)
    #expect(controller.pools[.widget(.commentThread)]?.getView(forKey: widgetID) == nil)  // view released

    // But the reserved height is PRESERVED on the tree so the scrollbar does not jump
    // as the off-window annotation scrolls in and out (its node still reserves 120).
    #expect(tree.totalHeight(.unified) == heightWithWidget)
    #expect(tree.widgetNode(for: .commentThread(anchorID: anchorID))?.summary.height(.unified) == 120)

    // Scrolling back re-materializes the SAME widget at its preserved position.
    controller.scroll(toY: 0)
    #expect(controller.pools[.widget(.commentThread)]?.getView(forKey: widgetID) != nil)
    #expect(tree.totalHeight(.unified) == heightWithWidget)
  }
}
