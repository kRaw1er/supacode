import AppKit
import Testing

@testable import supacode

/// Phase 10 — the shared `reveal(row:)` primitive: the pure anchored-scroll solver
/// (`DiffScrollTargetSolver`, ~20 boundary cases) + the live NSVIEW reveal against a
/// real window-less `DiffViewportController` (alignment, sticky-inset, clamp, nearest
/// fallback). Port of pierre `computeFocusedRowScrollTopForOffset` / `ScrollIntoView`.
@MainActor
struct DiffRevealTests {
  // MARK: - scrollTargetPureCases (~20) — the pure solver

  @Test func scrollTargetPureCases() {
    let viewportHeight: CGFloat = 600  // clip height
    let total: CGFloat = 5000  // maxTop = 4400
    let inset: CGFloat = 44

    func solve(_ rowTop: CGFloat, _ rowHeight: CGFloat, _ align: RevealAlignment, minY: CGFloat, inset: CGFloat = 44)
      -> CGFloat?
    {
      DiffScrollTargetSolver.desiredTop(
        rowTop: rowTop, rowHeight: rowHeight, align: align,
        viewport: DiffScrollTargetSolver.Viewport(
          visibleMinY: minY, height: viewportHeight, totalHeight: total, headerInset: inset))
    }

    // 1. nearest — row already fully visible in the unobscured band → nil (no scroll).
    #expect(solve(1100, 20, .nearest, minY: 1000) == nil)
    // 2. nearest — row hidden above / under the sticky header → reveal above (rowTop-inset).
    #expect(solve(1020, 20, .nearest, minY: 1000) == 1020 - inset)
    // 3. nearest — row below the fold → land it at the viewport bottom (rowBottom-vh).
    #expect(solve(1590, 20, .nearest, minY: 1000) == (1590 + 20) - viewportHeight)
    // 4. nearest — row bottom exactly at the fold is still visible → nil.
    #expect(solve(1580, 20, .nearest, minY: 1000) == nil)
    // 5. nearest — respects the top inset on scroll-up (lands rowTop-inset, not rowTop).
    #expect(solve(1010, 20, .nearest, minY: 1000, inset: 100) == 910)  // 1010 − 100

    // 6. top align — subtracts the sticky inset.
    #expect(solve(2000, 20, .top, minY: 0) == 2000 - inset)
    // 7. top align — negative inset degrades to 0.
    #expect(solve(2000, 20, .top, minY: 0, inset: -10) == 2000)
    // 8. top align — clamps at the tail [0, total-vh].
    #expect(solve(4900, 20, .top, minY: 0) == 4400)
    // 9. top align — clamps at 0 when the inset pushes the target negative.
    #expect(solve(10, 20, .top, minY: 0) == 0)

    // 10. center — row centered in the UNOBSCURED band (below the header).
    let band = viewportHeight - inset  // 556
    #expect(solve(2000, 20, .center, minY: 0) == 2000 - inset - (band - 20) / 2)
    // 11. center — single-line region == line height (region is one line).
    #expect(solve(3000, 20, .center, minY: 0) == 3000 - inset - (band - 20) / 2)
    // 12. center — multi-line region centered as one region (larger height).
    #expect(solve(3000, 100, .center, minY: 0) == 3000 - inset - (band - 100) / 2)
    // 13. center — region taller than the band → top-aligns (start visible) minus inset.
    #expect(solve(3000, 700, .center, minY: 0) == 3000 - inset)
    // 14. center — clamps to 0 near the top.
    #expect(solve(100, 20, .center, minY: 0) == 0)
    // 15. center — clamps at the tail.
    #expect(solve(4900, 20, .center, minY: 0) == 4400)

    // 16. nearest — minimal move up when just above the band.
    #expect(solve(999, 20, .nearest, minY: 1000) == 999 - inset)
    // 17. nearest — minimal move down when just below the fold.
    #expect(solve(1601, 10, .nearest, minY: 1000) == (1601 + 10) - viewportHeight)
    // 18. top align — zero inset lands exactly at the row top.
    #expect(solve(1234, 20, .top, minY: 0, inset: 0) == 1234)
    // 19. nearest — a row under the header at the very top reveals above, clamped to 0.
    #expect(solve(20, 20, .nearest, minY: 0) == 0)
    // 20. empty/degenerate: zero total height clamps everything to 0.
    #expect(
      DiffScrollTargetSolver.desiredTop(
        rowTop: 100, rowHeight: 20, align: .top,
        viewport: DiffScrollTargetSolver.Viewport(visibleMinY: 0, height: 600, totalHeight: 0, headerInset: 44)) == 0)
  }

  // MARK: - revealAlignmentRangeCenterNearestFallback (NSVIEW)

  @Test func revealAlignmentRangeCenterNearestFallback() {
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: 600)
    controller.apply(tree: ViewportTestSupport.contextLeaves(Array(1...500)), mode: .unified, scrollPreserving: false)
    let inset = StickyHeaderOverlay.headerHeight  // 44
    func originY() -> CGFloat { controller.scrollView.contentView.bounds.origin.y }

    // top align — lands rowTop - inset.
    controller.reveal(toY: 2000, height: 20, align: .top)
    #expect(abs(originY() - (2000 - inset)) < 0.5)

    // nearest — row below the fold from the top → bottom-align.
    controller.scroll(toY: 0)
    controller.reveal(toY: 2000, height: 20, align: .nearest)
    #expect(abs(originY() - ((2000 + 20) - 600)) < 0.5)

    // nearest — row above the current offset (under the header) → reveal above.
    controller.scroll(toY: 3000)
    controller.reveal(toY: 2000, height: 20, align: .nearest)
    #expect(abs(originY() - (2000 - inset)) < 0.5)

    // nearest — already fully visible → NO scroll (fallback no-op).
    controller.scroll(toY: 2000)
    controller.reveal(toY: 2100, height: 20, align: .nearest)
    #expect(abs(originY() - 2000) < 0.5)

    // center — single-line region centered in the unobscured band.
    let band = CGFloat(600) - inset
    controller.reveal(toY: 5000, height: 20, align: .center)
    #expect(abs(originY() - (5000 - inset - (band - 20) / 2)) < 0.5)

    // center — region taller than the band top-aligns (start visible) minus inset.
    controller.reveal(toY: 5000, height: 700, align: .center)
    #expect(abs(originY() - (5000 - inset)) < 0.5)

    // clamps to [0, docHeight - visibleHeight] (total 10000, clip 600 → maxTop 9400).
    controller.reveal(toY: 9990, height: 20, align: .top)
    #expect(abs(originY() - 9400) < 0.5)
    controller.reveal(toY: 10, height: 20, align: .top)
    #expect(originY() == 0)
  }

  // MARK: - revealRespectsStickyInset (NSVIEW)

  @Test func revealRespectsStickyInset() {
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: 600)
    controller.apply(tree: ViewportTestSupport.contextLeaves(Array(1...500)), mode: .unified, scrollPreserving: false)
    func originY() -> CGFloat { controller.scrollView.contentView.bounds.origin.y }

    controller.reveal(toY: 3000, height: 20, align: .top, headerInset: 44)
    let with44 = originY()
    controller.reveal(toY: 3000, height: 20, align: .top, headerInset: 100)
    let with100 = originY()
    // A larger sticky inset lands the row proportionally lower (further above), so the
    // top offset is smaller by exactly the inset delta.
    #expect(abs((with44 - with100) - (100 - 44)) < 0.5)
    #expect(abs(with44 - (3000 - 44)) < 0.5)
  }

  // MARK: - reveal(row:) seeks the row's y then anchors (NSVIEW)

  @Test func revealRowSeeksTreeGeometry() {
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: 600)
    controller.apply(tree: ViewportTestSupport.contextLeaves(Array(1...500)), mode: .unified, scrollPreserving: false)
    // Row index 150 sits at y = 150 * 20 = 3000; .top align → 3000 - 44.
    controller.reveal(row: 150, align: .top)
    #expect(abs(controller.scrollView.contentView.bounds.origin.y - (3000 - StickyHeaderOverlay.headerHeight)) < 0.5)
    // Out-of-range index is a no-op (guarded seek).
    let before = controller.scrollView.contentView.bounds.origin.y
    controller.reveal(row: 999_999, align: .top)
    #expect(controller.scrollView.contentView.bounds.origin.y == before)
  }
}
