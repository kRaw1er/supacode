import ComposableArchitecture
import Foundation
import SupacodeSettingsShared

struct WorktreeInfoWatcherClient {
  var send: @MainActor @Sendable (Command) -> Void
  var events: @MainActor @Sendable () -> AsyncStream<Event>

  enum Command: Equatable {
    case setWorktrees([Worktree])
    case setSelectedWorktreeID(Worktree.ID?)
    case setPullRequestTrackingEnabled(Bool)
    case stop
  }

  enum Event: Equatable {
    case branchChanged(worktreeID: Worktree.ID)
    case filesChanged(worktreeID: Worktree.ID)
    case repositoryPullRequestRefresh(repositoryRootURL: URL, worktreeIDs: [Worktree.ID])
  }
}

extension WorktreeInfoWatcherClient: DependencyKey {
  /// The UNCONFIGURED placeholder — the real client closes over the live watcher
  /// manager and is injected at store construction. Reaching it means a dependency
  /// was resolved outside that scope (typically an escaped TCA effect re-resolving
  /// after its context fell back to `.live`), so it DEGRADES rather than trapping:
  /// a `fatalError` here kills the app-hosted test bundle mid-run. Same rationale as
  /// `TerminalClient.liveValue`.
  static let liveValue = WorktreeInfoWatcherClient(
    send: { _ in logger.error("send called on the unconfigured live client — ignoring") },
    events: {
      logger.error("events called on the unconfigured live client — returning an empty stream")
      return AsyncStream { $0.finish() }
    }
  )

  private static let logger = SupaLogger("WorktreeInfoWatcherClient")

  static let testValue = WorktreeInfoWatcherClient(
    send: { _ in },
    events: { AsyncStream { $0.finish() } }
  )
}

extension DependencyValues {
  var worktreeInfoWatcher: WorktreeInfoWatcherClient {
    get { self[WorktreeInfoWatcherClient.self] }
    set { self[WorktreeInfoWatcherClient.self] = newValue }
  }
}
