import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

@MainActor
struct DiffReviewFeatureTests {
  // MARK: - Fixtures

  private func gitLocalWorktree(path: String = "/tmp/repo/wt") -> Worktree {
    let url = URL(filePath: path)
    return Worktree(
      id: WorktreeID(path),
      name: "wt",
      detail: "",
      workingDirectory: url,
      repositoryRootURL: URL(filePath: "/tmp/repo")
    )
  }

  private func folderWorktree() -> Worktree {
    let url = URL(filePath: "/tmp/folder")
    return Worktree(
      id: WorktreeID("folder:/tmp/folder"),
      kind: .folder,
      name: "folder",
      detail: "",
      workingDirectory: url,
      repositoryRootURL: url
    )
  }

  private func remoteWorktree() -> Worktree {
    Worktree(
      id: WorktreeID("devbox:/remote/wt"),
      name: "wt",
      detail: "",
      workingDirectory: URL(filePath: "/remote/wt"),
      repositoryRootURL: URL(filePath: "/remote"),
      host: RemoteHost(alias: "devbox")
    )
  }

  private func makeFile(_ path: String, added: Int = 1, removed: Int = 0) -> FileChange {
    FileChange(
      oldPath: nil,
      newPath: path,
      status: .modified,
      addedLines: added,
      removedLines: removed,
      isBinary: false,
      isLargeFileCapped: false,
      hasLongLines: false,
      similarity: 0
    )
  }

  // MARK: - select → load

  @Test(.dependencies) func selectingGitWorktreeLoadsChanges() async {
    let worktree = gitLocalWorktree()
    let files = [makeFile("a.swift"), makeFile("b.swift")]
    let store = TestStore(initialState: DiffReviewFeature.State()) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.changedFiles = { _ in WorktreeDiff(files: files, isUnbornHead: false, operation: .none) }
    }

