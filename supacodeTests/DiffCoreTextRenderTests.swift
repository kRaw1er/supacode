import AppKit
import Testing

@testable import supacode

/// Phase 3 — the render-layer integration: a wrapped line's measured height flows
/// back into the chunk-tree (3.9, NSVIEW-HEADLESS), the row view re-measures on a
/// width change, and the canonical full-fidelity render golden (`renderGoldenSingleFixture`,
/// CT-HEADLESS; StyleRun colors fill in at Phase 4).
@MainActor
struct DiffCoreTextRenderTests {
  private func context(width: CGFloat, mode: DiffViewMode = .unified) -> LineRowRenderContext {
    LineRowRenderContext(
      metrics: .resolve(),
      rowHeight: ChunkLayoutMetrics.production.lineHeight,
      mode: mode,
      width: width,
      cache: CTLineCache(),
      palette: .shared,
      styleGeneration: 0
    )
  }

  private func longLineSegment(_ content: String) -> LineSegment {
    LineSegment(
      hunkID: HunkID(fileID: "f", index: 0),
      lines: [DiffLine(origin: .context, oldLineNumber: 1, newLineNumber: 1, content: content, noNewlineAtEof: false)],
      window: 0..<1,
      classification: .context
    )
  }

  // MARK: - 3.9 measured (wrapped) height flows into the tree

  @Test func measuredHeightFlowsToTree() {
    let controller = ViewportTestSupport.controller(width: 400, clipHeight: 600)
    let tree = ChunkTree()
    let content = String(repeating: "word ", count: 200)  // ~1000 chars ⇒ wraps at 400pt
    _ = tree.insert(.lineSegment(longLineSegment(content)), after: nil)

    let estimate = tree.totalHeight(.unified)  // one row × 20pt before measurement
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)

