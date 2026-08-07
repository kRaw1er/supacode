import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import supacode

/// Phase 10 reducer surface — scroll-spy (`.diffActiveFileChanged`), jump-to-file
/// (`.diffJumpToFile` / `.diffScrollTargetConsumed`), the help / find intents, and
/// the keyboard whole-file / context expand (declarative Phase-7 reuse). Each is a
/// pure state transition with no effect, so the assertions are exhaustive.
@MainActor
struct DiffNavReducerTests {
  private func makeFile(_ path: String, added: Int = 1, removed: Int = 0) -> FileChange {
    FileChange(
      oldPath: nil, newPath: path, status: .modified, addedLines: added, removedLines: removed,
      isBinary: false, isLargeFileCapped: false, hasLongLines: false, similarity: 0)
  }

  // MARK: - scroll-spy body → list

  @Test func activeFileChangedUpdatesActiveFileIDOnly() async {
    let store = TestStore(initialState: DiffReviewFeature.State()) { DiffReviewFeature() }
    // Display-only: only `activeFileID` changes — no structural / sidebar recompute
    // (this reducer is disjoint from the sidebar structure cache).
    await store.send(.diffActiveFileChanged("a.swift")) {
      $0.activeFileID = "a.swift"
    }
    await store.send(.diffActiveFileChanged("b.swift")) {
      $0.activeFileID = "b.swift"
    }
  }

  // MARK: - jump-to-file list → body (consume-once)

  @Test func jumpToFileSetsPendingTargetThenConsumed() async {
    let store = TestStore(initialState: DiffReviewFeature.State()) { DiffReviewFeature() }
    await store.send(.diffJumpToFile("a.swift")) {
      $0.pendingScrollTarget = .file("a.swift")
      $0.activeFileID = "a.swift"
    }
    // The viewport drains it once.
    await store.send(.diffScrollTargetConsumed) {
      $0.pendingScrollTarget = nil
    }
  }

  // MARK: - help + find intents

  @Test func helpTogglesAndFindRequests() async {
    let store = TestStore(initialState: DiffReviewFeature.State()) { DiffReviewFeature() }
    await store.send(.diffShowKeyboardHelp) { $0.keyboardHelpVisible = true }
    await store.send(.diffShowKeyboardHelp) { $0.keyboardHelpVisible = false }
    await store.send(.diffBeginFind) { $0.findRequested = true }
  }

  // MARK: - menu-driven nav intent (Diff menu → viewport, consume-once)

  /// The "Diff" `CommandMenu` items publish `FocusedAction`s that send `.diffMenuNav`;
  /// the reducer records a one-shot `pendingNavCommand` the viewport drains and clears
  /// via `.diffNavCommandConsumed`. Fails if the menu → viewport plumbing is reverted.
  @Test func menuNavSetsPendingCommandThenConsumed() async {
    let store = TestStore(initialState: DiffReviewFeature.State()) { DiffReviewFeature() }
    await store.send(.diffMenuNav(.nextChange)) { $0.pendingNavCommand = .nextChange }
    // The viewport forwarded it to `DiffKeyboardNav` → one-shot cleared.
    await store.send(.diffNavCommandConsumed) { $0.pendingNavCommand = nil }
    // Latest pick wins if a second lands before the drain.
    await store.send(.diffMenuNav(.prevFile)) { $0.pendingNavCommand = .prevFile }
    await store.send(.diffMenuNav(.nextFile)) { $0.pendingNavCommand = .nextFile }
    await store.send(.diffNavCommandConsumed) { $0.pendingNavCommand = nil }
  }

  // MARK: - keyboard whole-file expand (Phase-7 declarative reuse)

