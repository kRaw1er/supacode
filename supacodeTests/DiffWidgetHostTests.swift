import AppKit
import ComposableArchitecture
import Testing

@testable import supacode

/// Phase 6 — the widget host (`WidgetHostChunkView`) mount / recycle contract and
/// the collapse-toggle anti-jump relayout. NSVIEW-HEADLESS.
@MainActor
struct DiffWidgetHostTests {
  private func comment(_ id: UUID = UUID(), body: String = "please fix") -> ReviewComment {
    ReviewComment(
      id: id, filePath: "a.swift", side: .new, startLine: 3, endLine: 3,
      anchorSnippet: "t", contextBefore: "", body: body, createdAt: Date(timeIntervalSince1970: 0))
  }

  // MARK: - C 6.6 — mounts at estimate; an editing editor refuses recycle → rebuild

  @Test func widgetHostRecyclesByReuseKind() {
    let host = FakeWidgetLayoutHost()
    let coalescer = LayoutCoalescer(host: host)

    let idA = UUID()
    let display = CommentThreadWidget(
      key: .commentThread(anchorID: idA),
      model: CommentThreadModel(anchorID: idA, comments: [comment(idA)]),
      coalescer: coalescer
    )
    let hostView = WidgetHostChunkView()
    hostView.mount(display, key: .commentThread(anchorID: idA), width: 400, coalescer: coalescer)
    #expect(hostView.frame.height == display.estimatedHeight)  // mounts at the offscreen estimate
    #expect(hostView.mountedKey == .commentThread(anchorID: idA))

    // A display-mode thread accepts an identity swap (recycled host reused).
    let idB = UUID()
    let display2 = CommentThreadWidget(
      key: .commentThread(anchorID: idB),
      model: CommentThreadModel(anchorID: idB, comments: [comment(idB)]),
      coalescer: coalescer
    )
    #expect(hostView.reuse(display2, key: .commentThread(anchorID: idB), width: 400) == true)
    #expect(hostView.mountedKey == .commentThread(anchorID: idB))

    // An `.editing` editor REFUSES the swap (live TextEditor cursor) → harness rebuilds.
    let composerStore = Store(initialState: CommentComposer.State(draft: comment(idB), isEditing: true)) {
      CommentComposer()
    }
    let editing = CommentThreadWidget(
      key: .commentThread(anchorID: idB),
      model: CommentThreadModel(anchorID: idB, comments: [comment(idB)]),
      coalescer: coalescer,
      composerStore: composerStore
    )
    #expect(hostView.reuse(editing, key: .commentThread(anchorID: idB), width: 400) == false)
  }

  // MARK: - C 6.5 — collapse toggles node height + reaggregate, anchored no-jump
  //                 (even for a widget ABOVE the fold)

  @Test func collapseToggleHeightNoJump() {
    let controller = ViewportTestSupport.controller()
    let tree = ChunkTree(metrics: .production)
    let id = UUID()
    var after: ChunkID? = tree.insert(WidgetTreeFixture.commentWidget(id: id, estimatedHeight: 200), after: nil)
    for line in 1...300 { after = tree.insert(WidgetTreeFixture.contextLeaf(line), after: after) }
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
    controller.scroll(toY: 2000)  // scrolled well BELOW the widget (it sits above the fold)
    let before = controller.visibleRect.minY

    // Collapse: the widget above shrinks 200 → 40 through the coalescer (capture once,
    // apply, restore once). The first fully-visible line re-lands at the same pixel,
    // so the scroll offset drops by exactly the 160pt the content above lost.
    let coalescer = LayoutCoalescer(host: controller)
    coalescer.enqueueMeasuredHeight(key: .commentThread(anchorID: id), width: 800, height: 40)
    coalescer.tick()

    #expect(abs((before - controller.visibleRect.minY) - 160) < 1.5)
    #expect(tree.widgetNode(for: .commentThread(anchorID: id))?.summary.height(.unified) == 40)  // reaggregated
  }

  // MARK: - "hunk header collapsed at the LEFT on first open" — a viewport applied BEFORE
  //         the scroll view is sized (width 0) must NOT mount a widget host at width 0; the
  //         first real materialization happens once the viewport has a real width, so the
  //         hosted SwiftUI content is laid out full-width from the start.

  @Test func firstOpenBeforeSizingDefersMaterializationToRealWidth() {
    // `apply` runs in `makeNSView` BEFORE SwiftUI sizes the representable — the scroll view is
    // still 0-wide (the real first-open order that used to mount the header host collapsed).
    let controller = ViewportTestSupport.controller(width: 0, clipHeight: 600)
    controller.apply(tree: ViewportTestSupport.contextLeaves(Array(1...20)), mode: .unified, scrollPreserving: false)
    let anchorID = UUID()
    let widgetID = controller.insertCommentWidget(
      side: .new, startLine: 3, endLine: 3, anchorID: anchorID, estimatedHeight: 60)
    #expect(widgetID != nil)
    controller.layoutVisibleChunks()

    // Nothing materializes while the viewport is 0-wide — so NO host is ever mounted at width 0.
    #expect(controller.documentView.bounds.width == 0)
    #expect(controller.totalUsedViewCount == 0)
    #expect(controller.pools[.widget(.commentThread)]?.getView(forKey: widgetID!) == nil)

    // The scroll view gets its real size; the sizing-triggered layout re-fits the document and
    // mounts the widget host at full width — the hosted SwiftUI view lays out full-width, never
    // collapsed at the left.
    controller.scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    controller.scrollView.tile()
    controller.layoutVisibleChunks()

    #expect(controller.documentView.bounds.width == 800)
    let host = controller.pools[.widget(.commentThread)]?.getView(forKey: widgetID!) as? WidgetHostChunkView
    #expect(host != nil)
    #expect(host?.frame.width == 800)  // the viewport gave the container the real width

    // Flush a layout cycle (AppKit does this every frame; there is no run loop in a headless
    // test) — the host's fill constraints solve and its `layout()` re-flows the hosted SwiftUI
    // view to the container width, so the header content is full-width, not collapsed at 0.
    controller.documentView.layoutSubtreeIfNeeded()
    #expect(host?.hosted?.frame.width == 800)
  }

