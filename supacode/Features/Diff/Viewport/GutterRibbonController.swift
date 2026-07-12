import AppKit
import QuartzCore

/// A logical selection point on the gutter — ported from pierre `SelectionPoint`
/// (`types.ts:837-840`). It is a **coordinate**, `(lineNumber, side)`, never a `y`
/// or a view reference, so it survives view recycle AND a re-measure.
nonisolated struct SelectionPoint: Equatable {
  let lineNumber: Int
  let side: DiffSide
}

/// The gutter interaction state machine — ported from pierre
/// `InteractionManager.ts:166-184`. A drag anchors on a `SelectionPoint` and
/// extends to another on the SAME side.
nonisolated enum PointerSession: Equatable {
  case idle
  case gutterSelecting(anchor: SelectionPoint, current: SelectionPoint)
}

/// A resolved gutter range ready to open a composer over.
nonisolated struct SelectionCommit: Equatable {
  let side: DiffSide
  let startLine: Int
  let endLine: Int
  let snippet: String
  let contextBefore: String
}

/// The cross-linked hover regions for the pierre `lineHoverHighlight: 'both'`
/// behavior (B §2): a hovered gutter number highlights BOTH its own number cell
/// AND the paired content row. Document-space rects.
nonisolated struct HoverHighlight: Equatable {
  /// The hovered gutter line.
  let line: SelectionPoint
  /// The paired content row — full width, so it spans BOTH columns in split.
  let contentRow: NSRect
  /// The hovered side's line-number gutter cell.
  let gutterNumber: NSRect
}

/// A transparent overlay over the diff viewport that owns the comment-gutter
/// interaction only. It reveals a "+" glyph on the hovered line's gutter and
/// supports a click (single line) or a drag (inclusive range), reporting the
/// resolved `(side, range, snippet, context)` up through `onOpenComposer`.
///
/// Ported from `DiffGutterRibbonView.swift:51-108` onto the Phase-2 **geometric
/// `hitTest`** (there is no per-line `NSView` to `elementFromPoint`): `y → chunk`
/// is an O(log n) tree seek, `x → column` a scan of the ≤ 6 x-bands. A
/// `PointerSession` drives it with pierre's `requireNumberColumn` rule — the
/// drag begins only on a line-number gutter column (`:748-751`) but the drag
/// endpoint may sit over content, with the side PINNED to the anchor (`:889-892`).
/// Edge autoscroll (`EdgeAutoscroller`) is OUR ADDITION (C8 — pierre has none).
@MainActor
final class GutterRibbonController: NSView {
  weak var controller: DiffViewportController?

  /// Emitted when a click or drag resolves to a line range. The representable
  /// wires it to `store.send(.review(.openCommentComposer(...)))`.
  var onOpenComposer:
    ((_ side: DiffSide, _ startLine: Int, _ endLine: Int, _ snippet: String, _ contextBefore: String) -> Void)?

  private(set) var session: PointerSession = .idle
  private var hover: SelectionPoint?
  private var trackingArea: NSTrackingArea?

  // Geometry cached straight off the forward `hitTest` so drawing seeks the row by
  // its global rendered-row INDEX (O(log n)) instead of reverse-resolving a
  // `(line, side)` coordinate to a row (an O(n) walk from row 0). These mirror the
  // logical `hover` / `session` state and are set at the same point.
  private var hoverRowIndex: Int?
  private var anchorRowIndex: Int?
  private var currentRowIndex: Int?

  // Edge autoscroll state (set during a drag; consumed by `autoscrollStep`).
  private var autoscroller: EdgeAutoscroller?
  private var autoscrollOvershoot: CGFloat = 0
  private var autoscrollDirection: CGFloat = 0

  override var isFlipped: Bool { true }

  // MARK: - Coordinate mapping

  /// The overlay sits over the clip view, so its local `y = 0` is the top of the
  /// visible rect; document `y` adds the scroll offset.
  private func documentPoint(from local: CGPoint) -> CGPoint {
    CGPoint(x: local.x, y: local.y + (controller?.visibleRect.minY ?? 0))
  }

  private func localRect(fromDocument rect: NSRect) -> NSRect {
    rect.offsetBy(dx: 0, dy: -(controller?.visibleRect.minY ?? 0))
  }

  // MARK: - Testable session core (document-space points)

