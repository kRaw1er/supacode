import ComposableArchitecture
import Foundation

/// TCA dependency for the diff data layer, mirroring `GitClientDependency`: a
/// struct of `@Sendable` closures whose `liveValue` wraps the shared
/// `LibGit2DiffProvider` actor. Reducers read it via `@Dependency(\.diffClient)`.
///
/// The client is intentionally stateless — there is no generation token. Stale
/// results are the reducer's concern (Phase 2): each selection change starts a
/// fresh `.cancellable(id:, cancelInFlight: true)` effect keyed by the selected
/// worktree/file id, so a late result is discarded because its effect was
/// cancelled. Baking a token into this C-facing API would only duplicate that.
struct DiffClient: Sendable {
  /// Cheap changed-file list (status + counts + caps) for one worktree.
  var changedFiles: @Sendable (_ worktreeURL: URL) async throws -> WorktreeDiff
  /// Full hunks/lines for one file, on demand. Empty when binary / capped.
  var diff: @Sendable (_ file: FileChange, _ worktreeURL: URL) async throws -> [DiffHunk]
}

extension DiffClient: DependencyKey {
  static let liveValue: DiffClient = {
    // One shared actor for the whole app: it serializes every diff op so
    // libgit2 (`GIT_THREADS=1`) stays single-threaded per repo.
    let provider = LibGit2DiffProvider()
    return DiffClient(
      changedFiles: { try await provider.changedFiles(at: $0) },
      diff: { try await provider.diff(for: $0, at: $1) }
    )
  }()

  /// Realistic no-op default (matching `GitClientDependency.testValue`): an
  /// empty diff. Tests that need real data override the closures with
  /// fixture-backed stubs; `DiffClientTests` exercises the actor directly.
  static var testValue: DiffClient {
    DiffClient(
      changedFiles: { _ in WorktreeDiff(files: [], isUnbornHead: false, operation: .none) },
      diff: { _, _ in [] }
    )
  }
}

extension DependencyValues {
  var diffClient: DiffClient {
    get { self[DiffClient.self] }
    set { self[DiffClient.self] = newValue }
  }
}
