import AppKit
import Testing

@testable import supacode

/// pierre-backfill Batch B — Scroll/geometry position fidelity (NSVIEW-HEADLESS).
///
/// Two invariants the existing suite left uncovered:
///   1. Deep-scroll POSITION fidelity at extreme document heights — mirrors pierre
///      `CodeView.scrollAnchoring.test.ts` "rebases the DOM scroll position while
///      preserving logical scroll progress". Our `documentView.frame.height ==
///      tree.totalHeight` is UNCAPPED (~20M px for a 1M-row tree, vs pierre's 12M
///      rebase cap), and `millionRowTreeScrollsWithBoundedViewCount` only asserts a
///      bounded view COUNT — never that the scroll offset lands where it was asked to
///      or that the top row is the right one. This pins both at 5M / 10M / ~19.9M px.
///   2. Hidden collapsed line geometry resolves to its separator/expander row —
///      mirrors pierre `sparseLayoutCheckpoints.test.ts` "VirtualizedFileDiff maps
///      hidden collapsed line indexes to their separator row": a line inside a
///      collapsed gap resolves to the single expander row (its top + separator
///      height), never to a phantom per-line row.
@MainActor
struct DiffDeepScrollFidelityTests {

  // MARK: - 1. Deep-scroll position fidelity (mirrors CodeView.scrollAnchoring
  //          "rebases the DOM scroll position while preserving logical scroll progress")

  /// A 1M-row uniform tree is 20,000,000 px tall (20 px/row). Scroll to deep
  /// offsets and assert the pixel-precise position AND the top-row identity — the
  /// two things pierre's rebase test guards (`getScrollTop()` matches the requested
  /// logical position, and `file:39` is in the rendered set) but which our scale
  /// test never checks. If AppKit/CGFloat lost precision at ~20M px, `origin.y`
  /// would drift from the requested `y` and the top materialized leaf would stop
  /// covering it — a genuine bug this would surface loudly rather than force green.
  @Test func deepScrollLandsAtExactPositionWithCorrectTopRow() {
    let controller = ViewportTestSupport.controller()
    let tree = ChunkTreeFixture.uniform(rows: 1_000_000)
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)

    let rowHeight = ChunkLayoutMetrics.production.lineHeight
    #expect(tree.totalHeight(.unified) == CGFloat(1_000_000) * rowHeight)  // 20,000,000 px, uncapped

    // Deep offsets: mid-document, further, and near the tail (past the last-leaf top
    // at 19,900,000 for a 5_000-row / 100,000-px leaf). All are < maxY, so none clamp.
    for target in [CGFloat(5_000_000), 10_000_000, 19_900_000] {
      controller.scroll(toY: target)

      // (a) The clip landed at EXACTLY the requested y (no precision drift at 20M px).
      let originY = controller.scrollView.contentView.bounds.origin.y
      #expect(
        abs(originY - target) < 0.5,
        "deep scroll to y=\(target) landed at \(originY) — position drifted at extreme document height")

      // (b) The row materialized at that offset IS the leaf the tree seeks there, and
      //     its placed view actually spans the requested y in document space.
      guard let hit = tree.seek(y: target, mode: .unified) else {
        Issue.record("nil seek at deep y=\(target)")
        continue
      }
      let view = controller.pools[hit.chunk.reuseKind]?.getView(forKey: hit.id)
      #expect(view != nil, "the leaf at y=\(target) (id \(hit.id)) was not materialized")
      if let view {
        #expect(
          view.frame.minY <= target && target < view.frame.maxY,
          "leaf at y=\(target) was placed at \(view.frame.minY)..<\(view.frame.maxY) — does not cover the offset")
      }
    }
  }

  // MARK: - 3. Hidden collapsed line → its separator/expander row (mirrors
  //          sparseLayoutCheckpoints "maps hidden collapsed line indexes to their
  //          separator row")

  /// A two-hunk file: hunk 0 renders new lines 1…3, hunk 1 renders new line 40, and
  /// the inter-hunk gap (new 4…39, 36 lines) collapses to ONE expander widget. A
  /// query for a line INSIDE that gap must resolve to the expander row — top right
  /// after hunk 0's rows, height == the separator/expander height — and must NOT
  /// surface as a rendered line row (pierre's `getLinePosition(hidden) == { top,
  /// height: hunkSeparatorHeight }`, never a phantom per-line position).
  @Test func hiddenCollapsedLineResolvesToExpanderRow() {
    let file = DiffFixture.file()
    let hunk0 = DiffFixture.hunk(
      [
        DiffFixture.line(.context, old: 1, new: 1, "a"),
        DiffFixture.line(.deletion, old: 2, "b-old"),
        DiffFixture.line(.addition, new: 2, "b-new"),
        DiffFixture.line(.context, old: 3, new: 3, "c"),
      ],
      oldStart: 1, newStart: 1, header: "@@ -1,3 +1,3 @@")
    let hunk1 = DiffFixture.hunk(
      [
        DiffFixture.line(.deletion, old: 40, "z-old"),
        DiffFixture.line(.addition, new: 40, "z-new"),
      ],
      oldStart: 40, newStart: 40, header: "@@ -40 +40 @@")
    let tree = ChunkTreeFixture.files([.init(file: file, hunks: [hunk0, hunk1])])
    let controller = ViewportTestSupport.controller()
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)

    // The gap before hunk 1 (GapKey index 1) collapsed to a single expander whose
    // range covers the hidden lines 4…39 (36 lines) as ONE row — not 36 rows.
    guard let expander = tree.widgetNode(for: .expander(GapKey(hunkIndex: 1))),
      case .expander(let anchor, let range, let hidden)? = expander.chunk.widget?.payload
    else {
      Issue.record("expected a collapsed-gap expander for GapKey(1)")
      return
    }
    #expect(anchor == 4)
    #expect(range == 4..<40)
    #expect(hidden == 36)
    #expect(range.contains(20))  // the hidden line we probe below is inside this expander
    #expect(expander.summary.count(.unified) == 1)  // ONE separator row for the whole gap

    // The expander's geometry is the separator row's position: top == fileHeader
    // (44) + hunk-0 header (32) + hunk-0 body (ctx 20 + change 40 + ctx 20 = 80),
    // height == the reserved expander height (28) — a single row, never 36 × 20.
    let metrics = ChunkLayoutMetrics.production
    let expectedTop = metrics.diffHeaderHeight + metrics.separatorHeight + (metrics.lineHeight * 4)
    let expanderFrame = controller.frame(forChunk: expander.id)
    #expect(expanderFrame?.minY == expectedTop)  // 156
    #expect(expanderFrame?.height == metrics.expanderHeight)  // 28, not 36 * lineHeight

    // The hidden lines do NOT resolve to any rendered line row (no phantom rows):
    // 20 (mid-gap) and 38 (pierre's `additionStart - 2`, just above hunk 1).
    #expect(controller.lineLocation(line: 20, side: .new) == nil)
    #expect(controller.lineRect(line: 20, side: .new) == nil)
    #expect(controller.lineLocation(line: 38, side: .new) == nil)

    // Sanity: the VISIBLE boundary lines still resolve to real rows, so only the gap
    // interior is hidden.
    #expect(controller.lineLocation(line: 1, side: .new) != nil)
    #expect(controller.lineLocation(line: 3, side: .new) != nil)
    #expect(controller.lineLocation(line: 40, side: .new) != nil)
  }
}