    await store.send(.worktreeSelected(worktree)) {
      $0.generation = 1
      $0.selectedWorktree = worktree
      $0.loadState = .loading
    }
    await store.receive(.loaded(files, generation: 1)) {
      $0.files = files
      $0.loadState = .loaded
    }
  }

  // MARK: - deselect discards stale (8.1)

  @Test(.dependencies) func deselectDiscardsStaleLoadedResult() async {
    let worktree = gitLocalWorktree()
    let files = [makeFile("a.swift")]
    let store = TestStore(initialState: DiffReviewFeature.State()) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      // Suspend forever so the gen-1 load never resolves on its own; the nil
      // selection cancels it. We then deliver a gen-1 `.loaded` by hand.
      $0.diffClient.changedFiles = { _ in try await Task.never() }
    }
    // The cancelled suspend may throw and enqueue a discarded `.failed`; keep the
    // assertion focused on the generation guard by relaxing exhaustivity.
    store.exhaustivity = .off

    await store.send(.worktreeSelected(worktree)) {
      $0.generation = 1
      $0.selectedWorktree = worktree
      $0.loadState = .loading
    }
    await store.send(.worktreeSelected(nil)) {
      $0.generation = 2
      $0.selectedWorktree = nil
      $0.files = []
      $0.loadState = .idle
    }
    // Gen-1 result arrives late; the guard drops it (current generation is 2).
    await store.send(.loaded(files, generation: 1))
    #expect(store.state.files.isEmpty)
    #expect(store.state.loadState == .idle)
  }

  // MARK: - folder unsupported (1.4) — client never called

  @Test(.dependencies) func folderWorktreeIsUnsupportedWithoutClientCall() async {
    let worktree = folderWorktree()
    let callCount = LockIsolated(0)
    let store = TestStore(initialState: DiffReviewFeature.State()) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.changedFiles = { _ in
        callCount.withValue { $0 += 1 }
        return WorktreeDiff(files: [], isUnbornHead: false, operation: .none)
      }
    }

    await store.send(.worktreeSelected(worktree)) {
      $0.generation = 1
      $0.selectedWorktree = worktree
      $0.loadState = .unsupported(.folder)
    }
    #expect(callCount.value == 0)
  }

  // MARK: - remote unsupported (1.5) — client never called

  @Test(.dependencies) func remoteWorktreeIsUnsupportedWithoutClientCall() async {
    let worktree = remoteWorktree()
    let callCount = LockIsolated(0)
    let store = TestStore(initialState: DiffReviewFeature.State()) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.changedFiles = { _ in
        callCount.withValue { $0 += 1 }
        return WorktreeDiff(files: [], isUnbornHead: false, operation: .none)
      }
    }

    await store.send(.worktreeSelected(worktree)) {
      $0.generation = 1
      $0.selectedWorktree = worktree
      $0.loadState = .unsupported(.remote)
    }
    #expect(callCount.value == 0)
  }

  // MARK: - empty (1.6)

  @Test(.dependencies) func emptyChangesMapToEmptyState() async {
    let worktree = gitLocalWorktree()
    let store = TestStore(initialState: DiffReviewFeature.State()) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.changedFiles = { _ in WorktreeDiff(files: [], isUnbornHead: false, operation: .none) }
    }

    await store.send(.worktreeSelected(worktree)) {
      $0.generation = 1
      $0.selectedWorktree = worktree
      $0.loadState = .loading
    }
    await store.receive(.loaded([], generation: 1)) {
      $0.loadState = .empty
    }
  }

  // MARK: - index.lock keeps last-good (1.7)

  @Test(.dependencies) func indexLockKeepsLastGoodFiles() async {
    let worktree = gitLocalWorktree()
    let files = [makeFile("a.swift"), makeFile("b.swift")]
    let callCount = LockIsolated(0)
    let store = TestStore(initialState: DiffReviewFeature.State()) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.changedFiles = { _ in
        let attempt = callCount.withValue { count -> Int in
          count += 1
          return count
        }
        if attempt == 1 {
          return WorktreeDiff(files: files, isUnbornHead: false, operation: .none)
        }
        throw DiffError.indexLocked
      }
    }

    await store.send(.worktreeSelected(worktree)) {
      $0.generation = 1
      $0.selectedWorktree = worktree
      $0.loadState = .loading
    }
    await store.receive(.loaded(files, generation: 1)) {
      $0.files = files
      $0.loadState = .loaded
    }
    // Re-load keeps the last-good list (files non-empty ⇒ no `.loading` flash).
    await store.send(.load) {
      $0.generation = 2
    }
    await store.receive(.failed(.indexLocked, generation: 2)) {
      $0.loadState = .refreshing
    }
    #expect(store.state.files == files)
  }

  // MARK: - debounced filesChanged (4.4)

  @Test(.dependencies) func filesChangedIsDebouncedIntoSingleReload() async {
    let worktree = gitLocalWorktree()
    let files = [makeFile("a.swift")]
    let clock = TestClock()
    let store = TestStore(initialState: DiffReviewFeature.State()) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.diffClient.changedFiles = { _ in WorktreeDiff(files: files, isUnbornHead: false, operation: .none) }
    }

    await store.send(.worktreeSelected(worktree)) {
      $0.generation = 1
      $0.selectedWorktree = worktree
      $0.loadState = .loading
    }
    await store.receive(.loaded(files, generation: 1)) {
      $0.files = files
      $0.loadState = .loaded
    }

    // Two rapid ticks; cancelInFlight restarts the window, so only one fires.
    await store.send(.filesChanged(worktree.id))
    await store.send(.filesChanged(worktree.id))

    await clock.advance(by: .milliseconds(250))
    await store.receive(.refreshTick)
    await store.receive(.load) {
      $0.generation = 2
    }
    await store.receive(.loaded(files, generation: 2))

    // A tick for a different worktree id is a no-op (no debounce effect fires).
    let other = gitLocalWorktree(path: "/tmp/repo/other")
    await store.send(.filesChanged(other.id))
  }

  // MARK: - openFile → openDiffTab

  @Test(.dependencies) func openFileSendsOpenDiffTabCommand() async {
    let worktree = gitLocalWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = worktree
    initialState.loadState = .loaded
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    }

    await store.send(.openFile(path: "a.swift"))
    await store.finish()
    #expect(sent.value == [.openDiffTab(worktree, filePath: "a.swift")])
  }

  // MARK: - openFile loads hunks → builds rows (Phase 3)

  private func modifiedHunk() -> DiffHunk {
    DiffHunk(
      oldStart: 1,
      oldCount: 1,
      newStart: 1,
      newCount: 2,
      header: "@@ -1 +1,2 @@",
      lines: [
        DiffLine(origin: .context, oldLineNumber: 1, newLineNumber: 1, content: "keep", noNewlineAtEof: false),
        DiffLine(origin: .addition, oldLineNumber: nil, newLineNumber: 2, content: "added", noNewlineAtEof: false),
      ]
    )
  }

  @Test(.dependencies) func openFileLoadsHunksAndBuildsRows() async {
    let worktree = gitLocalWorktree()
    let file = makeFile("a.swift")
    let hunks = [modifiedHunk()]
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = worktree
    initialState.files = [file]
    initialState.loadState = .loaded
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.terminalClient.send = { _ in }
      $0.diffClient.diff = { _, _, _ in hunks }
    }

    await store.send(.openFile(path: "a.swift")) {
      $0.diffLoadToken = 1
      $0.openDiffs["a.swift"] = DiffDocument(file: file, loadState: .loading, generation: 1)
    }
    await store.receive(\.diffLoaded) {
      var document = DiffDocument(file: file, loadState: .loading, generation: 1)
      document.hunks = hunks
      document.loadState = .loaded
      document.isStale = false
      document.rows = DiffRowBuilder.build(file: file, hunks: hunks, mode: .unified, expanded: [])
      document.revision = 1
      $0.openDiffs["a.swift"] = document
    }
  }

  // MARK: - mode toggle rebuilds open documents

  @Test(.dependencies) func diffModeChangedRebuildsRows() async {
    let file = makeFile("a.swift")
    let hunks = [modifiedHunk()]
    var document = DiffDocument(file: file, loadState: .loaded, generation: 1)
    document.hunks = hunks
    document.rows = DiffRowBuilder.build(file: file, hunks: hunks, mode: .unified, expanded: [])
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = gitLocalWorktree()
    initialState.openDiffs = ["a.swift": document]
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off  // @Shared diffViewMode write is asserted separately.

    await store.send(.diffModeChanged(.split))
    #expect(store.state.diffViewMode == .split)
    #expect(
      store.state.openDiffs["a.swift"]?.rows
        == DiffRowBuilder.build(file: file, hunks: hunks, mode: .split, expanded: [])
    )
    #expect(store.state.openDiffs["a.swift"]?.revision == 1)
  }

  // MARK: - live update: vanished file goes stale, tab stays (3.2/3.3)

  @Test(.dependencies) func reloadMarksVanishedOpenDiffStale() async {
    let worktree = gitLocalWorktree()
    let file = makeFile("a.swift")
    var document = DiffDocument(file: file, loadState: .loaded, generation: 1)
    document.rows = DiffRowBuilder.build(file: file, hunks: [modifiedHunk()], mode: .unified, expanded: [])
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = worktree
    initialState.files = [file]
    initialState.loadState = .loaded
    initialState.openDiffs = ["a.swift": document]
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.changedFiles = { _ in WorktreeDiff(files: [], isUnbornHead: false, operation: .none) }
    }

    await store.send(.load) { $0.generation = 1 }
    await store.receive(\.loaded) {
      $0.files = []
      $0.loadState = .empty
      $0.openDiffs["a.swift"]?.isStale = true
    }
    // Tab stays open with its last-rendered rows.
    #expect(store.state.openDiffs["a.swift"]?.rows.isEmpty == false)
  }

  // MARK: - expandGap re-diffs with raised context

  @Test(.dependencies) func expandGapReDiffsWithRaisedContext() async {
    let worktree = gitLocalWorktree()
    let file = makeFile("a.swift")
    let context = LockIsolated<UInt32>(0)
    let fullHunk = modifiedHunk()
    var document = DiffDocument(file: file, loadState: .loaded, generation: 3)
    document.hunks = [modifiedHunk()]
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = worktree
    initialState.files = [file]
    initialState.openDiffs = ["a.swift": document]
    initialState.diffLoadToken = 3
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.diff = { _, _, requestedContext in
        context.setValue(requestedContext)
        return [fullHunk]
      }
    }
    store.exhaustivity = .off

    await store.send(.expandGap(path: "a.swift", anchor: 5)) {
      $0.diffLoadToken = 4
      $0.openDiffs["a.swift"]?.expanded = [5]
      $0.openDiffs["a.swift"]?.generation = 4
    }
    await store.receive(\.diffLoaded)
    #expect(context.value > 3)  // raised well above the git default of 3.
  }
}