    // The wrapped height reached `setMeasuredHeight`: the tree (and the document)
    // grew, and the C7 guard fired.
    #expect(tree.totalHeight(.unified) > estimate)
    #expect(controller.measurePass > 0)
    #expect(abs(controller.documentView.frame.height - tree.totalHeight(.unified)) < 0.5)  // scrollbar correct
  }

  // MARK: - re-measure on a width (word-wrap) change

  @Test func lineRowViewReMeasuresOnWidthChange() {
    let view = LineRowView()
    let segment = longLineSegment(String(repeating: "abcd ", count: 120))  // 600 chars

    view.configure(segment: segment, chunkID: ChunkID(raw: 1), context: context(width: 300))
    let narrow = view.measuredRowHeights
    #expect(narrow.count == 1)
    #expect(narrow[0] > ChunkLayoutMetrics.production.lineHeight)  // wrapped
    #expect(narrow[0].truncatingRemainder(dividingBy: ChunkLayoutMetrics.production.lineHeight) == 0)  // whole rows

    view.configure(segment: segment, chunkID: ChunkID(raw: 1), context: context(width: 2000))
    let wide = view.measuredRowHeights
    #expect(wide[0] < narrow[0])  // wider ⇒ fewer sub-lines ⇒ shorter, no jump
    #expect(view.totalMeasuredHeight == wide[0])
  }

  // MARK: - renderGoldenSingleFixture (structure + gutter substrate; colors at P4)

  @Test func renderGoldenSingleFixture() {
    // A tiny "file": one change segment (a deletion + an addition) and one context
    // segment — covers all three origins the substrate must draw.
    let change = LineSegment(
      hunkID: HunkID(fileID: "a.swift", index: 0),
      lines: [
        DiffLine(origin: .deletion, oldLineNumber: 41, newLineNumber: nil, content: "let x = 1", noNewlineAtEof: false),
        DiffLine(origin: .addition, oldLineNumber: nil, newLineNumber: 41, content: "let x = 2", noNewlineAtEof: false),
      ],
      window: 0..<2,
      classification: .change
    )
    let contextSegment = LineSegment(
      hunkID: HunkID(fileID: "a.swift", index: 0),
      lines: [
        DiffLine(origin: .context, oldLineNumber: 42, newLineNumber: 42, content: "return x", noNewlineAtEof: false)
      ],
      window: 0..<1,
      classification: .context
    )

    // 1. Structure: the change leaf lays out 2 rows, the context leaf 1, all short
    //    (unwrapped) ⇒ exactly one row height each.
    let changeView = LineRowView()
    changeView.configure(segment: change, chunkID: ChunkID(raw: 1), context: context(width: 800))
    #expect(changeView.measuredRowHeights == [20, 20])
    #expect(changeView.firstRowText == "let x = 1")

    let contextView = LineRowView()
    contextView.configure(segment: contextSegment, chunkID: ChunkID(raw: 2), context: context(width: 800))
    #expect(contextView.measuredRowHeights == [20])
    #expect(contextView.firstRowText == "return x")

    // 2. Full draw path (CTLineDraw + numbers + gutter) completes headlessly.
    drawHeadless(changeView, height: 40)
    drawHeadless(contextView, height: 20)

    // 3. I5 render-model golden — the whole "file" as a deterministic, appearance-
    //    independent snapshot: every rendered row (class · old/new · height · content)
    //    IN ORDER plus the gutter substrate token pattern per origin (exact rects, not
    //    pixels). Locks row order + gutter substrate; regenerate with UPDATE_GOLDEN=1
    //    and review by hand.
    let gutter = GutterRenderer(metrics: ViewportTestSupport.metrics(gutter: 48), scale: 2, palette: .shared)
    let geometry = LineRowGeometry(rowRect: CGRect(x: 0, y: 0, width: 800, height: 20), barX: 52)
    var digest = ""
    digest += renderModelRows(changeView, segment: change)
    digest += renderModelRows(contextView, segment: contextSegment)
    for origin in [DiffLineOrigin.deletion, .addition, .context] {
      digest += gutterSubstrate(gutter, geometry: geometry, origin: origin)
    }
    GoldenText.assert(digest, "renderSingleFixture")
  }

  /// One line per rendered row: `class · o<old>/n<new> · h<height> · "<content>"`, in
  /// document order — content read back from the configured view, class/numbers from the
  /// projected rows.
  private func renderModelRows(_ view: LineRowView, segment: LineSegment) -> String {
    let rows = segment.renderedRows(.unified)
    var textByRow: [Int: String] = [:]
    for text in view.visibleRowTexts { textByRow[text.localRow] = text.unified ?? "" }
    return rows.indices
      .map { index in
        let row = rows[index]
        let old = row.oldNumber.map(String.init) ?? "-"
        let new = row.newNumber.map(String.init) ?? "-"
        let height = view.measuredRowHeights[index]
        return "row \(classLabel(row.origin)) · o\(old)/n\(new) · h\(height) · \"\(textByRow[index] ?? "")\"\n"
      }
      .joined()
  }

  /// The gutter substrate token pattern for one origin: `gutter <class>: <n> [rects]`
  /// (exact recorded fill rects: deletion ⇒ tint + dashed; addition ⇒ tint + solid;
  /// context ⇒ none).
  private func gutterSubstrate(_ gutter: GutterRenderer, geometry: LineRowGeometry, origin: DiffLineOrigin) -> String {
    let recorder = RecordingContext()
    gutter.draw(row: geometry, origin: origin, in: recorder)
    let rects = recorder.fills
      .map { "\($0.minX),\($0.minY),\($0.width),\($0.height)" }
      .joined(separator: ";")
    return "gutter \(classLabel(origin)): \(recorder.fills.count) [\(rects)]\n"
  }

  private func classLabel(_ origin: DiffLineOrigin) -> String {
    switch origin {
    case .context: "ctx"
    case .addition: "add"
    case .deletion: "del"
    case .noNewlineMarker: "nonl"
    }
  }

  // MARK: - B §3 — a palette swap invalidates recycled views (no stale glyph cache)

  @Test func paletteSwapInvalidatesRecycledViews() {
    let cache = CTLineCache()
    let segment = LineSegment(
      hunkID: HunkID(fileID: "f", index: 0),
      lines: [
        DiffLine(
          origin: .context, oldLineNumber: 1, newLineNumber: 1, content: "let recycled = true", noNewlineAtEof: false)
      ],
      window: 0..<1,
      classification: .context
    )
    func recycleContext(styleGeneration: Int) -> LineRowRenderContext {
      LineRowRenderContext(
        metrics: CoreTextHarness.metrics,
        rowHeight: CoreTextHarness.lineHeight,
        mode: .unified,
        width: 800,
        cache: cache,  // the shared glyph cache the recycle pool reads through
        palette: .shared,
        styleGeneration: styleGeneration
      )
    }

    let gen0 = DiffPalette.shared.styleGeneration
    let view = LineRowView()  // the recyclable shell reused across palettes
    view.configure(segment: segment, chunkID: ChunkID(raw: 1), context: recycleContext(styleGeneration: gen0))
    #expect(cache.count == 1)  // typeset one wrapped line under the current generation

    // A palette / theme swap: bump the generation and drop the shared glyph cache
    // — exactly `DiffViewportController.styleDidChange`.
    DiffPalette.shared.styleDidChange()
    cache.invalidateStyle()
    let gen1 = DiffPalette.shared.styleGeneration
    #expect(gen1 == gen0 + 1)
    #expect(cache.count == 0)  // the pre-swap glyphs are gone — no stale cache survives

    // Recycle the SAME shell under the new generation → it re-typesets fresh (a
    // cache miss, one new entry), never a stale hit; the row shows re-rendered text.
    view.configure(segment: segment, chunkID: ChunkID(raw: 1), context: recycleContext(styleGeneration: gen1))
    #expect(cache.count == 1)
    #expect(view.firstRowText == "let recycled = true")

    // The generation is part of the cache key, so a pre-swap render can never serve
    // post-swap glyphs: re-rendering at the OLD generation mints a DISTINCT entry.
    let stale = LineRowView()
    stale.configure(segment: segment, chunkID: ChunkID(raw: 2), context: recycleContext(styleGeneration: gen0))
    #expect(cache.count == 2)  // gen0 and gen1 occupy separate cache namespaces
  }

  /// Run a row view's `draw(_:)` into an offscreen bitmap context (no window).
  private func drawHeadless(_ view: LineRowView, height: CGFloat) {
    let bitmap = CoreTextHarness.context(width: 800, height: height, scale: 2)
    let graphics = NSGraphicsContext(cgContext: bitmap, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    view.frame = CGRect(x: 0, y: 0, width: 800, height: max(height, view.totalMeasuredHeight))
    view.draw(view.bounds)
    NSGraphicsContext.restoreGraphicsState()
  }
}