  /// Begin a selection at a document-space point. `requireNumberColumn: true` on
  /// down (pierre `:748-751`) — a down off the number column starts NO session.
  /// Returns whether a session began.
  @discardableResult
  func beginSelection(atDocument point: CGPoint) -> Bool {
    guard let hit = controller?.hitTest(point), hit.column.isNumberColumn,
      let line = hit.lineNumber, let side = hit.side
    else { return false }
    let anchor = SelectionPoint(lineNumber: line, side: side)
    session = .gutterSelecting(anchor: anchor, current: anchor)
    anchorRowIndex = hit.rowIndex
    currentRowIndex = hit.rowIndex
    hover = nil
    hoverRowIndex = nil
    setNeedsDisplay(bounds)
    return true
  }

  /// Extend the active selection to a document-space point. `requireNumberColumn:
  /// false` on drag (pierre `:889-892`) — the endpoint may sit over content — and
  /// the side is PINNED to the anchor's side. An inert region (widget / comment /
  /// expander / a row with no number on the pinned side) resolves no line, so the
  /// range HOLDS.
  func extendSelection(toDocument point: CGPoint) {
    guard case .gutterSelecting(let anchor, _) = session else { return }
    guard let hit = controller?.hitTest(point, side: anchor.side), let line = hit.lineNumber else { return }
    let end = SelectionPoint(lineNumber: line, side: anchor.side)
    guard case .gutterSelecting(let anc, let current) = session, current != end else { return }
    session = .gutterSelecting(anchor: anc, current: end)
    currentRowIndex = hit.rowIndex
    setNeedsDisplay(bounds)
  }

  /// Commit the active selection: normalize a reversed range and anchor the "+"
  /// to the bottom-most selected line. Returns the resolved commit (and fires
  /// `onOpenComposer`), or `nil` when there is no active session.
  @discardableResult
  func commitSelection() -> SelectionCommit? {
    stopAutoscroll()
    defer {
      session = .idle
      hover = nil
      hoverRowIndex = nil
      anchorRowIndex = nil
      currentRowIndex = nil
      setNeedsDisplay(bounds)
    }
    guard case .gutterSelecting(let anchor, let current) = session, let controller else { return nil }
    let start = min(anchor.lineNumber, current.lineNumber)
    let last = max(anchor.lineNumber, current.lineNumber)
    let payload = controller.anchorPayload(side: anchor.side, startLine: start, endLine: last)
    onOpenComposer?(anchor.side, start, last, payload.snippet, payload.contextBefore)
    return SelectionCommit(
      side: anchor.side, startLine: start, endLine: last, snippet: payload.snippet, contextBefore: payload.contextBefore
    )
  }

  /// Abort the active selection without committing (cancel path).
  func cancelSelection() {
    stopAutoscroll()
    session = .idle
    hover = nil
    hoverRowIndex = nil
    anchorRowIndex = nil
    currentRowIndex = nil
    setNeedsDisplay(bounds)
  }

  // MARK: - Hover

  func updateHover(atDocument point: CGPoint) {
    let resolved: SelectionPoint?
    let resolvedRow: Int?
    if let hit = controller?.hitTest(point), hit.column.isNumberColumn, let line = hit.lineNumber, let side = hit.side {
      resolved = SelectionPoint(lineNumber: line, side: side)
      resolvedRow = hit.rowIndex  // keep the geometric row so drawing seeks by index, not by line
    } else {
      resolved = nil
      resolvedRow = nil
    }
    guard hover != resolved else { return }
    hover = resolved
    hoverRowIndex = resolvedRow
    setNeedsDisplay(bounds)
  }

  /// The cross-linked hover highlight (pierre `lineHoverHighlight: 'both'`, B §2):
  /// a hovered gutter number highlights BOTH its own number cell AND the paired
  /// content row across every column. `nil` when nothing is hovered. The row rect
  /// is derived LIVE each read from the hovered row's INDEX (`lineRect(rowIndex:)`,
  /// an O(log n) `seek`), so it re-measures against the current geometry (B §2) —
  /// the index is the geometric identity the forward `hitTest` produced, not a
  /// cached rect. Exposed so a headless test asserts the cross-link (there is no
  /// window to sample pixels).
  var hoverHighlight: HoverHighlight? {
    guard let hover, let controller, let rowIndex = hoverRowIndex,
      let row = controller.lineRect(rowIndex: rowIndex)
    else { return nil }
    return HoverHighlight(
      line: hover,
      contentRow: row,
      gutterNumber: Self.gutterNumberRect(
        for: hover, row: row, mode: controller.mode, gutterWidth: controller.gutterWidth)
    )
  }

