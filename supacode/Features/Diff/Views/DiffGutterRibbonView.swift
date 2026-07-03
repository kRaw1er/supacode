import AppKit

/// A transparent overlay over the diff viewport that owns the comment gutter
/// interaction only — it holds no comment state. It reveals a "+" glyph on the
/// hovered line's gutter, supports a click (single line) or a drag (inclusive
/// range), and reports the resolved `(side, range, snippet, context)` up via
/// `onOpenComposer`. All row/geometry lookups go through the Phase-3
/// `DiffTableController`; this is a row-index gesture that never touches the
/// diff text's selection.
final class DiffGutterRibbonView: NSView {
  weak var controller: DiffTableController?

  /// Emitted when a click or drag resolves to a line range. The representable
  /// wires it to `store.send(.review(.openCommentComposer(...)))`.
  var onOpenComposer:
    ((_ side: DiffSide, _ startLine: Int, _ endLine: Int, _ snippet: String, _ contextBefore: String) -> Void)?

  private var trackingArea: NSTrackingArea?
  private var hoverTarget: DiffTableController.CommentTarget?
  /// Active drag: the anchor target plus the current end target on the same side.
  private var dragAnchor: DiffTableController.CommentTarget?
  private var dragEnd: DiffTableController.CommentTarget?

  override var isFlipped: Bool { true }
  /// Purely an event/hover overlay; never draws a background so the diff shows through.
  override var wantsDefaultClipping: Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingArea = area
  }

  /// Only intercept events on a line's gutter band; everything else falls
  /// through to the diff cells (expander clicks, comment-thread taps).
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let superview else { return nil }
    let local = convert(point, from: superview)
    return controller?.commentTarget(at: local, from: self) != nil ? self : nil
  }

  // MARK: - Hover

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    updateHover(controller?.commentTarget(at: point, from: self))
  }

  override func mouseExited(with event: NSEvent) {
    updateHover(nil)
  }

  /// The overlay sits above the clip view, so forward wheel events to the scroll
  /// view instead of swallowing them on the gutter band.
  override func scrollWheel(with event: NSEvent) {
    nextResponder?.scrollWheel(with: event)
  }

  private func updateHover(_ target: DiffTableController.CommentTarget?) {
    guard hoverTarget != target else { return }
    let previous = hoverTarget
    hoverTarget = target
    if let previous, let rect = controller?.rowRect(previous.rowIndex, in: self) { setNeedsDisplay(rect) }
    if let target, let rect = controller?.rowRect(target.rowIndex, in: self) { setNeedsDisplay(rect) }
  }

  // MARK: - Click + drag

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard let anchor = controller?.commentTarget(at: point, from: self) else {
      super.mouseDown(with: event)
      return
    }
    dragAnchor = anchor
    dragEnd = anchor
    hoverTarget = nil
    setNeedsDisplay(bounds)
  }

  override func mouseDragged(with event: NSEvent) {
    guard let anchor = dragAnchor else { return }
    let point = convert(event.locationInWindow, from: nil)
    guard let current = controller?.commentTarget(at: point, from: self, side: anchor.side) else { return }
    guard dragEnd != current else { return }
    dragEnd = current
    setNeedsDisplay(bounds)
  }

  override func mouseUp(with event: NSEvent) {
    defer {
      dragAnchor = nil
      dragEnd = nil
      setNeedsDisplay(bounds)
    }
    guard let anchor = dragAnchor, let end = dragEnd, let controller else { return }
    let start = min(anchor.line, end.line)
    let last = max(anchor.line, end.line)
    let payload = controller.anchorPayload(side: anchor.side, startLine: start, endLine: last)
    onOpenComposer?(anchor.side, start, last, payload.snippet, payload.contextBefore)
  }

  // MARK: - Draw

  override func draw(_ dirtyRect: NSRect) {
    guard let controller else { return }
    if let anchor = dragAnchor, let end = dragEnd {
      drawDragBand(anchor: anchor, end: end, controller: controller)
    } else if let hoverTarget {
      drawPlusGlyph(for: hoverTarget, controller: controller)
    }
  }

  private func drawPlusGlyph(for target: DiffTableController.CommentTarget, controller: DiffTableController) {
    let rowRect = controller.rowRect(target.rowIndex, in: self)
    guard !rowRect.isEmpty else { return }
    let diameter = min(rowRect.height - 2, 16)
    let gutter = controller.gutterBandWidth
    let centerX = target.side == .old ? gutter * 0.5 : gutter * 1.5
    let origin = NSPoint(x: max(1, centerX - diameter / 2), y: rowRect.midY - diameter / 2)
    let glyphRect = NSRect(origin: origin, size: NSSize(width: diameter, height: diameter))
    let config = NSImage.SymbolConfiguration(pointSize: diameter, weight: .semibold)
    guard
      let image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: "Comment on this line")?
        .withSymbolConfiguration(config)
    else { return }
    let tinted = image
    tinted.isTemplate = true
    NSColor.controlAccentColor.set()
    tinted.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    toolTip = "Comment on this line — drag to select a range"
  }

  private func drawDragBand(
    anchor: DiffTableController.CommentTarget,
    end: DiffTableController.CommentTarget,
    controller: DiffTableController
  ) {
    let anchorRect = controller.rowRect(anchor.rowIndex, in: self)
    let endRect = controller.rowRect(end.rowIndex, in: self)
    guard !anchorRect.isEmpty, !endRect.isEmpty else { return }
    let band = anchorRect.union(endRect)
    NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
    band.fill()
  }
}
