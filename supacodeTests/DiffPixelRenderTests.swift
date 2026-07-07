import AppKit
import Testing

@testable import supacode

/// PIXEL-LEVEL RENDER (real CoreText draw into a bitmap). The geometry tests prove each
/// row is PLACED at the right y with the right content; these prove it actually PAINTS
/// pixels there. `documentView.cacheDisplay` forces the real `LineRowView.draw` (CoreText
/// glyphs + gutter) for every placed subview into an offscreen bitmap, and we assert every
/// materialized line leaf's band carries non-uniform pixels (glyphs/change-bar) — i.e. it
/// did not render blank. This is the "only one hunk renders, the rest is empty" bug's
/// draw-side guard: a leaf that is placed + visible but paints nothing fails here.
@MainActor
struct DiffPixelRenderTests {

  /// A 3-hunk file with distinct, change-bearing lines (so nothing collapses and every
  /// rendered row has glyphs). Built through the REAL `ChunkTreeBuilder`.
  private func threeHunkTree() -> ChunkTree {
    func hunk(_ base: Int, _ tag: String) -> DiffHunk {
      DiffFixture.hunk(
        [
          DiffFixture.line(.context, old: base, new: base, "\(tag) let context line \(base)"),
          DiffFixture.line(.deletion, old: base + 1, "\(tag) removed value \(base)"),
          DiffFixture.line(.addition, new: base + 1, "\(tag) inserted value \(base)"),
          DiffFixture.line(.context, old: base + 2, new: base + 2, "\(tag) trailing context \(base)"),
        ], oldStart: base, newStart: base, header: "@@ -\(base),3 +\(base),3 @@")
    }
    return ChunkTreeFixture.files([
      ChunkTreeFixture.FileSpec(
        file: DiffFixture.file(path: "Sample.swift"), hunks: [hunk(1, "A"), hunk(60, "B"), hunk(120, "C")])
    ])
  }

  /// The distinct colors sampled across a horizontal strip at `y` (bitmap space), over the
  /// content x-band. A blank (unpainted / uniform-fill) row yields ≤ 1 distinct color; a
  /// row that actually drew glyphs / a change-bar yields several.
  private func distinctColors(_ rep: NSBitmapImageRep, row yPos: Int) -> Int {
    guard yPos >= 0, yPos < rep.pixelsHigh else { return 0 }
    var seen = Set<String>()
    for col in stride(from: 4, to: min(rep.pixelsWide, 780), by: 3) {
      guard let color = rep.colorAt(x: col, y: yPos) else { continue }
      // Quantize to avoid AA noise blowing up the set.
      let key =
        "\(Int(color.redComponent * 16))-\(Int(color.greenComponent * 16))-\(Int(color.blueComponent * 16))"
      seen.insert(key)
    }
    return seen.count
  }

  /// ISOLATION: a STANDALONE `LineRowView` (configured directly, no documentView / layer)
  /// must paint glyphs + gutter into a bitmap. Tells apart a genuine `LineRowView.draw`
  /// defect from a documentView-recursion artefact in the whole-tree test below.
  @Test func standaloneLineRowViewPaintsGlyphs() throws {
    let lines = [
      DiffFixture.line(.context, old: 1, new: 1, "let alpha = compute(1)"),
      DiffFixture.line(.context, old: 2, new: 2, "let beta = compute(2)"),
      DiffFixture.line(.context, old: 3, new: 3, "let gamma = compute(3)"),
    ]
    let segment = LineSegment(
      hunkID: HunkID(fileID: "f", index: 0), lines: lines, window: 0..<3, classification: .context)
    let view = LineRowView()
    view.frame = CGRect(x: 0, y: 0, width: 800, height: 60)
    view.configure(
      segment: segment, chunkID: ChunkID(raw: 1), rowHeight: 20,
      font: .monospacedSystemFont(ofSize: 12, weight: .regular), mode: .unified)

    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds), "no rep")
    view.cacheDisplay(in: view.bounds, to: rep)
    let colorsMid = distinctColors(rep, row: 10)
    #expect(
      colorsMid > 1, "a standalone LineRowView painted BLANK (only \(colorsMid) color) — LineRowView.draw is broken")
  }

  @Test func everyMaterializedLineLeafPaintsPixels() throws {
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: 600)
    controller.apply(tree: threeHunkTree(), mode: .unified, scrollPreserving: false)

    let lineViews = (controller.pools[.line]?.used.values ?? [:].values)
      .compactMap { $0 as? LineRowView }
      .sorted { $0.frame.minY < $1.frame.minY }
    #expect(lineViews.count >= 6, "expected several line leaves across 3 hunks, got \(lineViews.count)")

    // Render each materialized (windowing-configured) leaf into its OWN bitmap and assert
    // it painted glyphs/gutter — the draw-side counterpart to the geometry tests. (The
    // "only one hunk shows" bug was `LineRowView.draw` filling the whole `dirtyRect` — the
    // viewport band — instead of its own bounds, erasing sibling leaves. Each leaf drawn in
    // isolation always painted fine, so it can only be seen when siblings share a context;
    // the fix is `bounds.fill()`, and this per-leaf guard at least pins that a leaf paints.)
    var painted = 0
    for view in lineViews {
      let bounds = CGRect(x: 0, y: 0, width: view.frame.width, height: view.frame.height)
      guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
      view.cacheDisplay(in: bounds, to: rep)
      let colors = distinctColors(rep, row: min(10, Int(bounds.height) - 1))
      #expect(
        colors > 1, "leaf at y=\(Int(view.frame.minY)) (h=\(Int(view.frame.height))) painted BLANK (\(colors) color)")
      if colors > 1 { painted += 1 }
    }
    #expect(painted == lineViews.count, "\(lineViews.count - painted)/\(lineViews.count) leaves painted nothing")
  }
}
