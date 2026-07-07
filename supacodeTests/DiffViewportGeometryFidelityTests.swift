import AppKit
import Testing

@testable import supacode

/// VIEWPORT GEOMETRY FIDELITY (PURE MODEL — NO real scroll, NO real window). The scroll
/// bar only *moves the offset*; the render layer, given a scroll offset `Y` and a known
/// row height, must LAY OUT the right document rows at the right document-`y`. We control
/// the line count and set any `Y`, so this is fully deterministic without an NSScrollView
/// gesture: set the clip offset, run the real recycle loop (`layoutVisibleChunks`), then
/// read back — for every materialized `LineRowView` — each drawn row's DOCUMENT position
/// (`view.frame.minY + rowTop`) and its content.
///
/// The seam the index tests do NOT cover: `DiffRowIndexFidelityTests` proves the MODEL
/// getter (`seek(index:)`); these prove the PLACEMENT (`layoutVisibleChunks` leaf frames +
/// `LineRowView`'s per-row `top`) actually paints those rows at their true `y`. The
/// reported bug — "only the last few rows render, on the second scroll page, different each
/// scroll" — is a placement defect: a WRAPPED leaf is positioned from the tree's 1-row
/// ESTIMATE but drawn at its full MEASURED height, so on a scroll frame adjacent leaves
/// overlap by the wrap delta (`jumpScrollManyWrappedLeavesTilesOnFirstPass` is the repro).
@MainActor
struct DiffViewportGeometryFidelityTests {

  /// One drawn row in DOCUMENT space, harvested from a materialized leaf.
  private struct PaintedRow {
    var docTop: CGFloat
    var height: CGFloat
    var localRow: Int
    var text: LineRowView.VisibleRowText
  }

  /// Every row CURRENTLY laid out for painting, across all materialized line leaves, in
  /// document-`y` order. `docTop = leaf.frame.minY + row.top` — the true on-screen y.
  private func paintedRows(_ controller: DiffViewportController) -> [PaintedRow] {
    var out: [PaintedRow] = []
    for anyView in (controller.pools[.line]?.used ?? [:]).values {
      guard let view = anyView as? LineRowView else { continue }
      let byLocal = Dictionary(view.visibleRowTexts.map { ($0.localRow, $0) }, uniquingKeysWith: { first, _ in first })
      for frame in view.typesetRowFrames {
        guard let text = byLocal[frame.localRow] else { continue }
        out.append(
          PaintedRow(docTop: view.frame.minY + frame.top, height: frame.height, localRow: frame.localRow, text: text))
      }
    }
    return out.sorted { $0.docTop < $1.docTop }
  }

  /// The painted rows that actually intersect the visible viewport `[offset, offset+height]`
  /// (dropping the ±overscan tails), in y-order.
  private func band(_ controller: DiffViewportController, offset: CGFloat, height: CGFloat) -> [PaintedRow] {
    paintedRows(controller).filter { $0.docTop < offset + height && $0.docTop + $0.height > offset }
  }

  /// Assert the painted rows tile `[offset, offset+height]` with no gap / overlap and start
  /// at (not below) the offset — the two ways a placement bug shows on screen.
  private func expectContiguousCover(_ rows: [PaintedRow], offset: CGFloat, label: String) {
    #expect(!rows.isEmpty, "\(label): viewport EMPTY")
    for pair in zip(rows, rows.dropFirst()) {
      let gap = pair.1.docTop - (pair.0.docTop + pair.0.height)
      #expect(abs(gap) < 0.5, "\(label): \(gap)px gap/overlap at y=\(pair.0.docTop)")
    }
    if let top = rows.first {
      #expect(top.docTop <= offset + 0.5, "\(label): top row at y=\(top.docTop), below the offset")
    }
  }

  // MARK: - Every visible document row is painted at its true y

  /// A 8_000-row uniform tree (all context, 20-px rows, distinct `"line{k}"`, NO widgets)
  /// so document row `k` MUST paint at `y = k * 20` with text `"line{k}"`. Scroll to a
  /// spread of offsets — including deep ones and both sides of the 5_000-row leaf seam.
  @Test(arguments: [DiffViewMode.unified, .split])
  func everyVisibleDocumentRowIsPaintedAtItsTrueY(mode: DiffViewMode) {
    let clip: CGFloat = 600
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: clip)
    let rowHeight = ChunkLayoutMetrics.production.lineHeight  // 20
    controller.apply(tree: ChunkTreeFixture.uniform(rows: 8_000) { "line\($0)" }, mode: mode, scrollPreserving: false)

