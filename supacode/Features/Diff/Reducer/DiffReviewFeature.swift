import ComposableArchitecture
import Foundation
import Sharing

/// Canonical (owned by Phase 2). Unified vs split viewer preference. Phase 3 consumes this exact
/// type + key — it must NOT define a parallel `DiffMode` / `"diffMode"`.
enum DiffViewMode: String, Codable, Sendable, Equatable, CaseIterable { case unified, split }

@Reducer
struct DiffReviewFeature {
  @ObservableState
  struct State: Equatable {
    /// The worktree whose changes are shown, or nil when nothing is selected.
    var selectedWorktree: Worktree?
    /// Last successfully loaded file list. Kept across an `.indexLocked` refresh
    /// (last-good) so the panel never flashes empty on a transient lock.
    var files: [FileChange] = []
    var loadState: LoadState = .idle
    /// Monotonic request token. Bumped on every (re)selection and load; a returning
    /// `.loaded/.failed` whose `generation` no longer matches is discarded (8.1).
    var generation: Int = 0
    /// Unified vs split viewer preference (consumed in Phase 3; declared here so the
    /// panel owns the pref). Global.
    @Shared(.appStorage("diffViewMode")) var diffViewMode: DiffViewMode = .unified

    enum LoadState: Equatable {
      case idle  // no selection (1.1)
      case loading  // in-flight, no prior list to show
      case loaded  // files.isEmpty == false
      case empty  // git worktree, zero changes (1.6)
      case refreshing  // index.lock: keep `files`, show subtle "updating…" (1.7)
      case error(DiffError)  // other libgit2 failure
      case unsupported(Unsupported)  // folder / remote (1.4 / 1.5)
    }
    enum Unsupported: Equatable {
      case folder  // "Not a git repository"
      case remote  // "Diff review isn't available for remote worktrees yet"
    }

    /// The toolbar toggle is hidden when the panel can't apply to this worktree.
    var supportsDiffReview: Bool {
      guard let worktree = selectedWorktree else { return false }
      return !worktree.isFolder && worktree.host == nil
    }
  }

  enum Action: Equatable {
    case worktreeSelected(Worktree?)  // fan-out from AppFeature :313
    case load  // (re)issue a changedFiles request
    case loaded([FileChange], generation: Int)  // client success
    case failed(DiffError, generation: Int)  // client failure
    case filesChanged(Worktree.ID)  // raw info-event tick (pre-debounce)
    case refreshTick  // post-debounce: re-load
    case openFile(path: String)  // row tap → open center diff tab
  }

  private nonisolated enum CancelID: Hashable, Sendable { case load, debounce }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      @Dependency(DiffClient.self) var diffClient
      @Dependency(TerminalClient.self) var terminalClient
      @Dependency(\.continuousClock) var clock
      switch action {

      case .worktreeSelected(let worktree):
        // Any selection change invalidates in-flight results (8.1) and cancels
        // both the load and a pending debounce.
        state.generation &+= 1
        state.selectedWorktree = worktree
        guard let worktree else {
          state.files = []
          state.loadState = .idle
          return .merge(.cancel(id: CancelID.load), .cancel(id: CancelID.debounce))
        }
        // Gate BEFORE touching the client: never call libgit2 for folder/remote (1.4/1.5).
        if worktree.isFolder {
          state.files = []
          state.loadState = .unsupported(.folder)
          return .merge(.cancel(id: CancelID.load), .cancel(id: CancelID.debounce))
        }
        if worktree.host != nil {
          state.files = []
          state.loadState = .unsupported(.remote)
          return .merge(.cancel(id: CancelID.load), .cancel(id: CancelID.debounce))
        }
        state.files = []  // new worktree ⇒ drop the prior list
        state.loadState = .loading
        return Self.loadEffect(worktree: worktree, generation: state.generation, diffClient: diffClient)

      case .load:
        guard let worktree = state.selectedWorktree,
          !worktree.isFolder, worktree.host == nil
        else { return .none }
        state.generation &+= 1
        // Keep `files` on a re-load so live refresh doesn't flash empty; the row
        // list swaps atomically on `.loaded`.
        if state.files.isEmpty { state.loadState = .loading }
        return Self.loadEffect(worktree: worktree, generation: state.generation, diffClient: diffClient)

      case .loaded(let files, let generation):
        guard generation == state.generation else { return .none }  // discard stale (8.1)
        state.files = files
        state.loadState = files.isEmpty ? .empty : .loaded
        return .none

      case .failed(let error, let generation):
        guard generation == state.generation else { return .none }  // discard stale (8.1)
        switch error {
        case .indexLocked:
          // Keep the last-good list; show "updating…" instead of clearing (1.7).
          state.loadState = state.files.isEmpty ? .loading : .refreshing
        default:
          state.loadState = .error(error)
        }
        return .none

      case .filesChanged(let worktreeID):
        // Only the currently selected, supported worktree drives a refresh.
        guard let worktree = state.selectedWorktree, worktree.id == worktreeID,
          !worktree.isFolder, worktree.host == nil
        else { return .none }
        // Coalesce a burst of agent edits into one reload (4.4). cancelInFlight
        // restarts the 250ms window on each new tick.
        return .run { send in
          try await clock.sleep(for: .milliseconds(250))
          await send(.refreshTick)
        }
        .cancellable(id: CancelID.debounce, cancelInFlight: true)

      case .refreshTick:
        return .send(.load)

      case .openFile(let path):
        guard let worktree = state.selectedWorktree else { return .none }
        // Reducer can't touch the @Observable manager directly; go through the
        // TerminalClient command path (mirrors every other terminal reach-out).
        return .run { _ in
          await terminalClient.send(.openDiffTab(worktree, filePath: path))
        }
      }
    }
  }

  /// Tags the request with `generation`; the return is checked against the live
  /// generation in `.loaded/.failed`, so a late result after a selection change
  /// is dropped. `static` so the `@Sendable` `Reduce` closure can call it under
  /// the module's default main-actor isolation (mirrors the feature's peers).
  private static func loadEffect(
    worktree: Worktree,
    generation: Int,
    diffClient: DiffClient
  ) -> Effect<Action> {
    .run { send in
      do {
        // Phase 1 returns `WorktreeDiff`; the row list consumes `.files`.
        let diff = try await diffClient.changedFiles(worktree.workingDirectory)
        await send(.loaded(diff.files, generation: generation))
      } catch let error as DiffError {
        await send(.failed(error, generation: generation))
      } catch {
        await send(.failed(.libgit2(code: -1, message: "\(error)"), generation: generation))
      }
    }
    .cancellable(id: CancelID.load, cancelInFlight: true)
  }
}