  /// The hovered side's line-number gutter cell (document space), mode-correct via
  /// `DiffHitTest.bands` — the "gutter number" half of the pierre `both` cross-link.
  private static func gutterNumberRect(
    for point: SelectionPoint, row: NSRect, mode: DiffViewMode, gutterWidth: CGFloat
  ) -> NSRect {
    let bands = DiffHitTest.bands(mode: mode, width: row.width, gutterW: gutterWidth)
    guard let band = bands.first(where: { $0.column == .gutter(point.side) }) else { return .zero }
    return NSRect(
      x: band.range.lowerBound, y: row.minY, width: band.range.upperBound - band.range.lowerBound, height: row.height)
  }

  // MARK: - Edge autoscroll (OUR ADDITION — C8)

  /// Update the autoscroll intent from the drag pointer's LOCAL y. Past the top
  /// edge scrolls up, past the bottom edge scrolls down, inside the visible rect
  /// is a dead-zone (stops).
  func updateAutoscroll(pointerLocalY: CGFloat) {
    if pointerLocalY < 0 {
      autoscrollOvershoot = -pointerLocalY
      autoscrollDirection = -1
      startAutoscrollIfNeeded()
    } else if pointerLocalY > bounds.height {
      autoscrollOvershoot = pointerLocalY - bounds.height
      autoscrollDirection = 1
      startAutoscrollIfNeeded()
    } else {
      autoscrollOvershoot = 0
      autoscrollDirection = 0
      stopAutoscroll()
    }
  }

  /// One autoscroll frame: advance the scroll by `velocity·dt` in the pinned
  /// direction, then re-`hitTest` the pinned near edge to advance the end line.
  /// Public so a headless test can drive it with an injected `dt` (no live link).
  func autoscrollStep(dt deltaTime: CFTimeInterval) {
    guard case .gutterSelecting = session, let controller, autoscrollDirection != 0 else { return }
    let velocity = EdgeAutoscroller.velocity(overshoot: autoscrollOvershoot)
    guard velocity > 0 else { return }
    let deltaY = autoscrollDirection * velocity * CGFloat(deltaTime)
    controller.scroll(toY: controller.visibleRect.minY + deltaY)
    // Re-hitTest the pinned near edge (x is irrelevant — `hitTest(_:side:)` reads
    // the line on the pinned side regardless of column).
    let edgeLocalY: CGFloat = autoscrollDirection > 0 ? bounds.height - 1 : 1
    extendSelection(toDocument: documentPoint(from: CGPoint(x: 0, y: edgeLocalY)))
  }

  private func startAutoscrollIfNeeded() {
    // Only drive a live display link when actually on-screen; a headless test sets
    // the overshoot / direction via `updateAutoscroll` and calls `autoscrollStep`
    // with an injected `dt` directly (no live link off-window).
    guard autoscroller == nil, window != nil else { return }
    autoscroller = EdgeAutoscroller(view: self) { [weak self] deltaTime in
      self?.autoscrollStep(dt: deltaTime)
    }
  }

  private func stopAutoscroll() {
    autoscroller?.stop()
    autoscroller = nil
    autoscrollOvershoot = 0
    autoscrollDirection = 0
  }

  // MARK: - NSResponder event routing

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

  /// Only intercept events on a line's number gutter (or during an active drag);
  /// everything else falls through to the viewport (expander clicks, comment taps).
  override func hitTest(_ point: NSPoint) -> NSView? {
    if case .gutterSelecting = session { return self }
    guard let controller, let superview else { return nil }
    let doc = documentPoint(from: convert(point, from: superview))
    guard let hit = controller.hitTest(doc), hit.column.isNumberColumn, hit.lineNumber != nil else { return nil }
    return self
  }

  override func mouseMoved(with event: NSEvent) {
    updateHover(atDocument: documentPoint(from: convert(event.locationInWindow, from: nil)))
  }

  override func mouseExited(with event: NSEvent) {
    updateHover(atDocument: CGPoint(x: -1, y: -1))
  }

  /// Forward wheel events to the scroll view rather than swallowing them.
  override func scrollWheel(with event: NSEvent) {
    nextResponder?.scrollWheel(with: event)
  }

  override func mouseDown(with event: NSEvent) {
    let doc = documentPoint(from: convert(event.locationInWindow, from: nil))
    if !beginSelection(atDocument: doc) { super.mouseDown(with: event) }
  }

  override func mouseDragged(with event: NSEvent) {
    guard case .gutterSelecting = session else { return }
    let local = convert(event.locationInWindow, from: nil)
    extendSelection(toDocument: documentPoint(from: local))
    updateAutoscroll(pointerLocalY: local.y)
  }

  override func mouseUp(with event: NSEvent) {
    _ = commitSelection()
  }

  // MARK: - Draw

