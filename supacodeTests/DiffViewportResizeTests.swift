import AppKit
import Testing

@testable import supacode

/// RESIZE FIDELITY. The reported bug: changing the viewport WIDTH did not re-tile /
/// re-wrap until the next scroll — a width change re-wraps every line and shifts the
/// total height, but the only relayout trigger was the clip's *bounds-origin* (scroll)
/// observer, never its *frame-size* (resize) change. `viewportResized()` (wired to
/// `frameDidChange`) closes that gap with an anchor-preserving relayout, mirroring
/// `styleDidChange`. These tests drive `viewportResized()` directly because the real
/// notification is delivered async on the main run loop, which a headless test never
/// spins.
@MainActor
struct DiffViewportResizeTests {

  /// One drawn row in DOCUMENT space, harvested from a materialized leaf.
  private struct PaintedRow {
    var docTop: CGFloat
    var height: CGFloat
    var text: LineRowView.VisibleRowText
  }

  private func paintedRows(_ controller: DiffViewportController) -> [PaintedRow] {
    var out: [PaintedRow] = []
    for anyView in (controller.pools[.line]?.used ?? [:]).values {
      guard let view = anyView as? LineRowView else { continue }
      let byLocal = Dictionary(
        view.visibleRowTexts.map { ($0.localRow, $0) }, uniquingKeysWith: { first, _ in first })
      for frame in view.typesetRowFrames {
        guard let text = byLocal[frame.localRow] else { continue }
        out.append(PaintedRow(docTop: view.frame.minY + frame.top, height: frame.height, text: text))
      }
    }
    return out.sorted { $0.docTop < $1.docTop }
  }

  /// The first row at/below the viewport top (the anchored row).
  private func topRow(_ controller: DiffViewportController, offset: CGFloat) -> PaintedRow? {
    paintedRows(controller).first { $0.docTop + $0.height > offset }
  }

  /// Simulate the AppKit resize the `frameDidChange` observer reacts to: re-tile the
  /// scroll view at the new width, then fire the handler the notification would.
  private func resize(_ controller: DiffViewportController, toWidth width: CGFloat, clipHeight: CGFloat) {
    controller.scrollView.frame = NSRect(x: 0, y: 0, width: width, height: clipHeight)
    controller.scrollView.tile()
    controller.viewportResized()
  }

  /// A narrower viewport re-wraps EVERY line, so the document grows taller — and it
  /// must do so on the resize itself, with NO intervening scroll or manual layout.
  @Test(arguments: [DiffViewMode.unified, .split])
  func narrowingReWrapsWithoutAScroll(mode: DiffViewMode) {
    let clip: CGFloat = 600
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: clip)
    let tree = ChunkTreeFixture.uniform(rows: 4_000) { "line\($0) " + String(repeating: "token\($0) ", count: 30) }
    controller.apply(tree: tree, mode: mode, scrollPreserving: false)
    // Warm the measured heights across a spread so the wide total reflects real wrapping.
    let wideTotal = controller.documentView.bounds.height

    resize(controller, toWidth: 320, clipHeight: clip)

    #expect(controller.documentView.bounds.width == 320, "[\(mode)] document width not re-fit to the clip")
    #expect(
      controller.documentView.bounds.height > wideTotal,
      "[\(mode)] narrower viewport did not grow the document — no re-wrap happened on resize")
    // The viewport is not left blank: rows are materialized at the new width.
    #expect(!band(controller, offset: 0, height: clip).isEmpty, "[\(mode)] viewport empty after resize")
  }

  /// A width change keeps the first visible line pinned to the viewport top (anchor
  /// preserved) instead of jumping — the content the user was reading stays put.
  @Test(arguments: [DiffViewMode.unified, .split])
  func resizePreservesTheAnchoredLine(mode: DiffViewMode) {
    let clip: CGFloat = 600
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: clip)
    // Single-line, non-wrapping leaves so the anchored line is unambiguous.
    let tree = ChunkTreeFixture.uniform(rows: 8_000) { "line\($0)" }
    controller.apply(tree: tree, mode: mode, scrollPreserving: false)

    let offset = (controller.documentView.bounds.height - clip) * 0.5
    controller.scroll(toY: offset)
    let before = topRow(controller, offset: controller.scrollView.contentView.bounds.origin.y)
    let beforeText = mode == .unified ? before?.text.unified : before?.text.new
    #expect(beforeText != nil, "[\(mode)] no anchored row before resize")

    resize(controller, toWidth: 500, clipHeight: clip)

    let newOffset = controller.scrollView.contentView.bounds.origin.y
    let after = topRow(controller, offset: newOffset)
    let afterText = mode == .unified ? after?.text.unified : after?.text.new
    #expect(afterText == beforeText, "[\(mode)] anchored line jumped: \(beforeText ?? "nil") → \(afterText ?? "nil")")
  }

  /// A height-only resize (same width) does not re-wrap — it re-tiles cheaply. Guards
  /// the `newWidth != lastLaidOutWidth` short-circuit.
  @Test
  func heightOnlyResizeKeepsTheWidthAndReTiles() {
    let clip: CGFloat = 600
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: clip)
    let tree = ChunkTreeFixture.uniform(rows: 4_000) { "line\($0) " + String(repeating: "token\($0) ", count: 30) }
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
    let total = controller.documentView.bounds.height

    resize(controller, toWidth: 800, clipHeight: 400)  // taller-clip / same width

    #expect(controller.documentView.bounds.width == 800)
    #expect(controller.documentView.bounds.height == total, "same width must not change the document height")
    #expect(!band(controller, offset: 0, height: 400).isEmpty, "viewport empty after a height-only resize")
  }

  private func band(_ controller: DiffViewportController, offset: CGFloat, height: CGFloat) -> [PaintedRow] {
    paintedRows(controller).filter { $0.docTop < offset + height && $0.docTop + $0.height > offset }
  }
}
