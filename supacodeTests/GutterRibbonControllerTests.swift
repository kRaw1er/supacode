import AppKit
import Testing

@testable import supacode

/// Phase 6 — the gutter "+" range-select ported onto geometric `hitTest` + a
/// pierre `PointerSession` (`requireNumberColumn` true-down / false-drag, side
/// pinned to the anchor), plus the `EdgeAutoscroller` velocity ramp (our addition,
/// C8). NSVIEW-HEADLESS — the testable session core takes document-space points.
@MainActor
struct GutterRibbonControllerTests {
  /// Controller over `count` single-line context leaves (leaf `i` → line `i+1` at
  /// `y = i·20`), plus a gutter overlay tiled to the clip.
  private func makeSetup(lines count: Int = 20) -> (DiffViewportController, GutterRibbonController) {
    let controller = ViewportTestSupport.controller()
    controller.apply(tree: ViewportTestSupport.contextLeaves(Array(1...count)), mode: .unified, scrollPreserving: false)
    let gutter = GutterRibbonController()
    gutter.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    gutter.controller = controller
    return (controller, gutter)
  }

  private func rowY(_ line: Int) -> CGFloat { CGFloat(line - 1) * 20 + 10 }
  private func oldNumX(_ controller: DiffViewportController) -> CGFloat {
    DiffHitTest.changeBarWidth + controller.gutterWidth / 2
  }
  private func contentX(_ controller: DiffViewportController) -> CGFloat {
    2 * DiffHitTest.changeBarWidth + 2 * controller.gutterWidth + 20
  }

  // MARK: - C 8.1 — down off the number column starts NO session

  @Test func downOffNumberColumnNoSession() {
    let (controller, gutter) = makeSetup()
    let started = gutter.beginSelection(atDocument: CGPoint(x: contentX(controller), y: rowY(3)))
    #expect(started == false)
    #expect(gutter.session == .idle)
  }

  // MARK: - C 8.2 — down-on-number → drag-over-content ⇒ min…max, side pinned

  @Test func downOnNumberThenDragOverContent() {
    let (controller, gutter) = makeSetup()
    #expect(gutter.beginSelection(atDocument: CGPoint(x: oldNumX(controller), y: rowY(3))))
    // Endpoint over the CONTENT column (not a number column) still extends — the
    // side is pinned to the anchor (`requireNumberColumn: false` on drag).
    gutter.extendSelection(toDocument: CGPoint(x: contentX(controller), y: rowY(6)))
    guard case .gutterSelecting(let anchor, let current) = gutter.session else {
      Issue.record("expected an active session")
      return
    }
    #expect(anchor == SelectionPoint(lineNumber: 3, side: .old))
    #expect(current == SelectionPoint(lineNumber: 6, side: .old))  // side pinned to the anchor
    let commit = gutter.commitSelection()
    #expect(commit?.side == .old)
    #expect(commit?.startLine == 3)
    #expect(commit?.endLine == 6)
  }

  // MARK: - C 8.3 — the anchor is a logical SelectionPoint, never a y / view

