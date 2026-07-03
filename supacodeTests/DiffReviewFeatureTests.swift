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
}
