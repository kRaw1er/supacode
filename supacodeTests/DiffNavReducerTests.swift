import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

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
