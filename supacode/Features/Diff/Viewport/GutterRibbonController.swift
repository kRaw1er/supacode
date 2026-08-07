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
  /// down (pierre `:748-751`) — a down off the number column starts NO session —
  /// EXCEPT on the revealed "+" itself, which seeds the session on its own line
  /// (pierre `handlePointerDown` → `startGutterSelectionFromPointerDown` for a
  /// `isGutterUtilityPath` hit, `:729-734`). Without that branch the button is inert:
  /// it hangs outside the number band, so a click on it resolves to no line.
  /// Returns whether a session began.
  @discardableResult
  func beginSelection(atDocument point: CGPoint) -> Bool {
    if let onButton = hoveredLineIfOnPlusButton(document: point) {
      session = .gutterSelecting(anchor: onButton, current: onButton)
      anchorRowIndex = hoverRowIndex
      currentRowIndex = hoverRowIndex
      hover = nil
      hoverRowIndex = nil
      setNeedsDisplay(bounds)
      return true
    }
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
    // The revealed "+" overhangs its number column, so a pointer moving ONTO the button
    // has left the number band — resolving the hover from the band alone would clear the
    // very affordance the user is reaching for (it vanishes under the cursor). In pierre
    // this cannot happen: the button is a DOM CHILD of the number cell
    // (`showUtilityOnLine` → `numberElement.appendChild`, `:1136-1142`), so it is part of
    // the hovered element. We have no view per line, so the button's rect joins the
    // hovered line's region explicitly — the geometric equivalent of that containment.
    if hoveredLineIfOnPlusButton(document: point) != nil { return }
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

  /// The currently hovered line when `point` (document space) lands on ITS revealed "+"
  /// button, else `nil`. The button only exists while a line is hovered, so this is both
  /// the "keep the hover alive" test and the "the click hit the button" test.
  func hoveredLineIfOnPlusButton(document point: CGPoint) -> SelectionPoint? {
    guard let hover, let highlight = hoverHighlight, let controller else { return nil }
    let button = Self.plusButtonRect(
      for: hover, row: highlight.contentRow, mode: controller.mode, metrics: controller.lineMetrics)
    return button.contains(point) ? hover : nil
  }

  /// The clip view scrolled (wheel / trackpad) under a possibly-stationary cursor. This
  /// overlay is a FLOATING subview — fixed on screen while the rows scroll beneath it —
  /// so it is not auto-redrawn, and `mouseMoved` does NOT fire on a scroll. Without this
  /// the hover highlight / "+" glyph stays pinned to its old screen row while the code
  /// scrolls away (the "highlight between lines" bug). Re-resolve a passive hover to the
  /// row now under the cursor, then ALWAYS repaint — even when the resolved line is
  /// unchanged the document→local mapping moved, so the cached drawing is stale. During an
  /// active drag the band follows its pinned rows via that live mapping, so only a repaint
  /// is needed.
  func viewportDidScroll() {
    guard case .idle = session, let window else {
      setNeedsDisplay(bounds)  // a drag band follows its pinned rows; just repaint
      return
    }
    let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    resolveHoverAfterScroll(localMouse: bounds.contains(local) ? local : nil)
  }

  /// Testable core of `viewportDidScroll`: re-resolve a passive hover to the row now under
  /// `localMouse` (overlay-local; `nil` = the cursor is off the overlay) at the CURRENT
  /// scroll offset, then repaint. Split out so a headless test can drive it without a live
  /// window / mouse. Always repaints — even when the resolved line is unchanged, the
  /// document→local mapping moved, so the cached hover drawing is stale.
  func resolveHoverAfterScroll(localMouse: CGPoint?) {
    updateHover(atDocument: localMouse.map(documentPoint(from:)) ?? CGPoint(x: -1, y: -1))
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

  /// AppKit runs its tracking-area update pass off geometry / hierarchy changes, and this
  /// overlay is mounted (`addFloatingSubview`) from `makeNSView` — before the scroll view
  /// is in a window — then never resized again on its own. So arm the area explicitly the
  /// moment it lands in a window; otherwise nothing tracks until some LATER event forces a
  /// pass, which is why hover used to stay dead until the first click anywhere.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateTrackingAreas()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = Self.makeTrackingArea(bounds: bounds, owner: self)
    addTrackingArea(area)
    trackingArea = area
  }

  /// `.activeAlways`, NOT `.activeInKeyWindow`: the diff viewport is a passive reading
  /// surface the pointer wanders into while focus sits elsewhere (the terminal, another
  /// window). Key-window-scoped tracking made the gutter dead until a click moved focus
  /// here — hover on a review gutter should never require a focus click first.
  static func makeTrackingArea(bounds: NSRect, owner: AnyObject) -> NSTrackingArea {
    NSTrackingArea(
      rect: bounds,
      options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
      owner: owner,
      userInfo: nil
    )
  }

  /// The first click must ACT, not just focus the window — the "+" is a one-shot
  /// affordance, so swallowing its click to activate the window would make it need two.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  /// Only intercept events on a line's number gutter (or during an active drag);
  /// everything else falls through to the viewport (expander clicks, comment taps).
  override func hitTest(_ point: NSPoint) -> NSView? {
    if case .gutterSelecting = session { return self }
    guard let controller, let superview else { return nil }
    let doc = documentPoint(from: convert(point, from: superview))
    // The revealed "+" hangs OUTSIDE the number band, so it needs its own claim or the
    // click falls through to the viewport and the button is decorative-only.
    if hoveredLineIfOnPlusButton(document: doc) != nil { return self }
    guard let hit = controller.hitTest(doc), hit.column.isNumberColumn, hit.lineNumber != nil else { return nil }
    return self
  }

  override func mouseMoved(with event: NSEvent) {
    updateHover(atDocument: documentPoint(from: convert(event.locationInWindow, from: nil)))
  }

  /// The pointer can already be inside when the area arms (the overlay mounts under a
  /// stationary cursor — open a file from the sidebar and never move the mouse), and then
  /// the crossing IS the first hover event; waiting for a `mouseMoved` would show nothing.
  override func mouseEntered(with event: NSEvent) {
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
      drawPlusButton(for: highlight.line, docRect: highlight.contentRow, controller: controller)
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

  /// The hover "+" affordance's rect (document space) — ported from pierre
  /// `[data-utility-button]` (`style.css:1697-1714`): a `1lh × 1lh` button pinned to
  /// the RIGHT edge of the hovered side's number column and overhung outward by
  /// `1lh − 1ch` (`margin-right: calc((1lh - 1ch) * -1)`), so it straddles the column
  /// boundary rather than sitting centered on top of the digits.
  ///
  /// The overhang is `1lh − trailing pad` rather than pierre's `1lh − 1ch`: pierre's
  /// number cell has NO padding-right (`style.css:1425-1431`), so its `1ch` bite lands
  /// on the last digit; ours reserves `GutterRenderer.numberTrailingPad` after the
  /// digits (`LineRowView.drawNumber`), so biting exactly that much leaves the hovered
  /// line number fully legible — the point of the affordance is to comment on that line,
  /// so its number must stay readable.
  ///
  /// Vertically it hugs the row's FIRST visual line — the line the number itself is
  /// drawn on — so a wrapped (multi-sub-line) row does not float the button down into
  /// its middle. Mode-correct via `DiffHitTest.bands`, so split places it on the hovered
  /// pane (the old hand-rolled unified-only math put it in the wrong pane in split).
  static func plusButtonRect(
    for point: SelectionPoint, row: NSRect, mode: DiffViewMode, metrics: DiffMetrics
  ) -> NSRect {
    let bands = DiffHitTest.bands(mode: mode, width: row.width, gutterW: metrics.gutterWidth)
    guard let band = bands.first(where: { $0.column == .gutter(point.side) }) else { return .zero }
    let size = min(metrics.lineHeight, row.height)
    let overhang = max(0, size - GutterRenderer.numberTrailingPad)
    let maxX = band.range.upperBound + overhang
    return NSRect(x: maxX - size, y: row.minY, width: size, height: size)
  }

  /// Paint the hover "+" as an opaque accent-filled rounded button (pierre
  /// `background-color: var(--diffs-modified-base); color: var(--diffs-bg)`), NOT a
  /// translucent template symbol laid over the digits.
  private func drawPlusButton(for target: SelectionPoint, docRect: NSRect, controller: DiffViewportController) {
    let buttonDoc = Self.plusButtonRect(
      for: target, row: docRect, mode: controller.mode, metrics: controller.lineMetrics)
    let buttonRect = localRect(fromDocument: buttonDoc)
    guard !buttonRect.isEmpty else { return }
    let radius: CGFloat = 4
    NSColor.controlAccentColor.setFill()
    NSBezierPath(roundedRect: buttonRect, xRadius: radius, yRadius: radius).fill()
    let pointSize = (buttonRect.height * 0.6).rounded()
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    guard
      let image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Comment on this line")?
        .withSymbolConfiguration(config)
    else { return }
    image.isTemplate = true
    // The system's on-accent foreground (white in both appearances) — no custom colors.
    NSColor.alternateSelectedControlTextColor.set()
    let glyphRect = NSRect(
      x: (buttonRect.midX - image.size.width / 2).rounded(),
      y: (buttonRect.midY - image.size.height / 2).rounded(),
      width: image.size.width, height: image.size.height)
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
