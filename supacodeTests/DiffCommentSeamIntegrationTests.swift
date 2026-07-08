import AppKit
import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

/// Camp A F1+F5 — the INLINE-COMMENT seam, driven END TO END (callback → action →
/// reducer state → coordinator → viewport/tree/widget), not as isolated Coordinator
/// units (`DiffViewerRepresentableWiringTests` already covers those in isolation).
///
/// Each test drives the ACTUAL wired seam — the gutter overlay's `onOpenComposer`
/// closure the coordinator installs, or the composer child reducer's delegate — feeds
/// the resulting action into a REAL `StoreOf<DiffReviewFeature>`, lets the reducer
/// mutate state, then threads that state back through the coordinator exactly as
/// `DiffViewerRepresentable.updateNSView` / `syncCallbacks` / `makeResolver` do, and
/// asserts the live `ChunkTree` + resolved `CommentThreadWidget` reflect the whole
/// round trip:
///
/// - F1 NEW: gutter commit → `.openCommentComposer` → `state.composer` for a new anchor
///   → `reconcileTransientComposer` inserts a transient inline editing widget AND the
///   resolver (composer store injected for the matching anchor) resolves it `.editing`.
/// - COMMIT: composer `.saveTapped` → `.commit` delegate → `.commitComment` →
///   `state.comments` gains it, `state.composer == nil` → the re-projected tree renders
///   ONE display thread (`isEditing == false`, no duplicate transient).
/// - CANCEL: composer `.cancelTapped` → `.cancel` delegate → `state.composer == nil` →
///   `reconcileTransientComposer` removes the transient widget, no comment committed.
/// - EDIT: seeded committed comment → `.editComment` → `state.composer` on the existing
///   anchor → the content `Signature` gains `composerAnchorID` (forcing a re-project) →
///   the display widget flips `.editing`.
/// - SHEET-IS-GONE: composing routes through an INLINE tree widget positioned in the
///   document flow with a host-exclusive embedded editor — proven by wiring, not grep.
@MainActor
struct DiffCommentSeamIntegrationTests {
  // MARK: - Fixtures

  private func sizedCoordinator(width: CGFloat = 800, clipHeight: CGFloat = 600)
    -> DiffViewerRepresentable.Coordinator
  {
    let coord = DiffViewerRepresentable.Coordinator()
    coord.controller.scrollView.scrollerStyle = .overlay
    coord.controller.scrollView.frame = NSRect(x: 0, y: 0, width: width, height: clipHeight)
    coord.controller.scrollView.tile()
    return coord
  }

  private func line(_ origin: DiffLineOrigin, old: Int?, new: Int?, _ content: String) -> DiffLine {
    DiffLine(origin: origin, oldLineNumber: old, newLineNumber: new, content: content, noNewlineAtEof: false)
  }

  /// A file whose single hunk renders new-side lines 1…8 (a change at line 4), so a
  /// comment anchored on new line 5 finds a real anchor row in both the builder tree
  /// and the controller's `lineLocation`.
  private func commentFixture() -> (FileChange, [DiffHunk]) {
    let file = DiffFixture.file()
    let lines: [DiffLine] = [
      line(.context, old: 1, new: 1, "l1"),
      line(.context, old: 2, new: 2, "l2"),
      line(.context, old: 3, new: 3, "l3"),
      line(.deletion, old: 4, new: nil, "old4"),
      line(.addition, old: nil, new: 4, "new4"),
      line(.context, old: 5, new: 5, "l5"),
      line(.context, old: 6, new: 6, "l6"),
      line(.context, old: 7, new: 7, "l7"),
      line(.context, old: 8, new: 8, "l8"),
    ]
    let hunk = DiffHunk(
      oldStart: 1, oldCount: 8, newStart: 1, newCount: 8, header: "@@ -1,8 +1,8 @@", lines: lines)
    return (file, [hunk])
  }

  private func newComment(_ id: UUID, side: DiffSide = .new, start: Int = 5, end: Int = 5, body: String = "")
    -> ReviewComment
  {
    ReviewComment(
      id: id, filePath: "a.swift", source: .workingTree, side: side, startLine: start, endLine: end,
      anchorSnippet: "", contextBefore: "", body: body, createdAt: Date(timeIntervalSince1970: 500))
  }

