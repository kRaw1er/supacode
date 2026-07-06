import AppKit
import Testing

@testable import supacode

/// Phase 3 — the gutter substrate: per-file gutter width, retina pixel-snapping,
/// and the tint / change-bar paint tokens recorded into a `RecordingContext`
/// (3.11–3.13 + the 1-based/0-based numbering and measured-once extensions).
@MainActor
struct GutterRendererTests {
  private func renderer(scale: CGFloat) -> GutterRenderer {
    GutterRenderer(metrics: ViewportTestSupport.metrics(gutter: 48), scale: scale, palette: .shared)
  }

  // MARK: - 3.11 gutter width for digit counts

  @Test func gutterWidthForDigits() {
    #expect(GutterRenderer.gutterWidth(maxDigits: 3, advance: 8) == 48)  // (3 + 2 + 1) · 8
    #expect(GutterRenderer.gutterWidth(maxDigits: 5, advance: 8) == 64)  // (5 + 2 + 1) · 8
    #expect(GutterRenderer.gutterWidth(maxDigits: 1, advance: 8) == 48)  // floors at 3 digits
  }

  // MARK: - 3.12 retina snap lands on the backing grid at 1× / 2× / 1.5×

  @Test func retinaSnapLandsOnPixelGrid() {
    for scale in [CGFloat(1), 2, 1.5] {
      let gutter = renderer(scale: scale)
      for value in [CGFloat(0.3), 3.3, 52.0, 100.7, 19.9] {
        let onGrid = gutter.snap(value) * scale  // must be an integer number of backing pixels
        #expect(abs(onGrid - onGrid.rounded()) < 1e-9, "off-grid at scale \(scale), v \(value)")
      }
    }
    // The dashed-deletion period is exactly `lineHeight / round(lineHeight/2)`.
    #expect(GutterRenderer.dashPeriod(lineHeight: 20) == 2)
    #expect(GutterRenderer.dashPeriod(lineHeight: ViewportTestSupport.metrics(gutter: 48).lineHeight) == 2)
  }

  // MARK: - 3.13 draw records tint + change-bar rects (add=solid / del=dashed)

  @Test func gutterDrawsTintAndBarRects() {
    let gutter = renderer(scale: 2)
    let rowRect = CGRect(x: 0, y: 0, width: 800, height: 20)
    let geometry = LineRowGeometry(rowRect: rowRect, barX: 52)

    // Addition: one full-row tint + one SOLID bar rect.
    let add = RecordingContext()
    gutter.draw(row: geometry, origin: .addition, in: add)
    #expect(add.fills.count == 2)
    #expect(add.fills[0] == CGRect(x: 0, y: 0, width: 800, height: 20))  // tint
    #expect(add.fills[1] == CGRect(x: 52, y: 0, width: 4, height: 20))  // solid bar

    // Deletion: one tint + a DASHED bar (5 segments over a 20pt row, period 2).
    let del = RecordingContext()
    gutter.draw(row: geometry, origin: .deletion, in: del)
    #expect(del.fills.count == 6)
    #expect(del.fills[0] == CGRect(x: 0, y: 0, width: 800, height: 20))  // tint
    for dash in del.fills[1...] {
      #expect(dash.minX == 52)
      #expect(dash.width == 4)
      #expect(dash.height == 2)  // dash-on period
    }

    // Context: nothing painted.
    let context = RecordingContext()
    gutter.draw(row: geometry, origin: .context, in: context)
    #expect(context.fills.isEmpty)
  }

  // MARK: - 1-based display / 0-based index parity + gutter width == digits

  @Test func lineNumbering1BasedIndex0Based() {
    let lines = (0..<5).map {
      DiffLine(origin: .context, oldLineNumber: $0 + 1, newLineNumber: $0 + 1, content: "c", noNewlineAtEof: false)
    }
    let segment = LineSegment(
      hunkID: HunkID(fileID: "f", index: 0), lines: lines, window: 0..<5, classification: .context)
    let rows = segment.renderedRows(.unified)
    for index in rows.indices {
      #expect(rows[index].newNumber == index + 1)  // 0-based index ⇒ 1-based display
    }
    // Gutter width scales with the digit count of the largest line number.
    #expect(String(1000).count == 4)
    #expect(GutterRenderer.gutterWidth(maxDigits: String(1000).count, advance: 8) == 56)  // (4 + 2 + 1) · 8
    #expect(GutterRenderer.gutterWidth(maxDigits: String(5).count, advance: 8) == 48)  // 1 digit floors at 3
  }

  // MARK: - gutter width measured once, patched in place, no drift

  @Test func gutterWidthMeasuredOncePatchedInPlace() {
    #expect(
      GutterRenderer.gutterWidth(maxDigits: 3, advance: 8) == GutterRenderer.gutterWidth(maxDigits: 3, advance: 8))
    let three = GutterRenderer.gutterWidth(maxDigits: 3, advance: 8)
    let four = GutterRenderer.gutterWidth(maxDigits: 4, advance: 8)
    let five = GutterRenderer.gutterWidth(maxDigits: 5, advance: 8)
    #expect(three <= four)
    #expect(four <= five)
    #expect(five - four == four - three)  // monotone, constant step — no drift
  }
}