  @Test func expandWholeFileSetsExpansionFull() async {
    let key = DiffDocumentKey(path: "a.swift", source: .workingTree)
    let other = DiffDocumentKey(path: "b.swift", source: .workingTree)
    var state = DiffReviewFeature.State()
    state.openDiffs[key] = DiffDocument(file: makeFile("a.swift"))
    state.openDiffs[other] = DiffDocument(file: makeFile("b.swift"))
    let store = TestStore(initialState: state) { DiffReviewFeature() }

    await store.send(.diffExpandWholeFile(fileID: "a.swift")) {
      $0.openDiffs[key]?.expansion = .full
    }
    // Idempotent: a second whole-file expand of an already-full doc is a no-op.
    await store.send(.diffExpandWholeFile(fileID: "a.swift"))
  }

  // MARK: - keyboard context expand / collapse

  @Test func expandContextGrowsThenCollapses() async {
    let key = DiffDocumentKey(path: "a.swift", source: .workingTree)
    var state = DiffReviewFeature.State()
    state.openDiffs[key] = DiffDocument(file: makeFile("a.swift"))  // no hunks → gap 0 only
    let store = TestStore(initialState: state) { DiffReviewFeature() }

    // delta > 0 grows every gap by one fine (±20) step, both ends.
    await store.send(.diffExpandContext(fileID: "a.swift", delta: 1)) {
      $0.openDiffs[key]?.expansion = .regions([0: HunkExpansionRegion(fromStart: 20, fromEnd: 20)])
    }
    // delta < 0 re-hides back to the collapsed default.
    await store.send(.diffExpandContext(fileID: "a.swift", delta: -1)) {
      $0.openDiffs[key]?.expansion = .collapsed
    }
    // delta == 0 is a no-op.
    await store.send(.diffExpandContext(fileID: "a.swift", delta: 0))
  }
}

/// Deeplink guard around a surface-less diff tab. `.surface` and `.surfaceSplit` are
/// SEPARATE `Deeplink.WorktreeAction` cases that both route through
/// `validateSurface` (AppFeature). The existing `.surface` rejection lives in
/// `AppFeatureCommandPaletteTests`; this pins the promised `.surfaceSplit` sibling so a
/// future edit that guards only `.surface` can't let a split-surface deeplink mutate a
/// diff tab and slip past coverage.
@MainActor
struct DiffTabSurfaceSplitDeeplinkTests {
  private func makeWorktree(id: String, name: String, repoRoot: String) -> Worktree {
    Worktree(
      id: WorktreeID(id),
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: repoRoot)
    )
  }

  private func makeRepository(id: String, worktrees: [Worktree]) -> Repository {
    Repository(
      id: RepositoryID(id),
      rootURL: URL(fileURLWithPath: id),
      name: "repo",
      worktrees: IdentifiedArray(uniqueElements: worktrees)
    )
  }

  @Test(.dependencies) func surfaceSplitDeeplinkTargetingDiffTabIsRejected() async {
    // A `surfaceSplit` deeplink aimed at a surface-less diff tab must be rejected with a
    // clear "Not a terminal tab" alert and must not mutate any terminal surface.
    let worktree = makeWorktree(id: "/tmp/repo-diff/wt-1", name: "wt-1", repoRoot: "/tmp/repo-diff")
    let repository = makeRepository(id: "/tmp/repo-diff", worktrees: [worktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [repository]
    let sent = LockIsolated<[TerminalClient.Command]>([])
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositoriesState,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.tabExists = { _, _ in true }
      $0.terminalClient.isDiffTab = { _, _ in true }
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    }
    store.exhaustivity = .off

    let tabID = UUID()
    await store.send(
      .deeplink(
        .worktree(
          id: worktree.id,
          action: .surfaceSplit(
            tabID: tabID, surfaceID: UUID(), direction: .horizontal, input: nil, id: nil))))
    await store.finish()

    // No surface-mutating command reached the terminal (a benign worktree selection
    // may precede validation, but never a `.splitSurface`).
    #expect(
      sent.value.contains {
        if case .splitSurface = $0 { return true }
        return false
      } == false
    )
    #expect(store.state.alert != nil)
  }
}
