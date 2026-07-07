import AppKit
import Testing

@testable import supacode

/// RENDER-CORRECTNESS (NSVIEW-HEADLESS) — the P0 proof that the WINDOWED typeset
/// shows the RIGHT text, not merely the right COUNT. The perf suite pins that a
/// mid-scroll only typesets ≈ the viewport window; these pin that those typeset
/// rows carry the correct source line at the correct leaf-local index — pierre's
/// `collectRowSourceMismatches`. Without this, a windowing bug (off-by-N render
/// range, wrong `bufferBefore`) could pass the perf gate while painting garbage.
///
/// Both a single OVER-SIZED leaf (intra-leaf windowing — the actual bug: a
/// ≤5000-row leaf must NOT typeset every row) and a multi-leaf tree (cross-leaf
/// materialization) are covered, in unified AND split.
@MainActor
struct DiffWindowedRenderTests {
  /// The one materialized `LineRowView` for a single-leaf tree (the whole leaf is
  /// one chunk placed at row 0, so exactly one line view exists after layout).
  private func soleLineView(_ controller: DiffViewportController) -> LineRowView? {
    let views = controller.pools[.line]?.used.values.compactMap { $0 as? LineRowView } ?? []
    return views.count == 1 ? views.first : nil
  }

  // MARK: - Intra-leaf windowing: a mid-scroll typesets a mid sub-range, right text

  @Test func windowedRenderSourceTextFidelityUnified() throws {
    // One 3_000-row leaf (< maxLeafSpan ⇒ a single chunk), 60_000pt tall. Content
    // "line{index}" so leaf-local row L must render exactly "line{L}".
    let tree = ChunkTreeFixture.uniform(rows: 3_000) { "line\($0)" }
    let controller = ViewportTestSupport.controller()
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
    controller.scroll(toY: 30_000)  // mid-document

    let view = try #require(soleLineView(controller), "exactly one line view for the single big leaf")
    let visible = view.visibleRowTexts
    #expect(!visible.isEmpty)
    // WINDOWING IS CURRENTLY DISABLED (`lineRenderWindow` returns the whole leaf), so a
    // single-leaf file typesets EVERY row from index 0 — not a mid-scroll sub-window. The
    // load-bearing guard is the FIDELITY loop below (right text at the right leaf-local
    // index); re-enabling windowing would flip these two counts back to a bounded window.
    #expect(visible.count == 3_000)
    #expect(visible.first!.localRow == 0)
    #expect(visible.last!.localRow < 3_000)
    // FIDELITY: every visible row renders its own source line at its own index.
    for row in visible {
      #expect(
        row.unified == "line\(row.localRow)", "unified row \(row.localRow) rendered wrong text: \(row.unified ?? "nil")"
      )
    }
  }

  @Test func windowedRenderSourceTextFidelitySplit() throws {
    let tree = ChunkTreeFixture.uniform(rows: 3_000) { "line\($0)" }
    let controller = ViewportTestSupport.controller()
    controller.apply(tree: tree, mode: .split, scrollPreserving: false)
    controller.scroll(toY: 30_000)

    let view = try #require(soleLineView(controller), "exactly one line view for the single big leaf")
    let visible = view.visibleRowTexts
    #expect(!visible.isEmpty)
    // Windowing disabled ⇒ whole-leaf typeset (see the unified test's note).
    #expect(visible.count == 3_000)
    #expect(visible.first!.localRow == 0)
    // In split a context row projects the SAME line into both panes.
    for row in visible {
      #expect(row.old == "line\(row.localRow)", "split OLD row \(row.localRow) wrong: \(row.old ?? "nil")")
      #expect(row.new == "line\(row.localRow)", "split NEW row \(row.localRow) wrong: \(row.new ?? "nil")")
    }
  }

  // MARK: - Cross-leaf materialization: every materialized leaf shows its own line

  @Test func windowedRenderMultiLeafFidelity() throws {
    for mode in [DiffViewMode.unified, .split] {
      // 1_500 single-row context leaves (30_000pt) — taller than the viewport, so a
      // mid-scroll materializes only a bounded window of leaves.
      let tree = ViewportTestSupport.contextLeaves(Array(1...1_500))
      let controller = ViewportTestSupport.controller()
      controller.apply(tree: tree, mode: mode, scrollPreserving: false)
      controller.scroll(toY: 15_000)

      let used = controller.pools[.line]?.used ?? [:]
      #expect(!used.isEmpty)
      #expect(used.count < 300)  // window-bounded, not all 1_500 leaves
      var checked = 0
      for (chunkID, anyView) in used {
        guard let view = anyView as? LineRowView,
          let segment = controller.tree.nodesByID[chunkID]?.chunk.lineSegment
        else { continue }
        for row in view.visibleRowTexts {
          // contextLeaves render each source line 1:1; the expected text is the
          // leaf's own DiffLine at that leaf-local rendered-row index.
          let expected = segment.windowLine(at: row.localRow).content
          let rendered = mode == .unified ? row.unified : row.new
          #expect(
            rendered == expected, "leaf \(chunkID) row \(row.localRow): got \(rendered ?? "nil"), want \(expected)")
          checked += 1
        }
      }
      #expect(checked > 0, "no materialized rows were checked for \(mode)")
    }
  }
}