  override func draw(_ dirtyRect: NSRect) {
    guard let controller else { return }
    if case .gutterSelecting = session {
      drawDragBand(controller: controller)
    } else if let highlight = hoverHighlight {
      drawHoverHighlight(highlight)
      // Reuse the row rect the highlight already resolved — no second row lookup.
      drawPlusGlyph(for: highlight.line, docRect: highlight.contentRow, controller: controller)
    }
  }

  /// Paint the pierre `both` cross-link (B §2): a subtle full-width wash on the
  /// hovered content row (both columns) plus a stronger highlight on the hovered
  /// side's gutter number cell.
  private func drawHoverHighlight(_ highlight: HoverHighlight) {
    let rowLocal = localRect(fromDocument: highlight.contentRow)
    guard !rowLocal.isEmpty else { return }
    NSColor.controlAccentColor.withAlphaComponent(0.06).setFill()
    rowLocal.fill()
    let numberLocal = localRect(fromDocument: highlight.gutterNumber)
    NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
    numberLocal.fill()
  }

  private func drawPlusGlyph(for target: SelectionPoint, docRect: NSRect, controller: DiffViewportController) {
    let rowRect = localRect(fromDocument: docRect)
    guard !rowRect.isEmpty else { return }
    let diameter = min(rowRect.height - 2, 16)
    let gutter = controller.gutterWidth
    let bar = DiffHitTest.changeBarWidth
    let centerX = target.side == .old ? bar + gutter * 0.5 : bar + gutter + bar + gutter * 0.5
    let origin = NSPoint(x: max(1, centerX - diameter / 2), y: rowRect.midY - diameter / 2)
    let glyphRect = NSRect(origin: origin, size: NSSize(width: diameter, height: diameter))
    let config = NSImage.SymbolConfiguration(pointSize: diameter, weight: .semibold)
    guard
      let image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: "Comment on this line")?
        .withSymbolConfiguration(config)
    else { return }
    image.isTemplate = true
    NSColor.controlAccentColor.set()
    image.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    toolTip = "Comment on this line — drag to select a range"
  }

  private func drawDragBand(controller: DiffViewportController) {
    // Both endpoints seek by their cached rendered-row INDEX (O(log n)); the anchor's
    // index stays valid as it scrolls offscreen during an autoscroll drag.
    guard let anchorIndex = anchorRowIndex, let currentIndex = currentRowIndex,
      let anchorDoc = controller.lineRect(rowIndex: anchorIndex),
      let currentDoc = controller.lineRect(rowIndex: currentIndex)
    else { return }
    let band = localRect(fromDocument: anchorDoc).union(localRect(fromDocument: currentDoc))
    NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
    band.fill()
  }
}

/// Edge autoscroll on `NSView.displayLink` (D1 — NOT `CVDisplayLink`, deprecated
/// in macOS 15). A quadratic velocity ramp: 0 inside the visible rect (dead-zone),
/// ramping to `vmax` once the pointer sits `saturate` px past the near edge. The
/// per-frame `dt` comes from `CADisplayLink.targetTimestamp − .timestamp`.
@MainActor
final class EdgeAutoscroller {
  /// Pixels past the edge at which the ramp saturates.
  static let saturate: CGFloat = 120
  /// Peak scroll speed (px/s).
  static let vmax: CGFloat = 900

  /// Whether the display link is live. Flips `false` on `stop()` so a test can
  /// assert the link stopped on unmount (B §20).
  private(set) var isActive = false

  private var link: CADisplayLink?
  private let onFrame: (_ deltaTime: CFTimeInterval) -> Void

  init(view: NSView, onFrame: @escaping (CFTimeInterval) -> Void) {
    self.onFrame = onFrame
    let link = view.displayLink(target: self, selector: #selector(tick))
    link.add(to: .main, forMode: .common)
    self.link = link
    isActive = true
  }

  deinit { link?.invalidate() }

  /// Quadratic ramp: 0 in the dead-zone (`overshoot ≤ 0`), then `vmax·ramp²` with
  /// `ramp = min(overshoot / saturate, 1)`, saturating at `vmax` for `overshoot ≥
  /// saturate`.
  static func velocity(overshoot: CGFloat) -> CGFloat {
    guard overshoot > 0 else { return 0 }
    let ramp = min(overshoot / saturate, 1)
    return vmax * ramp * ramp
  }

  func stop() {
    link?.invalidate()
    link = nil
    isActive = false
  }

  @objc private func tick(_ link: CADisplayLink) {
    onFrame(link.targetTimestamp - link.timestamp)
  }
}