  // MARK: - coldRenderReservesHostSpace — attaching a comment host below the fold after a
  //         cold render (then letting its measured height flow in) does NOT reflow the
  //         viewport: the anchored on-screen line keeps its exact y (no scroll jump).

  @Test func coldRenderReservesHostSpace() {
    let controller = ViewportTestSupport.controller()
    let tree = ChunkTree(metrics: .production)
    var after: ChunkID?
    for line in 1...400 { after = tree.insert(WidgetTreeFixture.contextLeaf(line), after: after) }
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
    controller.scroll(toY: 1000)  // line 51 pinned at the clip top — the scroll anchor
    let anchorY = controller.visibleRect.minY

    // Cold render: attach a comment host FAR BELOW the fold (line 300 ≈ y 6000) after the
    // initial layout. Because the host sits below the anchored line, the attach must not
    // shove the anchored content — the on-screen y is byte-identical.
    let anchorID = UUID()
    let inserted = controller.insertCommentWidget(
      side: .new, startLine: 300, endLine: 300, anchorID: anchorID, estimatedHeight: 60)
    #expect(inserted != nil)
    #expect(controller.visibleRect.minY == anchorY)  // attach alone: no jump

    // Then the host's REAL measured height flows in (60 → 220). A measure-then-grow below
    // the fold reaggregates the tree but must still keep the anchored line put — the
    // deferred-reservation design's load-bearing "grow-below-anchor keeps anchor" contract.
    let coalescer = LayoutCoalescer(host: controller)
    coalescer.enqueueMeasuredHeight(key: .commentThread(anchorID: anchorID), width: 800, height: 220)
    coalescer.tick()

    #expect(controller.visibleRect.minY == anchorY)  // measure-then-grow below the fold: still no jump
    #expect(tree.widgetNode(for: .commentThread(anchorID: anchorID))?.summary.height(.unified) == 220)  // reaggregated
  }

  // MARK: - B §3/§20 — an occupied (.editing) host is not handed to another chunk;
  //          the autoscroller's display link stops on unmount

  @Test func occupiedWidgetHostNotRecycled() {
    let host = FakeWidgetLayoutHost()
    let coalescer = LayoutCoalescer(host: host)

    // Mount an EDITING comment composer — the host now owns an app-managed subview.
    let idA = UUID()
    let composerStore = Store(initialState: CommentComposer.State(draft: comment(idA), isEditing: true)) {
      CommentComposer()
    }
    let editing = CommentThreadWidget(
      key: .commentThread(anchorID: idA),
      model: CommentThreadModel(anchorID: idA, comments: [comment(idA)]),
      coalescer: coalescer,
      composerStore: composerStore
    )
    let hostView = WidgetHostChunkView()
    hostView.mount(editing, key: .commentThread(anchorID: idA), width: 400, coalescer: coalescer)
    #expect(hostView.isOccupied)

    // A DIFFERENT chunk (a display thread) asks to reuse the occupied host — REFUSED
    // (B §3: not eligible for recycle until drained), even though a display thread
    // would otherwise accept an identity swap. The host stays bound to A.
    let idB = UUID()
    let other = CommentThreadWidget(
      key: .commentThread(anchorID: idB),
      model: CommentThreadModel(anchorID: idB, comments: [comment(idB)]),
      coalescer: coalescer
    )
    #expect(hostView.reuse(other, key: .commentThread(anchorID: idB), width: 400) == false)
    #expect(hostView.mountedKey == .commentThread(anchorID: idA))  // NOT handed off

    // Only after the host is drained can it host another chunk.
    hostView.prepareForReuse()
    #expect(hostView.mountedKey == nil)
    #expect(hostView.isOccupied == false)
    hostView.mount(other, key: .commentThread(anchorID: idB), width: 400, coalescer: coalescer)
    #expect(hostView.mountedKey == .commentThread(anchorID: idB))
    #expect(hostView.isOccupied == false)  // a display thread does not occupy the host

    // The edge autoscroller's display link STOPS on unmount (B §20 lifecycle).
    let autoscroller = EdgeAutoscroller(view: NSView()) { _ in }
    #expect(autoscroller.isActive)
    autoscroller.stop()
    #expect(autoscroller.isActive == false)  // link invalidated on unmount
    autoscroller.stop()  // idempotent
    #expect(autoscroller.isActive == false)
  }
}
