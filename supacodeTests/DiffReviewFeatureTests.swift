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
      $0.diffClient.diff = { _, _, _, _, _ in [] }
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

  @Test(.dependencies) func openFileLoadsHunks() async {
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
      $0.diffClient.diff = { _, _, _, _, _ in hunks }
    }

    let key = DiffDocumentKey(path: "a.swift", source: .workingTree)
    await store.send(.openFile(path: "a.swift", source: .workingTree)) {
      $0.diffLoadToken = 1
      $0.openDiffs[key] = DiffDocument(file: file, loadState: .loading, generation: 1)
    }
    // Post-P13 seam swap: `.diffLoaded` stores hunks for the tree-backed viewport
    // to project — the deleted flat `rows` / `revision` are never touched.
    await store.receive(\.diffLoaded) {
      var document = DiffDocument(file: file, loadState: .loading, generation: 1)
      document.hunks = hunks
      document.loadState = .loaded
      document.isStale = false
      // The load feeds the highlighter (production path): it captures the per-side blobs
      // and evaluates the size gate. Syntax runs are now a pure render-layer pull off the
      // span cache — no runs / delivery revision live on the document any more.
      $0.openDiffs[key] = document
    }
  }

  /// REGRESSION — the "all text white" second root cause: the on-demand (production)
  /// load path must fetch the highlight blobs alongside the hunks, not leave them nil
  /// (they were only wired to the streaming path, which is gated OFF in production).
  @Test(.dependencies) func openFileLoadsHighlightBlobsOnProductionPath() async {
    let worktree = gitLocalWorktree()
    let file = makeFile("a.swift")
    let hunks = [modifiedHunk()]
    let oldInput = HighlightBlobInput(blobOID: "old", utf16: Array("let x = 1".utf16), path: "a.swift")
    let newInput = HighlightBlobInput(blobOID: "new", utf16: Array("let y = 2".utf16), path: "a.swift")
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = worktree
    initialState.files = [file]
    initialState.loadState = .loaded
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.terminalClient.send = { _ in }
      $0.diffClient.diff = { _, _, _, _, _ in hunks }
      $0.diffClient.highlightBlobs = { _, _, _ in (old: oldInput, new: newInput) }
    }
    store.exhaustivity = .off

    let key = DiffDocumentKey(path: "a.swift", source: .workingTree)
    await store.send(.openFile(path: "a.swift", source: .workingTree))
    await store.receive(\.diffLoaded)

    #expect(store.state.openDiffs[key]?.oldBlob == oldInput, "the production load path must populate the old blob")
    #expect(store.state.openDiffs[key]?.newBlob == newInput, "the production load path must populate the new blob")
    #expect(store.state.openDiffs[key]?.highlightingDisabled == false, "a normal file must stay highlightable")
  }

  // MARK: - mode toggle persists the global preference (dual-mode tree re-seek)

  @Test(.dependencies) func diffModeChangedPersistsPreference() async {
    let file = makeFile("a.swift")
    let hunks = [modifiedHunk()]
    var document = DiffDocument(file: file, loadState: .loaded, generation: 1)
    document.hunks = hunks
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
    // Post-P13: the tree is dual-mode — the toggle only persists the preference; the
    // document's hunks are untouched (no per-doc row rebuild, no `revision`).
    #expect(store.state.diffViewMode == .split)
    #expect(store.state.openDiffs[key]?.hunks == hunks)
  }

  // MARK: - ignore-whitespace toggle re-diffs open tabs through the flag (F9/#20)

  /// The header toggle flips `state.ignoreWhitespace` and re-diffs every open tab,
  /// threading the flag all the way to `DiffClient.diff`. Reverting the wiring (the
  /// request no longer carries `ignoreWhitespace`, or the handler no longer re-diffs)
  /// makes this fail: the client receives `false` (or is never called).
  @Test(.dependencies) func ignoreWhitespaceToggleReDiffsOpenTabsWithFlag() async {
    let file = makeFile("a.swift")
    var document = DiffDocument(file: file, loadState: .loaded, generation: 1)
    document.hunks = [modifiedHunk()]
    let key = DiffDocumentKey(path: "a.swift", source: .workingTree)
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = gitLocalWorktree()
    initialState.files = [file]
    initialState.loadState = .loaded
    initialState.openDiffs = [key: document]

    let received = LockIsolated<[Bool]>([])
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.diff = { _, _, _, _, ignoreWhitespace in
        received.withValue { $0.append(ignoreWhitespace) }
        return []
      }
    }
    store.exhaustivity = .off  // @Shared ignoreWhitespace write + re-diff token churn asserted directly.

    await store.send(.ignoreWhitespaceToggled(true))
    #expect(store.state.ignoreWhitespace == true)
    await store.receive(\.diffLoaded)
    #expect(received.value == [true], "the re-diff must thread ignoreWhitespace=true to the client")

    // Toggling to the same value is a no-op — no second re-diff.
    await store.send(.ignoreWhitespaceToggled(true))
    #expect(received.value == [true])
  }

  // MARK: - live update: vanished file goes stale, tab stays (3.2/3.3)

  @Test(.dependencies) func reloadMarksVanishedOpenDiffStale() async {
    let worktree = gitLocalWorktree()
    let file = makeFile("a.swift")
    var document = DiffDocument(file: file, loadState: .loaded, generation: 1)
    document.hunks = [modifiedHunk()]
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
    // Tab stays open (marked stale) with its last-loaded hunks for the viewport.
    #expect(store.state.openDiffs[key]?.isStale == true)
    #expect(store.state.openDiffs[key]?.hunks.isEmpty == false)
  }

  // MARK: - Phase 7: incremental collapse / expand (blob-slice, NO re-diff)

  /// A two-hunk file with an inter-hunk gap keyed `GapKey(1)`: hunk 0 covers new
  /// lines 1…3; hunk 1 starts at new line 40 — the gap is new lines 4…39 (36 lines).
  /// Old/new advance in lockstep so `oldLineDelta` is 0.
  private func twoHunkFile() -> (FileChange, [DiffHunk]) {
    let file = makeFile("a.swift")
    let hunk0 = DiffHunk(
      oldStart: 1, oldCount: 3, newStart: 1, newCount: 3, header: "@@ -1,3 +1,3 @@",
      lines: [
        DiffLine(origin: .context, oldLineNumber: 1, newLineNumber: 1, content: "a", noNewlineAtEof: false),
        DiffLine(origin: .deletion, oldLineNumber: 2, newLineNumber: nil, content: "b-old", noNewlineAtEof: false),
        DiffLine(origin: .addition, oldLineNumber: nil, newLineNumber: 2, content: "b-new", noNewlineAtEof: false),
        DiffLine(origin: .context, oldLineNumber: 3, newLineNumber: 3, content: "c", noNewlineAtEof: false),
      ])
    let hunk1 = DiffHunk(
      oldStart: 40, oldCount: 2, newStart: 40, newCount: 2, header: "@@ -40,2 +40,2 @@",
      lines: [
        DiffLine(origin: .deletion, oldLineNumber: 40, newLineNumber: nil, content: "z-old", noNewlineAtEof: false),
        DiffLine(origin: .addition, oldLineNumber: nil, newLineNumber: 40, content: "z-new", noNewlineAtEof: false),
        DiffLine(origin: .context, oldLineNumber: 41, newLineNumber: 41, content: "tail", noNewlineAtEof: false),
      ])
    return (file, [hunk0, hunk1])
  }

  private func expansionStore(file: FileChange, hunks: [DiffHunk]) -> TestStoreOf<DiffReviewFeature> {
    let key = DiffDocumentKey(path: file.id, source: .workingTree)
    var document = DiffDocument(file: file, loadState: .loaded, generation: 1)
    document.hunks = hunks
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = gitLocalWorktree()
    initialState.files = [file]
    initialState.openDiffs = [key: document]
    initialState.diffLoadToken = 1
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      // Deterministic fixture slice (BlobSliceClient.testValue) so no filesystem.
    }
    store.exhaustivity = .off
    return store
  }

  @Test(.dependencies) func expandGapFinePerCoarseWhole() async {
    let (file, hunks) = twoHunkFile()
    let key = DiffDocumentKey(path: file.id, source: .workingTree)
    let store = expansionStore(file: file, hunks: hunks)

    // FINE up: region grows fromStart += 20; a slice fires and appends to revealed.
    await store.send(.expandGap(key: key, gap: 1, step: .fine, direction: .up))
    await store.receive(\.gapSliceLoaded)
    #expect(store.state.openDiffs[key]?.expansion == .regions([1: HunkExpansionRegion(fromStart: 20)]))
    #expect(store.state.openDiffs[key]?.revealed[1]?.count == 20)  // 20 fine lines revealed
    #expect(store.state.openDiffs[key]?.revealed[1]?.first?.newLineNumber == 4)  // gap starts at new line 4

    // COARSE up: region grows fromStart += 100 → clamps to the 37-line gap ⇒ renderAll.
    await store.send(.expandGap(key: key, gap: 1, step: .coarse, direction: .up))
    await store.receive(\.gapSliceLoaded)
    #expect(store.state.openDiffs[key]?.expansion == .regions([1: HunkExpansionRegion(fromStart: 120)]))
    #expect(store.state.openDiffs[key]?.revealed[1]?.count == 36)  // whole gap revealed (lines 4…39)

    // COLLAPSE: region removed, revealed cleared.
    await store.send(.collapseGap(key: key, gap: 1))
    #expect(store.state.openDiffs[key]?.expansion == .regions([:]))
    #expect(store.state.openDiffs[key]?.revealed[1] == nil)

    // WHOLE: promotes past the gap size in one shot ⇒ renderAll, one slice.
    await store.send(.expandGap(key: key, gap: 1, step: .whole, direction: .both))
    await store.receive(\.gapSliceLoaded)
    #expect(store.state.openDiffs[key]?.revealed[1]?.count == 36)
    await store.finish()
  }

  /// ⇧E (`.diffExpandContext` with delta < 0) is SYMMETRIC to `e`: it shrinks each gap
  /// by ONE fine step, it does NOT wipe straight to collapsed. A two-step expand shrunk
  /// once lands at one fine step (revealed kept — a partial shrink is capped by the
  /// resolved region, not by trimming `revealed`); a further shrink prunes the gap to
  /// no-region ⇒ `.collapsed` and only THEN clears `revealed[gap]`.
  @Test(.dependencies) func lessContextShrinksOneStepNotAllTheWay() async {
    let (file, hunks) = twoHunkFile()
    let key = DiffDocumentKey(path: file.id, source: .workingTree)
    let store = expansionStore(file: file, hunks: hunks)

    // Two fine expands on gap 1 ⇒ fromStart 40.
    await store.send(.expandGap(key: key, gap: 1, step: .fine, direction: .up))
    await store.receive(\.gapSliceLoaded)
    await store.send(.expandGap(key: key, gap: 1, step: .fine, direction: .up))
    await store.receive(\.gapSliceLoaded)
    #expect(store.state.openDiffs[key]?.expansion == .regions([1: HunkExpansionRegion(fromStart: 40)]))
    #expect(store.state.openDiffs[key]?.revealed[1]?.isEmpty == false)

    // ⇧E once: shrink one fine step ⇒ fromStart 20 (NOT collapsed); `revealed` kept
    // (partial shrink — the resolved region caps display, revealed stays over-populated).
    await store.send(.diffExpandContext(fileID: file.id, delta: -1))
    #expect(store.state.openDiffs[key]?.expansion == .regions([1: HunkExpansionRegion(fromStart: 20)]))
    #expect(store.state.openDiffs[key]?.revealed[1]?.isEmpty == false)

    // ⇧E again: the last step prunes gap 1 to no-region ⇒ `.collapsed`, and NOW revealed clears.
    await store.send(.diffExpandContext(fileID: file.id, delta: -1))
    #expect(store.state.openDiffs[key]?.expansion == .collapsed)
    #expect(store.state.openDiffs[key]?.revealed[1] == nil)
    await store.finish()
  }

  @Test(.dependencies) func oneGapOnlyExpands() async {
    // A three-hunk file → two inter-hunk gaps, GapKey(1) and GapKey(2).
    let file = makeFile("a.swift")
    let hunk0 = DiffHunk(
      oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, header: "@@",
      lines: [DiffLine(origin: .context, oldLineNumber: 1, newLineNumber: 1, content: "a", noNewlineAtEof: false)])
    let hunk1 = DiffHunk(
      oldStart: 20, oldCount: 1, newStart: 20, newCount: 1, header: "@@",
      lines: [DiffLine(origin: .context, oldLineNumber: 20, newLineNumber: 20, content: "m", noNewlineAtEof: false)])
    let hunk2 = DiffHunk(
      oldStart: 60, oldCount: 1, newStart: 60, newCount: 1, header: "@@",
      lines: [DiffLine(origin: .context, oldLineNumber: 60, newLineNumber: 60, content: "z", noNewlineAtEof: false)])
    let diffCalls = LockIsolated(0)
    let key = DiffDocumentKey(path: file.id, source: .workingTree)
    var document = DiffDocument(file: file, loadState: .loaded, generation: 1)
    document.hunks = [hunk0, hunk1, hunk2]
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = gitLocalWorktree()
    initialState.files = [file]
    initialState.openDiffs = [key: document]
    initialState.diffLoadToken = 1
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.diff = { _, _, _, _, _ in
        diffCalls.withValue { $0 += 1 }
        return []
      }
    }
    store.exhaustivity = .off

    await store.send(.expandGap(key: key, gap: 1, step: .fine, direction: .up))
    await store.receive(\.gapSliceLoaded)
    await store.finish()

    // Gap B (GapKey 2) is untouched, and NO `DiffClient.diff` fired (no re-diff).
    #expect(store.state.openDiffs[key]?.expansion == .regions([1: HunkExpansionRegion(fromStart: 20)]))
    #expect(diffCalls.value == 0)
  }

  /// A two-hunk file whose inter-hunk gap is far larger than `maxEagerSliceLines`
  /// (500): hunk 0 covers new lines 1…3; hunk 1 starts at new line 800 — the gap is
  /// new lines 4…799 (796 lines). Whole-file / large expands eager-slice only the
  /// first 500; the rest must window in on scroll.
  private func bigGapTwoHunkFile() -> (FileChange, [DiffHunk]) {
    let file = makeFile("big.swift")
    let hunk0 = DiffHunk(
      oldStart: 1, oldCount: 3, newStart: 1, newCount: 3, header: "@@ -1,3 +1,3 @@",
      lines: [
        DiffLine(origin: .context, oldLineNumber: 1, newLineNumber: 1, content: "a", noNewlineAtEof: false),
        DiffLine(origin: .deletion, oldLineNumber: 2, newLineNumber: nil, content: "b-old", noNewlineAtEof: false),
        DiffLine(origin: .addition, oldLineNumber: nil, newLineNumber: 2, content: "b-new", noNewlineAtEof: false),
        DiffLine(origin: .context, oldLineNumber: 3, newLineNumber: 3, content: "c", noNewlineAtEof: false),
      ])
    let hunk1 = DiffHunk(
      oldStart: 800, oldCount: 1, newStart: 800, newCount: 1, header: "@@ -800,1 +800,1 @@",
      lines: [
        DiffLine(origin: .context, oldLineNumber: 800, newLineNumber: 800, content: "tail", noNewlineAtEof: false)
      ])
    return (file, [hunk0, hunk1])
  }

  /// Finding #11 (F69 tail): a `.whole` expand of a >500-line gap eager-slices only the
  /// first `maxEagerSliceLines`; scrolling the viewport into the un-sliced region must
  /// lazily window in the rest. A `.visibleRangeChanged` whose new-side window
  /// falls beyond the eager slice fires ONE slice for exactly the missing sub-range; a
  /// re-scroll over already-revealed lines fires none (dedup). Drives a single bounded
  /// gap (not `.diffExpandWholeFile`) so the trailing EOF-unbounded gap's own eager
  /// slice doesn't muddy the counts — the windowing wiring under test is per-gap and
  /// identical on both paths.
  @Test(.dependencies) func scrollingIntoUnslicedExpandedRegionWindowsInTheRest() async {
    let (file, hunks) = bigGapTwoHunkFile()
    let key = DiffDocumentKey(path: file.id, source: .workingTree)
    let sliceCalls = LockIsolated(0)
    var document = DiffDocument(file: file, loadState: .loaded, generation: 1)
    document.hunks = hunks
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = gitLocalWorktree()
    initialState.files = [file]
    initialState.openDiffs = [key: document]
    initialState.diffLoadToken = 1
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.blobSliceClient.slice = { _, _, _, range, delta in
        sliceCalls.withValue { $0 += 1 }
        return range.map {
          DiffLine(
            origin: .context, oldLineNumber: $0 + delta, newLineNumber: $0,
            content: "context line \($0)", noNewlineAtEof: false)
        }
      }
    }
    store.exhaustivity = .off

    // Expand gap 1 whole (796 lines): the eager slice is capped at 500 (new 4…503);
    // 504…799 stay un-sliced. Exactly one slice fires.
    await store.send(.expandGap(key: key, gap: 1, step: .whole, direction: .both))
    await store.receive(\.gapSliceLoaded)
    #expect(store.state.openDiffs[key]?.revealed[1]?.count == 500)
    #expect(store.state.openDiffs[key]?.revealed[1]?.contains { $0.newLineNumber == 700 } == false)
    #expect(sliceCalls.value == 1)

    // Scroll into the un-sliced region (new 700…749): one windowing slice fires for
    // exactly the missing sub-range and lands in `revealed`.
    await store.send(
      .visibleRangeChanged(key: key, window: VisibleLineWindow(old: 700..<750, new: 700..<750)))
    await store.receive(\.gapSliceLoaded)
    #expect(sliceCalls.value == 2)
    #expect(store.state.openDiffs[key]?.revealed[1]?.contains { $0.newLineNumber == 700 } == true)
    #expect(store.state.openDiffs[key]?.revealed[1]?.contains { $0.newLineNumber == 749 } == true)

    // Re-scrolling over an ALREADY-revealed window (new 4…49, inside the eager slice)
    // fires NO further slice — the dedup against `revealed[gap]` holds.
    await store.send(
      .visibleRangeChanged(key: key, window: VisibleLineWindow(old: 4..<50, new: 4..<50)))
    #expect(sliceCalls.value == 2)
    await store.finish()
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

  /// The batch-loss race (RP5): the pre-gate said YES up front, so `.sendBatchToAgent`
  /// optimistically emits `.sendBatchFinished(.sent)` (clearing the comments) and
  /// relies on a same-tick `TerminalClient.Event.textInjectionFailed` — routed by
  /// `AppFeature` to `.sendBatchFinished(.noTerminal)` — to override the failure. The
  /// send never landed; the override MUST re-surface the alert so the batch does not
  /// vanish silently ("send did nothing but my comments are gone" with no signal).
  @Test(.dependencies) func sendBatchThenTextInjectionFailedRestoresAlert() async {
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
      $0.terminalClient.hasAgentTerminalSurface = { _ in true }  // gate says YES up front
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    }

    // Gate passes → optimistic `.sent` clears comments and unlocks the batch.
    await store.send(.sendBatchToAgent) {
      $0.batchLocked = true
    }
    await store.receive(.sendBatchFinished(.sent)) {
      $0.comments.removeAll()
      $0.batchLocked = false
    }
    #expect(store.state.comments.isEmpty)

    // Same-tick failure event overrides to `.noTerminal`: the send never landed, so
    // the user must be told (alert restored), not left with a silently-cleared batch.
    await store.send(.sendBatchFinished(.noTerminal)) {
      $0.alert = .noAgentTerminal
    }
    #expect(store.state.alert == .noAgentTerminal)
    #expect(store.state.batchLocked == false)
    await store.finish()
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
    await store.send(.diffLoaded(key: key, hunks: [hunk], old: nil, new: nil, token: 5))
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

  // MARK: - two-section inspector visibility (Phase 3 view-facing state)

  @Test(.dependencies) func baseSectionHiddenWhenNoBaseResolved() {
    var state = DiffReviewFeature.State()
    state.selectedWorktree = gitLocalWorktree()
    state.files = [makeFile("a.swift")]
    state.baseRef = nil
    // No base ref ⇒ the "vs <base>" section is hidden entirely (no header).
    #expect(state.baseSectionTitle == nil)
    #expect(state.supportsBaseDiff == false)
  }

  @Test(.dependencies) func baseSectionTitleStripsOriginPrefix() {
    var state = DiffReviewFeature.State()
    state.selectedWorktree = gitLocalWorktree()
    state.baseRef = "origin/main"
    // The header strips a leading `origin/` for display.
    #expect(state.baseSectionTitle == "vs main")
    state.baseRef = "feature/x"
    #expect(state.baseSectionTitle == "vs feature/x")
  }

  @Test(.dependencies) func baseSectionHiddenForUnsupportedWorktree() {
    var state = DiffReviewFeature.State()
    state.selectedWorktree = folderWorktree()
    state.baseRef = "main"
    // Folder/remote worktrees never show the base section even if a stale
    // `baseRef` lingers (supportsDiffReview is false).
    #expect(state.baseSectionTitle == nil)
  }

  @Test(.dependencies) func baseUpToDateIsEmptyStateNotError() {
    var state = DiffReviewFeature.State()
    state.selectedWorktree = gitLocalWorktree()
    state.baseRef = "main"
    state.baseFiles = []
    state.baseLoadState = .empty
    // Branch up to date with base ⇒ section present, empty (never an error).
    #expect(state.baseSectionTitle == "vs main")
    #expect(state.baseFiles.isEmpty)
    if case .error = state.baseLoadState { Issue.record("up-to-date must not be an error state") }
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
    await store.finish()  // drain the fire-and-forget persist effect (empty set)
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

  // MARK: - confirm-on-switch (3.4) — a worktree change with an unsent batch confirms first

  @Test(.dependencies) func switchingWorktreeWithUnsentCommentsConfirmsBeforeClearing() async {
    let comment = reviewComment()
    let current = gitLocalWorktree()
    let next = folderWorktree()  // folder target keeps the re-dispatched switch effect trivial
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = current
    initialState.comments = [comment]
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }

    // Switching parks the pending selection + presents the dialog; the batch is NOT cleared
    // and the current worktree stays selected until the user decides.
    await store.send(.worktreeSelected(next, prBaseRefName: nil)) {
      $0.pendingWorktreeSelection = .init(worktree: next, prBaseRefName: nil)
      $0.discardConfirm = DiffReviewFeature.discardConfirmDialog(count: 1)
    }
    #expect(store.state.comments == [comment])
    #expect(store.state.selectedWorktree == current)

    // Discard → clear the batch, drop the park, and re-dispatch the parked switch, which now
    // proceeds (empty batch) into the normal (folder) load path.
    await store.send(.discardConfirm(.presented(.discard))) {
      $0.discardConfirm = nil
      $0.comments.removeAll()
      $0.pendingWorktreeSelection = nil
    }
    await store.receive(.worktreeSelected(next, prBaseRefName: nil)) {
      $0.generation = 1
      $0.baseGeneration = 1
      $0.selectedWorktree = next
      $0.loadState = .unsupported(.folder)
    }
    await store.finish()  // drain the fire-and-forget persist effect (empty set)
  }

  // MARK: - comment-thread collapse toggle (F23)

  @Test(.dependencies) func toggleCommentThreadCollapsedFlipsMembership() async {
    let anchor = UUID()
    let store = TestStore(initialState: DiffReviewFeature.State()) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }

    await store.send(.toggleCommentThreadCollapsed(anchorID: anchor)) {
      $0.collapsedCommentThreads.insert(anchor)
    }
    await store.send(.toggleCommentThreadCollapsed(anchorID: anchor)) {
      $0.collapsedCommentThreads.remove(anchor)
    }
  }
}