  @Test func pointerSessionAnchorIsLogical() {
    let anchor = SelectionPoint(lineNumber: 5, side: .new)
    let session = PointerSession.gutterSelecting(anchor: anchor, current: anchor)
    // Structural: `SelectionPoint` carries only `(lineNumber, side)` — no pixel /
    // element — so it survives recycle + re-measure. Equality is by coordinate.
    #expect(
      session
        == .gutterSelecting(
          anchor: SelectionPoint(lineNumber: 5, side: .new),
          current: SelectionPoint(lineNumber: 5, side: .new)))
    #expect(anchor != SelectionPoint(lineNumber: 5, side: .old))
  }

  // MARK: - B §5 — the endpoint resolves by coordinate, not a captured target

  @Test func endpointFollowsCoordinateNotCapturedTarget() {
    let (controller, gutter) = makeSetup()
    #expect(gutter.beginSelection(atDocument: CGPoint(x: oldNumX(controller), y: rowY(3))))
    gutter.extendSelection(toDocument: CGPoint(x: oldNumX(controller), y: rowY(8)))
    guard case .gutterSelecting(_, let current) = gutter.session else {
      Issue.record("expected an active session")
      return
    }
    #expect(current.lineNumber == 8)  // resolved geometrically from the drag point
  }

  // MARK: - B §5 — reversed range normalizes; "+" anchors the bottom-most line

  @Test func reversedRangeNormalizesAndAnchorsBottom() {
    let (controller, gutter) = makeSetup()
    #expect(gutter.beginSelection(atDocument: CGPoint(x: oldNumX(controller), y: rowY(6))))
    gutter.extendSelection(toDocument: CGPoint(x: oldNumX(controller), y: rowY(2)))  // drag UP
    let commit = gutter.commitSelection()
    #expect(commit?.startLine == 2)  // normalized min…max
    #expect(commit?.endLine == 6)

    // The "+" anchors to the bottom-most selected line: the widget lands after
    // line 6, so line 7 is pushed down while line 6 (and above) is unaffected.
    let line6Y = controller.lineRect(line: 6, side: .old)?.minY
    let line7ID = controller.lineLocation(line: 7, side: .old)?.chunkID
    let line7Before = line7ID.flatMap { controller.frame(forChunk: $0)?.minY }
    controller.insertCommentWidget(side: .old, startLine: 2, endLine: 6, anchorID: UUID(), estimatedHeight: 100)
    #expect(controller.lineRect(line: 6, side: .old)?.minY == line6Y)  // bottom anchor: 6 unaffected
    let line7After = line7ID.flatMap { controller.frame(forChunk: $0)?.minY }
    #expect(line7After == (line7Before ?? 0) + 100)  // line below pushed down by the widget
  }

  // MARK: - B §5 — an inert region (widget / no-number row) HOLDS the range

  @Test func inertRegionsHoldRange() {
    let controller = ViewportTestSupport.controller()
    // Lines 1…5, then a comment WIDGET, then lines 6…10.
    let tree = ChunkTree(metrics: .production)
    var after: ChunkID?
    for line in 1...5 { after = tree.insert(WidgetTreeFixture.contextLeaf(line), after: after) }
    after = tree.insert(WidgetTreeFixture.commentWidget(id: UUID(), estimatedHeight: 40), after: after)
    for line in 6...10 { after = tree.insert(WidgetTreeFixture.contextLeaf(line), after: after) }
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)

    let gutter = GutterRibbonController()
    gutter.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    gutter.controller = controller

    #expect(gutter.beginSelection(atDocument: CGPoint(x: oldNumX(controller), y: 50)))  // line 3
    // Drag onto the widget row (y in [100,140)) — a widget carries no line number,
    // so the range HOLDS at the anchor.
    gutter.extendSelection(toDocument: CGPoint(x: oldNumX(controller), y: 120))
    guard case .gutterSelecting(_, let held) = gutter.session else {
      Issue.record("expected an active session")
      return
    }
    #expect(held.lineNumber == 3)  // unchanged — the inert widget row does not extend

    // Dragging PAST the widget onto line 8 resumes extension.
    gutter.extendSelection(toDocument: CGPoint(x: oldNumX(controller), y: 100 + 40 + 2 * 20 + 10))
    guard case .gutterSelecting(_, let resumed) = gutter.session else {
      Issue.record("expected an active session")
      return
    }
    #expect(resumed.lineNumber == 8)
  }

  // MARK: - C 8.4 — edge autoscroll velocity ramp (quadratic, dead-zone, saturates)

  @Test func edgeAutoscrollVelocityRamp() {
    #expect(EdgeAutoscroller.velocity(overshoot: -10) == 0)  // dead-zone (inside visibleRect)
    #expect(EdgeAutoscroller.velocity(overshoot: 0) == 0)
    #expect(EdgeAutoscroller.velocity(overshoot: 60) == EdgeAutoscroller.vmax * 0.25)  // t=0.5 → quadratic
    #expect(EdgeAutoscroller.velocity(overshoot: 120) == EdgeAutoscroller.vmax)  // saturates at 120px
    #expect(EdgeAutoscroller.velocity(overshoot: 240) == EdgeAutoscroller.vmax)  // clamped past saturation
    // Quadratic: half the overshoot yields a QUARTER (not half) the velocity.
    #expect(EdgeAutoscroller.velocity(overshoot: 60) < EdgeAutoscroller.velocity(overshoot: 120) / 2)
  }

  // MARK: - C 8.5 (automatable core) — an autoscroll tick advances the end line

  @Test func edgeAutoscrollExtendsSelectionOnTick() {
    let (controller, gutter) = makeSetup(lines: 100)
    #expect(gutter.beginSelection(atDocument: CGPoint(x: oldNumX(controller), y: rowY(3))))
    // Pointer 130px past the bottom edge → full ramp, direction down.
    gutter.updateAutoscroll(pointerLocalY: gutter.bounds.height + 130)
    gutter.autoscrollStep(dt: 0.1)  // one 100ms frame: scroll ~90px, re-hitTest the edge
    guard case .gutterSelecting(_, let current) = gutter.session else {
      Issue.record("expected an active session")
      return
    }
    #expect(current.lineNumber > 3)  // the end line advanced as the viewport scrolled
    #expect(controller.visibleRect.minY > 0)  // the viewport actually scrolled down
  }

  // MARK: - B §2 — hover cross-links the content row AND its gutter number

  @Test func hoverHighlightsBothColumns() {
    let (controller, gutter) = makeSetup()
    gutter.updateHover(atDocument: CGPoint(x: oldNumX(controller), y: rowY(4)))
    guard let highlight = gutter.hoverHighlight else {
      Issue.record("expected a hover cross-highlight over the number column")
      return
    }
    #expect(highlight.line == SelectionPoint(lineNumber: 4, side: .old))
    // The content-row half spans the FULL row width — both columns are cross-lit
    // (pierre `lineHoverHighlight: 'both'`), and matches the owner line's rect.
    #expect(highlight.contentRow == controller.lineRect(line: 4, side: .old))
    #expect(highlight.contentRow.minX == 0)
    #expect(highlight.contentRow.width == controller.documentView.bounds.width)
    // The gutter-number half is the hovered side's number cell only (a sub-band of
    // the row), so the cross-link lights BOTH the row and its number, not just one.
    #expect(highlight.gutterNumber.minX == DiffHitTest.changeBarWidth)  // old number band starts after the bar
    #expect(highlight.gutterNumber.width == controller.gutterWidth)
    #expect(highlight.gutterNumber.height == highlight.contentRow.height)
    #expect(highlight.gutterNumber.width < highlight.contentRow.width)  // number cell ⊊ content row

    // Moving off any number column clears the cross-highlight entirely.
    gutter.updateHover(atDocument: CGPoint(x: contentX(controller), y: rowY(4)))
    #expect(gutter.hoverHighlight == nil)
  }

  // MARK: - B §2 — the overlay re-reads the live controller each mouseMoved

  @Test func optionsReapplyToLiveRows() {
    let (controller, gutter) = makeSetup(lines: 20)
    gutter.updateHover(atDocument: CGPoint(x: oldNumX(controller), y: rowY(5)))
    #expect(gutter.hoverHighlight?.line == SelectionPoint(lineNumber: 5, side: .old))

    // Re-apply a DIFFERENT tree to the SAME controller + overlay (rows already on
    // screen). The gutter reads the controller live each mouseMoved — no cached
    // per-row closure, no re-creation — so hover now resolves against the new tree.
    controller.apply(
      tree: ViewportTestSupport.contextLeaves(Array(100...119)), mode: .unified, scrollPreserving: false)
    gutter.updateHover(atDocument: CGPoint(x: oldNumX(controller), y: rowY(5)))
    #expect(gutter.hoverHighlight?.line == SelectionPoint(lineNumber: 104, side: .old))  // row 5 → line 104 now

    // A fresh selection also reflects the live tree (config, not a stale snapshot).
    #expect(gutter.beginSelection(atDocument: CGPoint(x: oldNumX(controller), y: rowY(1))))
    #expect(
      gutter.session
        == .gutterSelecting(
          anchor: SelectionPoint(lineNumber: 100, side: .old),
          current: SelectionPoint(lineNumber: 100, side: .old)))
  }
}
