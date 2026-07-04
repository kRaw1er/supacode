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
      $0.diffClient.changedFiles = { _, _ in WorktreeDiff(files: files, isUnbornHead: false, operation: .none) }
      $0.gitClient.automaticWorktreeBaseRef = { _ in nil }  // no base → section 2 hidden
    }

    await store.send(.worktreeSelected(worktree, prBaseRefName: nil)) {
      $0.generation = 1
      $0.baseGeneration = 1
      $0.selectedWorktree = worktree
      $0.loadState = .loading
      $0.baseLoadState = .loading
    }
    // The base-ref resolve effect settles before the working-tree load in the
    // merged effect, so `.baseRefResolved` is received first.
    await store.receive(.baseRefResolved(ref: nil, generation: 1)) {
      $0.baseLoadState = .idle
    }
    await store.receive(.loaded(files, operation: .none, generation: 1)) {
      $0.files = files
      $0.loadState = .loaded
    }
  }

  // MARK: - base diff: PR base resolves & loads

  @Test(.dependencies) func selectingWorktreeWithPRResolvesAndLoadsBaseDiff() async {
    let worktree = gitLocalWorktree()
    let files = [makeFile("a.swift")]
    let baseFiles = [makeFile("committed.swift")]
    let store = TestStore(initialState: DiffReviewFeature.State()) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.changedFiles = { source, _ in
        switch source {
        case .workingTree: WorktreeDiff(files: files, isUnbornHead: false, operation: .none)
        case .baseBranch: WorktreeDiff(files: baseFiles, isUnbornHead: false, operation: .none)
        }
      }
      // PR base wins; the resolver never consults the default-branch fallback.
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/should-not-be-used" }
    }

    await store.send(.worktreeSelected(worktree, prBaseRefName: "main")) {
      $0.generation = 1
      $0.baseGeneration = 1
      $0.selectedWorktree = worktree
      $0.loadState = .loading
      $0.baseLoadState = .loading
    }
    // Merged-effect settle order: base resolve → working-tree load → base load.
    await store.receive(.baseRefResolved(ref: "main", generation: 1)) {
      $0.baseRef = "main"
    }
    await store.receive(.loaded(files, operation: .none, generation: 1)) {
      $0.files = files
      $0.loadState = .loaded
    }
    await store.receive(.baseLoaded(baseFiles, generation: 1)) {
      $0.baseFiles = baseFiles
      $0.baseLoadState = .loaded
    }
    #expect(store.state.baseRef == "main")
    #expect(store.state.baseFiles == baseFiles)
  }

  // MARK: - base diff: no PR → default-branch fallback

  @Test(.dependencies) func noPRFallsBackToDefaultBranch() async {
    let worktree = gitLocalWorktree()
    let store = TestStore(initialState: DiffReviewFeature.State()) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.changedFiles = { _, _ in WorktreeDiff(files: [], isUnbornHead: false, operation: .none) }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "origin/main" }
    }
    store.exhaustivity = .off

    await store.send(.worktreeSelected(worktree, prBaseRefName: nil))
    await store.receive(.baseRefResolved(ref: "origin/main", generation: 1)) {
      $0.baseRef = "origin/main"
      $0.baseLoadState = .loading
    }
    await store.receive(.baseLoaded([], generation: 1)) {
      $0.baseLoadState = .empty  // base == HEAD → up-to-date
    }
    #expect(store.state.baseRef == "origin/main")
  }

  // MARK: - base diff: unresolvable base hides section 2

  @Test(.dependencies) func unresolvableBaseHidesSectionTwo() async {
    let worktree = gitLocalWorktree()
    let files = [makeFile("a.swift")]
    let store = TestStore(initialState: DiffReviewFeature.State()) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.changedFiles = { _, _ in WorktreeDiff(files: files, isUnbornHead: false, operation: .none) }
      $0.gitClient.automaticWorktreeBaseRef = { _ in nil }  // nothing resolves
    }

    await store.send(.worktreeSelected(worktree, prBaseRefName: nil)) {
      $0.generation = 1
      $0.baseGeneration = 1
      $0.selectedWorktree = worktree
      $0.loadState = .loading
      $0.baseLoadState = .loading
    }
    await store.receive(.baseRefResolved(ref: nil, generation: 1)) {
      $0.baseLoadState = .idle
    }
    await store.receive(.loaded(files, operation: .none, generation: 1)) {
      $0.files = files
      $0.loadState = .loaded  // working-tree list still loads
    }
    #expect(store.state.baseRef == nil)
    #expect(store.state.supportsBaseDiff == false)
  }

  // MARK: - base generation guard discards a late base load

  @Test(.dependencies) func lateBaseLoadFromPreviousWorktreeIsDiscarded() async {
    let worktree = gitLocalWorktree()
    let store = TestStore(initialState: DiffReviewFeature.State()) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.changedFiles = { _, _ in WorktreeDiff(files: [], isUnbornHead: false, operation: .none) }
      $0.gitClient.automaticWorktreeBaseRef = { _ in nil }
    }
    store.exhaustivity = .off

    await store.send(.worktreeSelected(worktree, prBaseRefName: nil))
    // A base load tagged with the previous generation (0) must be dropped.
    await store.send(.baseLoaded([makeFile("stale.swift")], generation: 0))
    #expect(store.state.baseFiles.isEmpty)
  }

  // MARK: - mid-operation repository state (1.8) plumbed onto State

  @Test(.dependencies) func loadedSetsRepositoryOperationForBanner() async {
    let worktree = gitLocalWorktree()
    let files = [makeFile("a.swift")]
    let store = TestStore(initialState: DiffReviewFeature.State()) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.changedFiles = { _, _ in WorktreeDiff(files: files, isUnbornHead: false, operation: .rebase) }
      $0.gitClient.automaticWorktreeBaseRef = { _ in nil }
    }

    await store.send(.worktreeSelected(worktree, prBaseRefName: nil)) {
      $0.generation = 1
      $0.baseGeneration = 1
      $0.selectedWorktree = worktree
      $0.loadState = .loading
      $0.baseLoadState = .loading
    }
    await store.receive(.baseRefResolved(ref: nil, generation: 1)) {
      $0.baseLoadState = .idle
    }
    await store.receive(.loaded(files, operation: .rebase, generation: 1)) {
      $0.files = files
      $0.repositoryOperation = .rebase
      $0.loadState = .loaded
    }
    #expect(store.state.repositoryOperation.bannerMessage != nil)

    // Deselecting resets the operation so a stale banner never lingers.
    await store.send(.worktreeSelected(nil, prBaseRefName: nil)) {
      $0.generation = 2
      $0.baseGeneration = 2
      $0.selectedWorktree = nil
      $0.files = []
      $0.loadState = .idle
      $0.repositoryOperation = .none
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
      $0.diffClient.changedFiles = { _, _ in try await Task.never() }
      // Base resolves to nil immediately (exhaustivity is off, so the resulting
      // `.baseRefResolved(nil)` is tolerated); only the working-tree load is left
      // in-flight for the deselect to cancel.
      $0.gitClient.automaticWorktreeBaseRef = { _ in nil }
    }
    // The cancelled suspend may throw and enqueue a discarded `.failed`; keep the
    // assertion focused on the generation guard by relaxing exhaustivity.
    store.exhaustivity = .off

    await store.send(.worktreeSelected(worktree, prBaseRefName: nil)) {
      $0.generation = 1
      $0.baseGeneration = 1
      $0.selectedWorktree = worktree
      $0.loadState = .loading
      $0.baseLoadState = .loading
    }
    await store.send(.worktreeSelected(nil, prBaseRefName: nil)) {
      $0.generation = 2
      $0.baseGeneration = 2
      $0.selectedWorktree = nil
      $0.files = []
      $0.loadState = .idle
      $0.baseLoadState = .idle
    }
    // Gen-1 result arrives late; the guard drops it (current generation is 2).
    await store.send(.loaded(files, operation: .none, generation: 1))
    #expect(store.state.files.isEmpty)
    #expect(store.state.loadState == .idle)
  }

  // MARK: - folder unsupported (1.4) — client never called

  @Test(.dependencies) func folderWorktreeIsUnsupportedWithoutClientCall() async {
    let worktree = folderWorktree()
    let callCount = LockIsolated(0)
    let baseResolveCount = LockIsolated(0)
    let store = TestStore(initialState: DiffReviewFeature.State()) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.changedFiles = { _, _ in
        callCount.withValue { $0 += 1 }
        return WorktreeDiff(files: [], isUnbornHead: false, operation: .none)
      }
      $0.gitClient.automaticWorktreeBaseRef = { _ in
        baseResolveCount.withValue { $0 += 1 }
        return nil
      }
    }

    await store.send(.worktreeSelected(worktree, prBaseRefName: nil)) {
      $0.generation = 1
      $0.baseGeneration = 1
      $0.selectedWorktree = worktree
      $0.loadState = .unsupported(.folder)
    }
    #expect(callCount.value == 0)
    #expect(baseResolveCount.value == 0)  // folder → no base resolve/load
  }

  // MARK: - remote unsupported (1.5) — client never called

  @Test(.dependencies) func remoteWorktreeIsUnsupportedWithoutClientCall() async {
    let worktree = remoteWorktree()
    let callCount = LockIsolated(0)
    let baseResolveCount = LockIsolated(0)
    let store = TestStore(initialState: DiffReviewFeature.State()) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.changedFiles = { _, _ in
        callCount.withValue { $0 += 1 }
        return WorktreeDiff(files: [], isUnbornHead: false, operation: .none)
      }
      $0.gitClient.automaticWorktreeBaseRef = { _ in
        baseResolveCount.withValue { $0 += 1 }
        return nil
      }
    }

    await store.send(.worktreeSelected(worktree, prBaseRefName: nil)) {
      $0.generation = 1
      $0.baseGeneration = 1
      $0.selectedWorktree = worktree
      $0.loadState = .unsupported(.remote)
    }
    #expect(callCount.value == 0)
    #expect(baseResolveCount.value == 0)  // remote → no base resolve/load
  }

  // MARK: - empty (1.6)

  @Test(.dependencies) func emptyChangesMapToEmptyState() async {
    let worktree = gitLocalWorktree()
    let store = TestStore(initialState: DiffReviewFeature.State()) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.changedFiles = { _, _ in WorktreeDiff(files: [], isUnbornHead: false, operation: .none) }
      $0.gitClient.automaticWorktreeBaseRef = { _ in nil }
    }

    await store.send(.worktreeSelected(worktree, prBaseRefName: nil)) {
      $0.generation = 1
      $0.baseGeneration = 1
      $0.selectedWorktree = worktree
      $0.loadState = .loading
      $0.baseLoadState = .loading
    }
    await store.receive(.baseRefResolved(ref: nil, generation: 1)) {
      $0.baseLoadState = .idle
    }
    await store.receive(.loaded([], operation: .none, generation: 1)) {
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
      $0.diffClient.changedFiles = { _, _ in
        let attempt = callCount.withValue { count -> Int in
          count += 1
          return count
        }
        if attempt == 1 {
          return WorktreeDiff(files: files, isUnbornHead: false, operation: .none)
        }
        throw DiffError.indexLocked
      }
      $0.gitClient.automaticWorktreeBaseRef = { _ in nil }
    }

    await store.send(.worktreeSelected(worktree, prBaseRefName: nil)) {
      $0.generation = 1
      $0.baseGeneration = 1
      $0.selectedWorktree = worktree
      $0.loadState = .loading
      $0.baseLoadState = .loading
    }
    await store.receive(.baseRefResolved(ref: nil, generation: 1)) {
      $0.baseLoadState = .idle
    }
    await store.receive(.loaded(files, operation: .none, generation: 1)) {
      $0.files = files
      $0.loadState = .loaded
    }
    // Re-load keeps the last-good list (files non-empty ⇒ no `.loading` flash).
    // `baseRef` is nil, so `.load` issues no base effect.
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
      $0.diffClient.changedFiles = { _, _ in WorktreeDiff(files: files, isUnbornHead: false, operation: .none) }
      $0.gitClient.automaticWorktreeBaseRef = { _ in nil }
    }

    await store.send(.worktreeSelected(worktree, prBaseRefName: nil)) {
      $0.generation = 1
      $0.baseGeneration = 1
      $0.selectedWorktree = worktree
      $0.loadState = .loading
      $0.baseLoadState = .loading
    }
    await store.receive(.baseRefResolved(ref: nil, generation: 1)) {
      $0.baseLoadState = .idle
    }
    await store.receive(.loaded(files, operation: .none, generation: 1)) {
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
    await store.receive(.loaded(files, operation: .none, generation: 2))

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

    await store.send(.openFile(path: "a.swift", source: .workingTree))
    await store.finish()
    #expect(sent.value == [.openDiffTab(worktree, filePath: "a.swift", source: .workingTree)])
  }

  // MARK: - source-scoped openFile opens two distinct tabs + documents

  @Test(.dependencies) func openFileScopesTabAndDocumentBySource() async {
    let worktree = gitLocalWorktree()
    let file = makeFile("a.swift")
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = worktree
    initialState.files = [file]
    initialState.baseFiles = [file]
    initialState.baseRef = "main"
    initialState.loadState = .loaded
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
      $0.diffClient.diff = { _, _, _, _ in [] }
    }
    store.exhaustivity = .off

    await store.send(.openFile(path: "a.swift", source: .workingTree))
    await store.send(.openFile(path: "a.swift", source: .baseBranch(ref: "main")))
    await store.finish()

    // Two distinct documents keyed by `(path, source)`.
    #expect(store.state.openDiffs[DiffDocumentKey(path: "a.swift", source: .workingTree)] != nil)
    #expect(store.state.openDiffs[DiffDocumentKey(path: "a.swift", source: .baseBranch(ref: "main"))] != nil)
    #expect(store.state.openDiffs.count == 2)
    // Two `.openDiffTab` commands with different sources.
    #expect(
      sent.value.contains(.openDiffTab(worktree, filePath: "a.swift", source: .workingTree)))
    #expect(
      sent.value.contains(.openDiffTab(worktree, filePath: "a.swift", source: .baseBranch(ref: "main"))))
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
      $0.diffClient.diff = { _, _, _, _ in hunks }
    }

    let key = DiffDocumentKey(path: "a.swift", source: .workingTree)
    await store.send(.openFile(path: "a.swift", source: .workingTree)) {
      $0.diffLoadToken = 1
      $0.openDiffs[key] = DiffDocument(file: file, loadState: .loading, generation: 1)
    }
    await store.receive(\.diffLoaded) {
      var document = DiffDocument(file: file, loadState: .loading, generation: 1)
      document.hunks = hunks
      document.loadState = .loaded
      document.isStale = false
      document.rows = DiffRowBuilder.build(file: file, hunks: hunks, mode: .unified, expanded: [])
      document.revision = 1
      $0.openDiffs[key] = document
    }
  }

  // MARK: - mode toggle rebuilds open documents

  @Test(.dependencies) func diffModeChangedRebuildsRows() async {
    let file = makeFile("a.swift")
    let hunks = [modifiedHunk()]
    var document = DiffDocument(file: file, loadState: .loaded, generation: 1)
    document.hunks = hunks
    document.rows = DiffRowBuilder.build(file: file, hunks: hunks, mode: .unified, expanded: [])
    let key = DiffDocumentKey(path: "a.swift", source: .workingTree)
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = gitLocalWorktree()
    initialState.openDiffs = [key: document]
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off  // @Shared diffViewMode write is asserted separately.

    await store.send(.diffModeChanged(.split))
    #expect(store.state.diffViewMode == .split)
    #expect(
      store.state.openDiffs[key]?.rows
        == DiffRowBuilder.build(file: file, hunks: hunks, mode: .split, expanded: [])
    )
    #expect(store.state.openDiffs[key]?.revision == 1)
  }

  // MARK: - live update: vanished file goes stale, tab stays (3.2/3.3)

  @Test(.dependencies) func reloadMarksVanishedOpenDiffStale() async {
    let worktree = gitLocalWorktree()
    let file = makeFile("a.swift")
    var document = DiffDocument(file: file, loadState: .loaded, generation: 1)
    document.rows = DiffRowBuilder.build(file: file, hunks: [modifiedHunk()], mode: .unified, expanded: [])
    let key = DiffDocumentKey(path: "a.swift", source: .workingTree)
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = worktree
    initialState.files = [file]
    initialState.loadState = .loaded
    initialState.openDiffs = [key: document]
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.changedFiles = { _, _ in WorktreeDiff(files: [], isUnbornHead: false, operation: .none) }
    }

    // `baseRef` is nil, so `.load` issues no base effect.
    await store.send(.load) { $0.generation = 1 }
    await store.receive(\.loaded) {
      $0.files = []
      $0.loadState = .empty
      $0.openDiffs[key]?.isStale = true
    }
    // Tab stays open with its last-rendered rows.
    #expect(store.state.openDiffs[key]?.rows.isEmpty == false)
  }

  // MARK: - expandGap re-diffs with raised context

  @Test(.dependencies) func expandGapReDiffsWithRaisedContext() async {
    let worktree = gitLocalWorktree()
    let file = makeFile("a.swift")
    let context = LockIsolated<UInt32>(0)
    let fullHunk = modifiedHunk()
    var document = DiffDocument(file: file, loadState: .loaded, generation: 3)
    document.hunks = [modifiedHunk()]
    let key = DiffDocumentKey(path: "a.swift", source: .workingTree)
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = worktree
    initialState.files = [file]
    initialState.openDiffs = [key: document]
    initialState.diffLoadToken = 3
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.diff = { _, _, requestedContext, _ in
        context.setValue(requestedContext)
        return [fullHunk]
      }
    }
    store.exhaustivity = .off

    await store.send(.expandGap(path: "a.swift", source: .workingTree, anchor: 5)) {
      $0.diffLoadToken = 4
      $0.openDiffs[key]?.expanded = [5]
      $0.openDiffs[key]?.generation = 4
    }
    await store.receive(\.diffLoaded)
    #expect(context.value > 3)  // raised well above the git default of 3.
  }

  // MARK: - Phase 5: comments + send-to-agent

  private func reviewComment(
    path: String = "a.swift",
    start: Int = 3,
    end: Int = 3,
    snippet: String = "target",
    body: String = "please fix",
    side: DiffSide = .new
  ) -> ReviewComment {
    ReviewComment(
      id: UUID(),
      filePath: path,
      side: side,
      startLine: start,
      endLine: end,
      anchorSnippet: snippet,
      contextBefore: "",
      body: body,
      createdAt: Date(timeIntervalSince1970: 0)
    )
  }

  @Test(.dependencies) func sendBatchInjectsPromptAndClearsComments() async {
    let worktree = gitLocalWorktree()
    let comment = reviewComment()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = worktree
    initialState.comments = [comment]
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.terminalClient.hasAgentTerminalSurface = { _ in true }
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    }

    await store.send(.sendBatchToAgent) {
      $0.batchLocked = true
    }
    await store.receive(.sendBatchFinished(.sent)) {
      $0.comments.removeAll()
      $0.batchLocked = false
    }
    await store.finish()

    #expect(sent.value.count == 1)
    if case .insertTextIntoFocusedSurface(let target, let text, let submit) = sent.value.first {
      #expect(target == worktree)
      #expect(submit == true)
      #expect(text.contains("please fix"))
    } else {
      Issue.record("expected insertTextIntoFocusedSurface, got \(String(describing: sent.value.first))")
    }
  }

  @Test(.dependencies) func sendBatchWithoutTerminalKeepsBatchAndAlerts() async {
    let worktree = gitLocalWorktree()
    let comment = reviewComment()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = worktree
    initialState.comments = [comment]
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.terminalClient.hasAgentTerminalSurface = { _ in false }
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    }

    await store.send(.sendBatchToAgent) {
      $0.alert = .noAgentTerminal
    }
    // Batch retained; no terminal command dispatched (5.7).
    #expect(store.state.comments == [comment])
    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func sendEmptyBatchIsNoop() async {
    let worktree = gitLocalWorktree()
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = worktree
    initialState.comments = [reviewComment(body: "   ")]  // whitespace-only → dropped
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.terminalClient.hasAgentTerminalSurface = { _ in true }
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    }

    await store.send(.sendBatchToAgent)  // build → nil ⇒ no-op
    #expect(sent.value.isEmpty)
  }

  @Test(.dependencies) func diffLoadedRelocatesCommentsThroughAnchor() async {
    let worktree = gitLocalWorktree()
    let file = makeFile("a.swift")
    let comment = reviewComment(start: 3, end: 3, snippet: "target")
    let key = DiffDocumentKey(path: "a.swift", source: .workingTree)
    let document = DiffDocument(file: file, loadState: .loaded, generation: 5)
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = worktree
    initialState.files = [file]
    initialState.openDiffs = [key: document]
    initialState.diffLoadToken = 5
    initialState.comments = [comment]
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    // Re-diff: "target" moved from line 3 to line 5 (2 lines inserted above).
    let line = { (number: Int, content: String) in
      DiffLine(origin: .context, oldLineNumber: nil, newLineNumber: number, content: content, noNewlineAtEof: false)
    }
    let hunk = DiffHunk(
      oldStart: 1, oldCount: 3, newStart: 1, newCount: 5, header: "@@ -1,3 +1,5 @@",
      lines: [line(1, "a"), line(2, "b"), line(3, "c"), line(4, "d"), line(5, "target")]
    )
    await store.send(.diffLoaded(key: key, hunks: [hunk], token: 5))
    #expect(store.state.comments[id: comment.id]?.startLine == 5)
    #expect(store.state.comments[id: comment.id]?.orphaned == false)
  }

  // MARK: - comments are isolated by source

  @Test(.dependencies) func commentsAreIsolatedBySource() {
    let file = makeFile("a.swift")
    let workingComment = reviewComment(body: "working note")
    var baseComment = reviewComment(body: "base note")
    baseComment.source = .baseBranch(ref: "main")
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = gitLocalWorktree()
    initialState.files = [file]
    initialState.baseFiles = [file]
    initialState.baseRef = "main"
    initialState.comments = [workingComment, baseComment]

    // A working-tree document only sees the working-tree comment, and vice versa.
    #expect(initialState.comments(forPath: "a.swift", source: .workingTree) == [workingComment])
    #expect(initialState.comments(forPath: "a.swift", source: .baseBranch(ref: "main")) == [baseComment])
  }

  // MARK: - HEAD-tick refreshes the base list without re-resolving

  @Test(.dependencies) func headTickRefreshesBaseWithoutReResolving() async {
    let worktree = gitLocalWorktree()
    let resolveCount = LockIsolated(0)
    let baseFiles = [makeFile("committed.swift")]
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = worktree
    initialState.files = []
    initialState.baseFiles = baseFiles
    initialState.baseRef = "main"
    initialState.baseLoadState = .loaded
    initialState.loadState = .loaded
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.changedFiles = { _, _ in WorktreeDiff(files: baseFiles, isUnbornHead: false, operation: .none) }
      $0.gitClient.automaticWorktreeBaseRef = { _ in
        resolveCount.withValue { $0 += 1 }
        return "origin/should-not-resolve"
      }
    }
    store.exhaustivity = .off

    // A `.load` (post-tick) bumps `baseGeneration` and re-diffs the base against
    // the already-resolved ref — no re-resolution.
    await store.send(.load) {
      $0.generation = 1
      $0.baseGeneration = 1
    }
    await store.receive(.baseLoaded(baseFiles, generation: 1)) {
      $0.baseFiles = baseFiles
      $0.baseLoadState = .loaded
    }
    await store.finish()
    #expect(resolveCount.value == 0)  // base ref never re-resolved on a tick
    #expect(store.state.baseRef == "main")
  }

  @Test(.dependencies) func requestDiscardPresentsConfirmAndDiscardClears() async {
    let comment = reviewComment()
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = gitLocalWorktree()
    initialState.comments = [comment]
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }

    await store.send(.requestDiscardBatch) {
      $0.discardConfirm = DiffReviewFeature.discardConfirmDialog(count: 1)
    }
    await store.send(.discardConfirm(.presented(.discard))) {
      $0.discardConfirm = nil
      $0.comments.removeAll()
    }
  }

  @Test(.dependencies) func requestDiscardKeepRetainsComments() async {
    let comment = reviewComment()
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = gitLocalWorktree()
    initialState.comments = [comment]
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }

    await store.send(.requestDiscardBatch) {
      $0.discardConfirm = DiffReviewFeature.discardConfirmDialog(count: 1)
    }
    // "Keep" == dismiss; the batch is retained.
    await store.send(.discardConfirm(.dismiss)) {
      $0.discardConfirm = nil
    }
    #expect(store.state.comments == [comment])
  }
}
