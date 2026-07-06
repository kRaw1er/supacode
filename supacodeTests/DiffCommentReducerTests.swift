import AppKit
import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Phase 6 — the comment persistence reducer arms (commit / edit / delete / send
/// persist via an injected double, load-then-relocate on open) and the gutter↔tree
/// ↔reducer seam (drag → split/insert → commit; cancel → remove). TestClock
/// throughout; no `Task.sleep`.
@MainActor
struct DiffCommentReducerTests {
  private func gitWorktree(path: String = "/tmp/repo/wt") -> Worktree {
    Worktree(
      id: WorktreeID(path),
      name: "wt",
      detail: "",
      workingDirectory: URL(filePath: path),
      repositoryRootURL: URL(filePath: "/tmp/repo")
    )
  }

  private func makeFile(_ path: String) -> FileChange {
    FileChange(
      oldPath: nil, newPath: path, status: .modified, addedLines: 1, removedLines: 0,
      isBinary: false, isLargeFileCapped: false, hasLongLines: false, similarity: 0)
  }

  private func reviewComment(
    id: UUID = UUID(),
    source: DiffSource = .workingTree,
    side: DiffSide = .new,
    start: Int = 3,
    end: Int = 3,
    snippet: String = "target",
    body: String = "please fix",
    createdAt: Date = Date(timeIntervalSince1970: 500)
  ) -> ReviewComment {
    ReviewComment(
      id: id, filePath: "a.swift", source: source, side: side, startLine: start, endLine: end,
      anchorSnippet: snippet, contextBefore: "", body: body, createdAt: createdAt)
  }

  // MARK: - C 7.7 — commit / edit / delete mutate `comments` + persist (no rebuildRows, S7)

  @Test(arguments: [DiffSource.workingTree, DiffSource.baseBranch(ref: "main")])
  func commitEditDeletePersist(source: DiffSource) async {
    let worktree = gitWorktree()
    let workingID = worktree.id.rawValue
    let saved = LockIsolated<[ReviewComment]?>(nil)
    var state = DiffReviewFeature.State()
    state.selectedWorktree = worktree
    let store = TestStore(initialState: state) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
      $0[CommentPersistenceStoreClient.self] = CommentPersistenceStoreClient(
        load: { _ in [] },
        save: { id, comments in if id == workingID { saved.setValue(comments) } })
    }

    let id = UUID()
    let comment = reviewComment(id: id, source: source, body: "fix", createdAt: Date(timeIntervalSince1970: 500))

    // Commit: upsert + persist; `updatedAt` comes from the injected `date.now`.
    var committed = comment
    committed.updatedAt = Date(timeIntervalSince1970: 1000)
    await store.send(.commitComment(comment)) {
      $0.comments[id: id] = committed
    }
    await store.finish()
    #expect(saved.value?.count == 1)
    #expect(saved.value?.first?.updatedAt == Date(timeIntervalSince1970: 1000))
    #expect(store.state.openDiffs.isEmpty)  // S7: nothing rebuilt — the tree derives from `comments`

    // Edit: opens the composer over the committed comment (no persist).
    await store.send(.editComment(id: id)) {
      $0.composer = CommentComposer.State(draft: committed, isEditing: true)
    }

    // Re-commit the edited body: composer clears + persists again.
    var edited = committed
    edited.body = "fix v2"
    await store.send(.commitComment(edited)) {
      $0.comments[id: id] = edited
      $0.composer = nil
    }
    await store.finish()
    #expect(saved.value?.first?.body == "fix v2")

    // Delete: removes + persists the now-empty set.
    await store.send(.deleteComment(id: id)) {
      $0.comments.remove(id: id)
    }
    await store.finish()
    #expect(saved.value?.isEmpty == true)
  }

  // MARK: - E 6.4 — a sent batch persists empty (no ghost comments on reopen)

  @Test func sendBatchDoesNotRePersistClearedBatch() async {
    let worktree = gitWorktree()
    let workingID = worktree.id.rawValue
    let lastSaved = LockIsolated<[ReviewComment]?>(nil)
    var state = DiffReviewFeature.State()
    state.selectedWorktree = worktree
    state.comments = [reviewComment(body: "please fix")]
    let store = TestStore(initialState: state) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.terminalClient.hasAgentTerminalSurface = { _ in true }
      $0.terminalClient.send = { _ in }
      $0[CommentPersistenceStoreClient.self] = CommentPersistenceStoreClient(
        load: { _ in [] },
        save: { id, comments in if id == workingID { lastSaved.setValue(comments) } })
    }

    await store.send(.sendBatchToAgent) { $0.batchLocked = true }
    await store.receive(.sendBatchFinished(.sent)) {
      $0.comments.removeAll()
      $0.batchLocked = false
    }
    await store.finish()
    #expect(lastSaved.value?.isEmpty == true)  // the cleared batch is persisted empty
  }

  // MARK: - E 6.3 — reopen restores + relocates; orphan pinned never dropped

  @Test func persistReopenRestoresAndRelocates() async {
    let worktree = gitWorktree()
    let file = makeFile("a.swift")
    let key = DiffDocumentKey(path: "a.swift", source: .workingTree)
    let targetID = UUID()
    let goneID = UUID()
    let persisted = [
      reviewComment(id: targetID, start: 3, end: 3, snippet: "target", body: "note"),
      reviewComment(id: goneID, start: 5, end: 5, snippet: "vanished", body: "orphan"),
    ]
    var state = DiffReviewFeature.State()
    state.selectedWorktree = worktree
    state.files = [file]
    state.openDiffs = [key: DiffDocument(file: file, loadState: .loaded, generation: 7)]
    state.diffLoadToken = 7
    let store = TestStore(initialState: state) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    // Reopen restores the persisted set (tree derives from `comments`, not vice-versa).
    await store.send(.commentsLoaded(persisted))
    #expect(store.state.comments.count == 2)

    // Relocate on diffLoaded: "target" now sits at new line 9; "vanished" is gone.
    let hunk = DiffFixture.hunk(
      (1...8).map { DiffFixture.line(.context, old: $0, new: $0, "ctx\($0)") }
        + [DiffFixture.line(.context, old: 9, new: 9, "target")])
    await store.send(.diffLoaded(key: key, hunks: [hunk], token: 7))
    #expect(store.state.comments[id: targetID]?.startLine == 9)  // relocated
    #expect(store.state.comments[id: targetID]?.orphaned == false)
    #expect(store.state.comments[id: goneID]?.orphaned == true)  // pinned, never dropped
    #expect(store.state.comments[id: goneID] != nil)
  }

  // MARK: - Load-on-open wiring: selecting a worktree restores its persisted set

  @Test func reopenLoadsPersistedComments() async {
    let worktree = gitWorktree()
    let workingID = worktree.id.rawValue
    let persisted = [reviewComment(id: UUID(), body: "restored")]
    let store = TestStore(initialState: DiffReviewFeature.State()) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.changedFiles = { _, _ in WorktreeDiff(files: [], isUnbornHead: false, operation: .none) }
      $0.gitClient.automaticWorktreeBaseRef = { _ in nil }
      $0[CommentPersistenceStoreClient.self] = CommentPersistenceStoreClient(
        load: { id in id == workingID ? persisted : [] },
        save: { _, _ in })
    }
    store.exhaustivity = .off

    await store.send(.worktreeSelected(worktree, prBaseRefName: nil))
    await store.receive(.commentsLoaded(persisted)) {
      $0.comments = IdentifiedArray(uniqueElements: persisted)
    }
    await store.finish()
  }

  // MARK: - E 6.1 — gutter drag → split/insert → commit updates comments, source-scoped

  @Test(arguments: [DiffSource.workingTree, DiffSource.baseBranch(ref: "main")])
  func gutterDragInsertsComposerCommitUpdatesComments(source: DiffSource) async {
    let controller = ViewportTestSupport.controller()
    controller.apply(tree: ViewportTestSupport.contextLeaves(Array(1...10)), mode: .unified, scrollPreserving: false)
    let gutter = GutterRibbonController()
    gutter.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    gutter.controller = controller
    var opened: (start: Int, end: Int)?
    gutter.onOpenComposer = { _, start, end, _, _ in opened = (start, end) }

    let oldNumX = DiffHitTest.changeBarWidth + controller.gutterWidth / 2
    #expect(gutter.beginSelection(atDocument: CGPoint(x: oldNumX, y: 50)))  // line 3
    gutter.extendSelection(toDocument: CGPoint(x: oldNumX, y: 90))  // line 5
    _ = gutter.commitSelection()
    #expect(opened?.start == 3)
    #expect(opened?.end == 5)

    // Harness insert: the widget lands after line 5; lines below push down, anchor above unaffected.
    let anchorID = UUID()
    let line3Y = controller.lineRect(line: 3, side: .old)?.minY
    let line6ID = controller.lineLocation(line: 6, side: .old)?.chunkID
    let line6Before = line6ID.flatMap { controller.frame(forChunk: $0)?.minY }
    controller.insertCommentWidget(side: .old, startLine: 3, endLine: 5, anchorID: anchorID, estimatedHeight: 120)
    #expect(controller.lineRect(line: 3, side: .old)?.minY == line3Y)
    #expect(line6ID.flatMap { controller.frame(forChunk: $0)?.minY } == (line6Before ?? 0) + 120)
    #expect(controller.tree.widgetNode(for: .commentThread(anchorID: anchorID)) != nil)

    // Reducer commit, source-scoped.
    let worktree = gitWorktree()
    var state = DiffReviewFeature.State()
    state.selectedWorktree = worktree
    let store = TestStore(initialState: state) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
      $0[CommentPersistenceStoreClient.self] = .testValue
    }
    let comment = ReviewComment(
      id: anchorID, filePath: "a.swift", source: source, side: .old, startLine: 3, endLine: 5,
      anchorSnippet: "s", contextBefore: "", body: "fix", createdAt: Date(timeIntervalSince1970: 1000))
    await store.send(.commitComment(comment)) {
      $0.comments[id: anchorID] = comment
    }
    await store.finish()
    #expect(store.state.comments(forPath: "a.swift", source: source) == [comment])
    let otherSource: DiffSource = source == .workingTree ? .baseBranch(ref: "main") : .workingTree
    #expect(store.state.comments(forPath: "a.swift", source: otherSource).isEmpty)
  }

  // MARK: - E 6.2 — cancel removes the composer node; lines re-close; nothing committed

  @Test func cancelRemovesComposerNode() async {
    let controller = ViewportTestSupport.controller()
    controller.apply(tree: ViewportTestSupport.contextLeaves(Array(1...10)), mode: .unified, scrollPreserving: false)
    let anchorID = UUID()
    let line6ID = controller.lineLocation(line: 6, side: .new)?.chunkID
    let line6Before = line6ID.flatMap { controller.frame(forChunk: $0)?.minY }
    controller.insertCommentWidget(side: .new, startLine: 3, endLine: 5, anchorID: anchorID, estimatedHeight: 120)
    #expect(controller.tree.widgetNode(for: .commentThread(anchorID: anchorID)) != nil)
    #expect(line6ID.flatMap { controller.frame(forChunk: $0)?.minY } == (line6Before ?? 0) + 120)

    // Cancel: drop the editing node → the lines re-close to their prior pixels.
    #expect(controller.removeCommentWidget(anchorID: anchorID))
    #expect(controller.tree.widgetNode(for: .commentThread(anchorID: anchorID)) == nil)
    #expect(line6ID.flatMap { controller.frame(forChunk: $0)?.minY } == line6Before)

    // Reducer: cancel clears the composer, commits nothing.
    var state = DiffReviewFeature.State()
    state.selectedWorktree = gitWorktree()
    state.composer = CommentComposer.State(
      draft: ReviewComment(
        id: anchorID, filePath: "a.swift", side: .new, startLine: 3, endLine: 5,
        anchorSnippet: "s", contextBefore: "", body: "", createdAt: Date(timeIntervalSince1970: 0)),
      isEditing: false)
    let store = TestStore(initialState: state) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }
    await store.send(.composer(.presented(.delegate(.cancel)))) {
      $0.composer = nil
    }
    #expect(store.state.comments.isEmpty)
  }
}
