import AppKit
import Testing

@testable import supacode

/// PERF-REGRESSION (NSVIEW-HEADLESS) — the suite that was MISSING and let a
/// scroll-lagging viewer ship "green". A world-class diff viewer must be
/// virtualized: the work per layout / scroll frame is bounded by the VISIBLE
/// WINDOW (+overscan), never by the file size or the leaf-segment span.
///
/// These are ALGORITHMIC assertions (spy counters), NOT wall-clock — scale
/// invariance is machine-independent and stable in CI. Two per-instance counters
/// carry them (parallel-safe, mirror `ChunkTree.diagnostics`):
///   • `CTLineCache.buildCount`      — real CoreText typesets (cache misses).
///   • `DiffViewportController.lineRowsConfigured` — rows pushed through
///     `LineRowView.configure` across layout passes (re-project cost).
///
/// Root causes these pin (all confirmed in the render layer):
///   1. `maxLeafSpan == 5_000` + `LineRowView` typesets the WHOLE segment up front
///      ⇒ opening a 100k file typesets ~5_000 rows for a ~80-row window.
///   2. `DiffViewportController.configure` has NO early-out for line segments
///      (widgets do) ⇒ every scroll frame re-projects the whole visible segment.
///
/// The headless controller is 800×600 (30 visible rows); with the ~1000px
/// overscan the ideal window is ~80 rows. Thresholds are generous multiples of
/// that so the FIX target is unambiguous and the failure is loud.
@MainActor
struct DiffViewportScalePerfTests {
  /// Rows a correct virtualized viewport may touch on one layout: visible window
  /// (600px / 20px = 30) + overscan both sides, with generous headroom.
  static let windowBudget = 400

  // MARK: - Bug 1 — initial layout must not typeset the whole 5_000-row segment

  @Test func initialLayoutTypesetsVisibleWindowNotWholeSegment_100k() {
    let tree = ChunkTreeFixture.largeDistinct(rows: 100_000)
    let controller = ViewportTestSupport.controller()  // 800×600, ~80-row window
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)

    let typeset = controller.ctLineCache.buildCount
    // Windowed render (`lineRenderWindow`): the FIRST layout typesets ONLY the visible
    // viewport window (+overscan), estimating off-screen line heights — NOT the whole
    // 5_000-row leaf. Placement fidelity is proven by `DiffViewportGeometryFidelityTests`
    // (each drawn row lands at its true document-y), so this is a hard pass again.
    #expect(
      typeset <= Self.windowBudget,
      """
      Opening a 100k-line file typeset \(typeset) lines on the FIRST layout — the visible \
      window is ~80 rows. The viewport must materialize only the visible sub-window of the \
      \(ChunkLayoutMetrics.maxLeafSpan)-row leaf, not the whole segment. Typeset work must be \
      O(viewport), not O(segment).
      """
    )
  }

  // MARK: - Bug 1 — layout cost must be independent of FILE SIZE (scale invariance)

  @Test func layoutTypesetWorkIsScaleInvariant_1k_vs_100k() {
    func typesetsForInitialLayout(_ rows: Int) -> Int {
      let controller = ViewportTestSupport.controller()
      controller.apply(tree: ChunkTreeFixture.largeDistinct(rows: rows), mode: .unified, scrollPreserving: false)
      return controller.ctLineCache.buildCount
    }
    let small = typesetsForInitialLayout(1_000)
    let huge = typesetsForInitialLayout(100_000)
    // Windowed render: initial typeset work is bounded by the visible window, so it is the
    // same (≈ the viewport) whether the file is 1k or 100k lines — scale-invariant.
    #expect(
      huge <= small * 2,
      """
      Initial-layout typeset work scaled with file size: 1k→\(small) lines, 100k→\(huge) lines. \
      A virtualized viewport typesets ~the same (≈ the visible window) regardless of file size; \
      the growth means work is O(file/segment), not O(viewport).
      """
    )
  }

  // MARK: - Bug 2 — a scroll inside a materialized region must not re-project it

  @Test func scrollWithinMaterializedRegionDoesNotReconfigureWholeSegment_100k() {
    let tree = ChunkTreeFixture.uniform(rows: 100_000)  // content-agnostic: counts ROWS, not typesets
    let controller = ViewportTestSupport.controller()
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)

    let baseline = controller.lineRowsConfigured
    controller.scroll(toY: 40)  // 2 rows — the same 5_000-row segment is already materialized
    let reconfigured = controller.lineRowsConfigured - baseline

    #expect(
      reconfigured <= 300,
      """
      A 2-row scroll re-configured \(reconfigured) rows. The visible segment was already \
      materialized, so a pure scroll should re-project ~0 rows — `DiffViewportController.configure` \
      is missing the line-segment early-out that widgets already have (`mountedKey == key ⇒ return`), \
      so it re-projects (and re-hits the cache for) the whole segment every frame.
      """
    )
  }

  // MARK: - Bug 3 — a syntax arrival re-typesets the window, it must NOT re-project the leaf

  @Test func syntaxBumpDoesNotReprojectMaterializedLeaf() {
    let controller = ViewportTestSupport.controller()
    controller.apply(tree: ChunkTreeFixture.largeDistinct(rows: 5_000), mode: .unified, scrollPreserving: false)
    let afterApply = LineRowView.projectCount
    #expect(afterApply >= 1, "the visible leaf was never projected — the guard would be vacuous")
    // A span-cache fill bumps `syntaxVersion` ≈ every scroll frame. Syntax colours are
    // applied at TYPESET time, so a bump must re-typeset the visible window WITHOUT
    // rebuilding the whole ≤maxLeafSpan row model (`project()`).
    for _ in 1...10 { controller.repaintForSyntaxFill() }
    #expect(
      LineRowView.projectCount == afterApply,
      """
      10 syntax bumps re-projected the leaf \(LineRowView.projectCount - afterApply)× — syntaxVersion \
      leaked back into the project key, so every windowed-highlight arrival re-walks the whole leaf \
      (the O(leaf)-per-frame scroll stall).
      """
    )
  }

  // MARK: - Scale guard — tree seeks per layout stay sublinear (O(log n × window))

  @Test func seekCountPerLayoutIsSublinear_100k() {
    let tree = ChunkTreeFixture.uniform(rows: 100_000)
    let controller = ViewportTestSupport.controller()
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
    #expect(
      tree.diagnostics.seekCount < 2_000,
      "seekCount \(tree.diagnostics.seekCount) for a 100k layout — must stay O(log n × window), not O(n)."
    )
  }
}
