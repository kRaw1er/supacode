import AppKit
import Testing

@testable import supacode

/// APPEARANCE-FLIP (NSVIEW-HEADLESS) — the native mirror of pierre
/// `themeTypeUpdates.test.ts` ("applies during partial/windowed render, no jump")
/// and `CodeView.elementPooling.test.ts` ("clears pooled shells when shared css
/// options change").
///
/// `DiffViewportController.styleDidChange()` — the light↔dark / Dynamic-Type / zoom
/// entry point wired from `DiffViewportView.viewDidChangeEffectiveAppearance` — was
/// invoked by NO test. These pin its two load-bearing invariants against a mid-
/// document, WINDOWED render:
///   (1) it re-typesets the visible window under the new palette (buildCount grows)
///       WITHOUT a scroll jump — the anchored viewport stays put; and
///   (2) it clears the pooled glyph cache so NO stale glyph survives the flip — every
///       entry cached afterwards was built after the flip (pierre "clears pooled
///       shells when shared css options change"), while the SAME `LineRowView` shell
///       is reused (not recreated) to reflect the new palette.
@MainActor
struct DiffThemeFlipTests {
  /// The one materialized `LineRowView` for a single-leaf tree.
  private func soleLineView(_ controller: DiffViewportController) -> LineRowView? {
    let views = controller.pools[.line]?.used.values.compactMap { $0 as? LineRowView } ?? []
    return views.count == 1 ? views.first : nil
  }

  /// A tall single-leaf document scrolled to the middle so the render is genuinely
  /// WINDOWED (only a mid sub-range of the 2_000-row leaf is typeset).
  private func midScrolledController() -> DiffViewportController {
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: 600)
    controller.apply(tree: ChunkTreeFixture.largeDistinct(rows: 2_000), mode: .unified, scrollPreserving: false)
    controller.scroll(toY: 20_000)  // exactly mid-document (2_000 × 20 = 40_000pt tall)
    return controller
  }

  // MARK: - (1) windowed re-typeset with NO scroll jump

  @Test func styleFlipReTypesetsVisibleWindowWithoutScrollJump() throws {
    let controller = midScrolledController()
    let view = try #require(soleLineView(controller), "exactly one line view for the single big leaf")

    let offsetBefore = controller.scrollView.contentView.bounds.origin.y
    let buildsBefore = controller.ctLineCache.buildCount
    let generationBefore = DiffPalette.shared.styleGeneration
    #expect(offsetBefore > 0, "the fixture must be scrolled into the middle, not parked at the top")
    #expect(buildsBefore > 0, "the initial windowed layout must have typeset the visible rows")
    #expect(!view.visibleRowTexts.isEmpty, "the mid-scroll window renders a slice of the leaf")

    controller.styleDidChange()

    // (a) the palette actually flipped.
    #expect(DiffPalette.shared.styleGeneration == generationBefore + 1)
    // (b) the visible window re-typeset under the new palette (a real cache-miss burst).
    #expect(controller.ctLineCache.buildCount > buildsBefore, "the flip must re-typeset the visible rows")
    // (c) NO scroll jump — the anchored viewport stayed at the same pixel offset.
    let offsetAfter = controller.scrollView.contentView.bounds.origin.y
    #expect(abs(offsetAfter - offsetBefore) < 0.5, "the appearance flip jumped the scroll offset")
    // The window still renders content afterwards (not blanked).
    #expect(!view.visibleRowTexts.isEmpty)
  }

  // MARK: - (2) pooled glyphs cleared; reused shell reflects the new palette

  @Test func styleFlipClearsPooledGlyphsAndReusesTheShell() throws {
    let controller = midScrolledController()
    let viewBefore = try #require(soleLineView(controller), "exactly one line view for the single big leaf")

    let buildsBefore = controller.ctLineCache.buildCount
    let shellBefore = ObjectIdentifier(viewBefore)

    controller.styleDidChange()

    let delta = controller.ctLineCache.buildCount - buildsBefore
    #expect(delta > 0, "the flip must rebuild the visible window's glyphs")
    // The pool was CLEARED, not reused: every entry now in the cache was built AFTER
    // the flip. If a stale (pre-flip) glyph line had survived `invalidateStyle`, the
    // live count would exceed the post-flip build burst.
    #expect(
      controller.ctLineCache.count == delta,
      "stale glyphs survived the theme flip — the pool was not fully cleared")

    // The SAME shell was reused (recycled by chunk id), now reflecting the new palette.
    let viewAfter = try #require(soleLineView(controller), "the leaf's line view must still be materialized")
    #expect(ObjectIdentifier(viewAfter) == shellBefore, "the flip recreated the shell instead of reusing it")
    #expect(!viewAfter.visibleRowTexts.isEmpty, "the reused shell must re-render its window under the new palette")
  }
}