    for offset in [CGFloat(0), 500, 4_980, 100_000, 60_000, 159_000] {
      controller.scroll(toY: offset)
      let painted = paintedRows(controller)
      #expect(!painted.isEmpty, "offset \(offset) [\(mode)]: nothing painted")
      for row in Int(offset / rowHeight)...Int((offset + clip) / rowHeight) {
        let expectedTop = CGFloat(row) * rowHeight
        let drawn = painted.first { abs($0.docTop - expectedTop) < 0.5 }
        #expect(drawn != nil, "offset \(offset) [\(mode)]: row \(row) at docY \(expectedTop) not painted")
        let content = mode == .unified ? drawn?.text.unified : drawn?.text.new
        #expect(content == "line\(row)", "offset \(offset) [\(mode)]: docY \(expectedTop) got \(content ?? "nil")")
      }
    }
  }

  // MARK: - The painted rows tile the visible band with no gap and no drift

  /// No-wrap baseline: the drawn rows covering the viewport are contiguous and cover it.
  @Test(arguments: [DiffViewMode.unified, .split])
  func paintedRowsTileTheVisibleBandContiguously(mode: DiffViewMode) {
    let clip: CGFloat = 600
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: clip)
    let rowHeight = ChunkLayoutMetrics.production.lineHeight
    controller.apply(tree: ChunkTreeFixture.uniform(rows: 8_000) { "line\($0)" }, mode: mode, scrollPreserving: false)

    for offset in [CGFloat(0), 3_333, 99_990, 120_000] {
      controller.scroll(toY: offset)
      let rows = band(controller, offset: offset, height: clip)
      #expect(
        rows.count >= Int(clip / rowHeight), "offset \(offset) [\(mode)]: only \(rows.count) rows cover the viewport")
      expectContiguousCover(rows, offset: offset, label: "offset \(offset) [\(mode)]")
    }
  }

  // MARK: - Wrapped content, MANY small leaves — the reported bug's shape

  /// MANY small single-row leaves (the shape a real multi-hunk changed file makes), each a
  /// LONG line that wraps to several sub-rows. A 600-px viewport spans MANY of these at once,
  /// so every leaf-to-leaf boundary is on screen — unlike one 5_000-row leaf whose interior
  /// rows are always contiguous. Each leaf's tree ESTIMATE is one 20-px row but its drawn
  /// height is ~80 px, so an un-reconciled placement overlaps adjacent leaves by ~60 px.
  private func manyWrappedLeaves(_ count: Int) -> ChunkTree {
    let tree = ChunkTree(metrics: .production)
    let hunkID = HunkID(fileID: "wrap", index: 0)
    let lines = (0..<count).map {
      DiffLine(
        origin: .context, oldLineNumber: $0 + 1, newLineNumber: $0 + 1,
        content: "line\($0) " + String(repeating: "token\($0) ", count: 30), noNewlineAtEof: false)
    }
    var after: ChunkID?
    for offset in lines.indices {
      let segment = LineSegment(hunkID: hunkID, lines: lines, window: offset..<(offset + 1), classification: .context)
      after = tree.insert(.lineSegment(segment), after: after)
    }
    return tree
  }

  /// THE REPRO. A scrollbar jump into MANY un-measured wrapped leaves must tile contiguously
  /// on the produced frame — the tree positions each leaf from its 1-row estimate while the
  /// view draws it wrapped-tall, so without in-frame measure convergence adjacent leaves
  /// overlap by ~60 px (the "page-2, only a few overlapping rows, changing each scroll" bug).
  @Test(arguments: [DiffViewMode.unified, .split])
  func jumpScrollManyWrappedLeavesTilesOnFirstPass(mode: DiffViewMode) {
    let clip: CGFloat = 600
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: clip)
    controller.apply(tree: manyWrappedLeaves(2_000), mode: mode, scrollPreserving: false)

    let total = controller.documentView.bounds.height
    for fraction in [0.3, 0.55, 0.8] as [CGFloat] {
      controller.scroll(toY: (total - clip) * fraction)
      let offset = controller.scrollView.contentView.bounds.origin.y
      expectContiguousCover(
        band(controller, offset: offset, height: clip), offset: offset, label: "[\(mode)] jump \(offset)")
    }
  }

  /// Same defect over one big wrapped leaf-set built from a single distinct-content segment.
  @Test(arguments: [DiffViewMode.unified, .split])
  func jumpScrollOnWrappedFileTilesOnTheFirstPass(mode: DiffViewMode) {
    let clip: CGFloat = 600
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: clip)
    let tree = ChunkTreeFixture.uniform(rows: 4_000) { "line\($0) " + String(repeating: "token\($0) ", count: 30) }
    controller.apply(tree: tree, mode: mode, scrollPreserving: false)

    let total = controller.documentView.bounds.height
    for fraction in [0.35, 0.6, 0.85] as [CGFloat] {
      controller.scroll(toY: (total - clip) * fraction)
      let offset = controller.scrollView.contentView.bounds.origin.y
      let rows = band(controller, offset: offset, height: clip)
      #expect(rows.count >= 3, "[\(mode)] jump \(offset): only \(rows.count) rows painted")
      expectContiguousCover(rows, offset: offset, label: "[\(mode)] jump \(offset)")
    }
  }

  /// After the app-like convergence pump the band tiles AND reaches the viewport bottom.
  @Test(arguments: [DiffViewMode.unified, .split])
  func wrappedRowsStillTileTheViewportAfterMeasure(mode: DiffViewMode) {
    let clip: CGFloat = 600
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: clip)
    let tree = ChunkTreeFixture.uniform(rows: 4_000) { "line\($0) " + String(repeating: "token\($0) ", count: 30) }
    controller.apply(tree: tree, mode: mode, scrollPreserving: false)

    let total = controller.documentView.bounds.height
    for fraction in [0.0, 0.25, 0.5, 0.8] as [CGFloat] {
      let offset = (total - clip) * fraction
      controller.scroll(toY: offset)
      for _ in 0..<8 { controller.layoutVisibleChunks() }
      let rows = band(controller, offset: offset, height: clip)
      expectContiguousCover(rows, offset: offset, label: "[\(mode)] offset \(offset)")
      if let bottom = rows.last {
        let end = bottom.docTop + bottom.height
        #expect(
          end >= offset + clip - 0.5 || end >= total - 0.5, "[\(mode)] offset \(offset): band ends short at \(end)")
      }
    }
  }
}