  /// A real `StoreOf<DiffReviewFeature>` with the only invoked dependencies stubbed
  /// (`date` for the new-draft `createdAt`; persistence is a no-op double even though
  /// `selectedWorktree` is nil ⇒ `persistEffect` is `.none`). Non-exhaustive because
  /// a fresh draft's `ReviewComment.id` is a raw `UUID()` (see `bugsFound`), so exact
  /// state matching on send is impossible — the tests read `store.state` back instead.
  private func makeStore() -> TestStore<DiffReviewFeature.State, DiffReviewFeature.Action> {
    let store = TestStore(initialState: DiffReviewFeature.State()) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
      $0[CommentPersistenceStoreClient.self] = CommentPersistenceStoreClient(
        load: { _ in [] }, save: { _, _ in })
    }
    store.exhaustivity = .off
    return store
  }

  /// Resolve the comment-thread widget for `anchor` exactly as
  /// `DiffViewerRepresentable.makeResolver` wires it: the resolver's `composerStore`
  /// closure returns the coordinator's live composer store ONLY for the matching
  /// `composerAnchorID` (the reducer's presented `\.composer`, re-wrapped). So the
  /// widget's `isEditing` is a pure function of the round-tripped reducer state.
  private func resolveThread(_ coord: DiffViewerRepresentable.Coordinator, anchor: UUID) -> CommentThreadWidget? {
    var resolver = DiffWidgetResolver(comments: coord.comments)
    resolver.composerStore = { anchorID in
      guard let store = coord.composerStore, coord.composerAnchorID == anchorID else { return nil }
      return store
    }
    let coalescer = LayoutCoalescer(host: coord.controller)
    let widget = Widget(
      key: .commentThread(anchorID: anchor), estimatedHeight: 120, payload: .commentThread(anchorID: anchor))
    return resolver.resolve(widget, coalescer: coalescer) as? CommentThreadWidget
  }

  /// Count of `.commentThread` widget leaves for `anchor` currently in the tree — the
  /// duplicate-render guard (a commit must leave exactly one).
  private func threadWidgetCount(_ coord: DiffViewerRepresentable.Coordinator, anchor: UUID) -> Int {
    coord.controller.tree.inorderNodes().count { node in
      if case .widget(let widget) = node.chunk, widget.key == .commentThread(anchorID: anchor) { return true }
      return false
    }
  }

  /// Mirror of `syncCallbacks`: push the round-tripped reducer state onto the
  /// coordinator's live inputs (the composer store re-wraps the presented child).
  private func syncComposer(
    _ coord: DiffViewerRepresentable.Coordinator, state: DiffReviewFeature.State
  ) {
    coord.comments = Array(state.comments)
    coord.composerAnchorID = state.composer?.draft.id
    coord.composerStore = state.composer.map { Store(initialState: $0) { CommentComposer() } }
  }

  // MARK: - F1 — NEW comment: gutter closure → action → state → transient inline editor

  @Test func gutterOpenComposerSeedsTransientInlineEditorRoundTrip() async throws {
    let coord = sizedCoordinator()
    let (file, hunks) = commentFixture()
    var captured: [DiffReviewFeature.Action] = []
    coord.filePath = "a.swift"
    coord.source = .workingTree
    coord.send = { captured.append($0) }
    coord.installInteraction()
    coord.controller.apply(
      tree: ChunkTreeBuilder.build(file: file, hunks: hunks, mode: .unified), mode: .unified, scrollPreserving: false)

    // Drive the ACTUAL wired gutter closure the coordinator installed.
    coord.gutter?.onOpenComposer?(.new, 5, 5, "l5", "l4")

    // The closure builds the inline `.openCommentComposer` action (scoped to this tab),
    // NOT a modal-sheet action — that action IS the seam.
    #expect(
      captured == [
        .openCommentComposer(
          filePath: "a.swift", source: .workingTree, side: .new, startLine: 5, endLine: 5,
          anchorSnippet: "l5", contextBefore: "l4")
      ])

    // Feed it into the REAL reducer.
    let store = makeStore()
    await store.send(captured[0])
    let composerState = try #require(store.state.composer)
    #expect(composerState.isEditing == false)  // a brand-new (uncommitted) draft
    let anchor = composerState.draft.id

    // Round-trip the state onto the coordinator + reconcile the transient inline editor.
    syncComposer(coord, state: store.state)
    coord.reconcileTransientComposer(draft: composerState.draft, comments: coord.comments)

    // The tree gained a transient inline editing widget at the new anchor …
    #expect(coord.controller.tree.widgetNode(for: .commentThread(anchorID: anchor)) != nil)
    // … and the resolver injects the composer store for THAT anchor → `.editing`.
    let thread = try #require(resolveThread(coord, anchor: anchor))
    #expect(thread.isEditing == true)
  }

  // MARK: - COMMIT — composer delegate .commit → .commitComment → ONE display widget

  @Test func commitRendersSingleDisplayWidgetRoundTrip() async throws {
    let coord = sizedCoordinator()
    let (file, hunks) = commentFixture()
    coord.filePath = "a.swift"
    coord.source = .workingTree
    coord.installInteraction()
    coord.controller.apply(
      tree: ChunkTreeBuilder.build(file: file, hunks: hunks, mode: .unified), mode: .unified, scrollPreserving: false)

    let store = makeStore()
    // Open the composer for a new comment on new line 5, then seed the transient editor.
    await store.send(
      .openCommentComposer(
        filePath: "a.swift", source: .workingTree, side: .new, startLine: 5, endLine: 5,
        anchorSnippet: "l5", contextBefore: "l4"))
    let draft = try #require(store.state.composer).draft
    let anchor = draft.id
    syncComposer(coord, state: store.state)
    coord.reconcileTransientComposer(draft: draft, comments: coord.comments)
    #expect(coord.controller.tree.widgetNode(for: .commentThread(anchorID: anchor)) != nil)

    // User types, then hits Save — drive the composer child reducer's delegate chain.
    await store.send(.composer(.presented(.binding(.set(\.draft.body, "needs a fix")))))
    await store.send(.composer(.presented(.saveTapped)))
    await store.receive(\.composer.presented.delegate.commit)
    await store.receive(\.commitComment)
    await store.finish()

    #expect(store.state.comments.count == 1)
    #expect(store.state.comments[id: anchor]?.body == "needs a fix")
    #expect(store.state.composer == nil)

    // Commit is a content change: re-project the tree from `comments` (as `updateNSView`
    // does), then reconcile the now-committed composer draft (nil) — the guard must NOT
    // tear down the committed widget, and must NOT leave the transient one behind.
    let comments = Array(store.state.comments)
    coord.controller.apply(
      tree: ChunkTreeBuilder.build(file: file, hunks: hunks, mode: .unified, comments: comments), mode: .unified,
      scrollPreserving: true)
    syncComposer(coord, state: store.state)
    coord.reconcileTransientComposer(draft: nil, comments: comments)

    #expect(threadWidgetCount(coord, anchor: anchor) == 1)  // exactly one — no duplicate
    let thread = try #require(resolveThread(coord, anchor: anchor))
    #expect(thread.isEditing == false)  // a DISPLAY thread now (composer closed)
    #expect(thread.model.comments.map(\.id) == [anchor])
  }

  // MARK: - CANCEL — composer delegate .cancel → composer nil → transient removed

  @Test func cancelRemovesTransientWidgetAndCommitsNothingRoundTrip() async throws {
    let coord = sizedCoordinator()
    let (file, hunks) = commentFixture()
    coord.filePath = "a.swift"
    coord.source = .workingTree
    coord.installInteraction()
    coord.controller.apply(
      tree: ChunkTreeBuilder.build(file: file, hunks: hunks, mode: .unified), mode: .unified, scrollPreserving: false)

    let store = makeStore()
    await store.send(
      .openCommentComposer(
        filePath: "a.swift", source: .workingTree, side: .new, startLine: 5, endLine: 5,
        anchorSnippet: "l5", contextBefore: "l4"))
    let anchor = try #require(store.state.composer).draft.id
    syncComposer(coord, state: store.state)
    coord.reconcileTransientComposer(draft: store.state.composer?.draft, comments: coord.comments)
    #expect(coord.controller.tree.widgetNode(for: .commentThread(anchorID: anchor)) != nil)

    // Esc / Cancel → the composer child emits `.cancel`; the parent drops the composer.
    await store.send(.composer(.presented(.cancelTapped)))
    await store.receive(\.composer.presented.delegate.cancel)
    await store.finish()
    #expect(store.state.composer == nil)
    #expect(store.state.comments.isEmpty)  // nothing was committed

    // Round-trip the closed composer → the transient inline editor is removed.
    syncComposer(coord, state: store.state)
    coord.reconcileTransientComposer(draft: nil, comments: Array(store.state.comments))
    #expect(coord.controller.tree.widgetNode(for: .commentThread(anchorID: anchor)) == nil)
    #expect(threadWidgetCount(coord, anchor: anchor) == 0)
  }

  // MARK: - EDIT — .editComment flips the committed display widget to editing

  @Test func editComposerFlipsDisplayWidgetToEditingRoundTrip() async throws {
    let coord = sizedCoordinator()
    let (file, hunks) = commentFixture()
    coord.filePath = "a.swift"
    coord.source = .workingTree
    coord.installInteraction()

    let anchor = UUID()
    let committed = newComment(anchor, body: "original")
    let store = makeStore()
    await store.send(.commentsLoaded([committed]))  // seed a committed thread

    // The committed comment renders as a DISPLAY thread in the projected tree.
    let comments = Array(store.state.comments)
    coord.controller.apply(
      tree: ChunkTreeBuilder.build(file: file, hunks: hunks, mode: .unified, comments: comments), mode: .unified,
      scrollPreserving: false)
    #expect(coord.controller.tree.widgetNode(for: .commentThread(anchorID: anchor)) != nil)

    // Before opening the editor: no composer anchor ⇒ the widget resolves DISPLAY.
    syncComposer(coord, state: store.state)
    #expect(coord.composerAnchorID == nil)
    #expect(try #require(resolveThread(coord, anchor: anchor)).isEditing == false)

    // The content Signature (BEFORE the edit) — captured so we can prove the edit
    // changes it, which is what forces the re-project that flips the host to editing.
    let signatureBefore = DiffViewerRepresentable.Coordinator.Signature(
      comments: comments, wordDiffEnabled: true, composerAnchorID: nil)

    // A comment-row "edit" tap → `.editComment` opens the composer over the existing anchor.
    await store.send(.editComment(id: anchor))
    let composerState = try #require(store.state.composer)
    #expect(composerState.isEditing == true)
    #expect(composerState.draft.id == anchor)

    // The composer anchor now enters the content Signature (≠ the pre-edit one), so
    // `updateNSView` re-projects and the widget host re-mounts editing.
    let signatureAfter = DiffViewerRepresentable.Coordinator.Signature(
      comments: Array(store.state.comments), wordDiffEnabled: true, composerAnchorID: anchor)
    #expect(signatureBefore != signatureAfter)

    // Round-trip the open composer + re-project → the SAME anchor's widget flips editing.
    syncComposer(coord, state: store.state)
    coord.controller.apply(
      tree: ChunkTreeBuilder.build(
        file: file, hunks: hunks, mode: .unified, comments: Array(store.state.comments)), mode: .unified,
      scrollPreserving: true)
    #expect(coord.composerAnchorID == anchor)
    let thread = try #require(resolveThread(coord, anchor: anchor))
    #expect(thread.isEditing == true)
  }

  // MARK: - SHEET-IS-GONE — composing routes through an INLINE tree widget, not a modal

  @Test func composingRoutesThroughInlineWidgetNotSheetRoundTrip() async throws {
    let coord = sizedCoordinator()
    let (file, hunks) = commentFixture()
    var captured: [DiffReviewFeature.Action] = []
    coord.filePath = "a.swift"
    coord.source = .workingTree
    coord.send = { captured.append($0) }
    coord.installInteraction()
    coord.controller.apply(
      tree: ChunkTreeBuilder.build(file: file, hunks: hunks, mode: .unified), mode: .unified, scrollPreserving: false)

    // Open via the wired gutter closure → the ONLY composer-open action is the inline
    // `.openCommentComposer` (there is no present-sheet action in the surface).
    coord.gutter?.onOpenComposer?(.new, 5, 5, "l5", "l4")
    guard case .openCommentComposer = captured.first else {
      Issue.record("gutter did not route composing through .openCommentComposer")
      return
    }

    let store = makeStore()
    await store.send(captured[0])
    let draft = try #require(store.state.composer).draft
    let anchor = draft.id
    syncComposer(coord, state: store.state)
    coord.reconcileTransientComposer(draft: draft, comments: coord.comments)

    // Wiring proof #1 — the composer is a TREE NODE in the document flow (a modal
    // sheet would not be), inserted immediately AFTER its anchor line (new line 5).
    let nodes = coord.controller.tree.inorderNodes()
    let widgetIndex = try #require(
      nodes.firstIndex { node in
        if case .widget(let widget) = node.chunk, widget.key == .commentThread(anchorID: anchor) { return true }
        return false
      })
    #expect(widgetIndex > 0)
    let predecessor = nodes[widgetIndex - 1]
    #expect(predecessor.chunk.lineSegment?.windowedLines.last?.newLineNumber == 5)

    // Wiring proof #2 — the resolved widget embeds the composer inline and holds its
    // host exclusively (the anti-sheet property: the editor lives in the viewport).
    let thread = try #require(resolveThread(coord, anchor: anchor))
    #expect(thread.isEditing == true)
    #expect(thread.occupiesHostExclusively == true)
  }
}
