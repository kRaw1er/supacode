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
