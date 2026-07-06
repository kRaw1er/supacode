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
  /// `source` selects the uncommitted working-tree diff or the base-branch
  /// (three-dot) diff.
  var changedFiles: @Sendable (_ source: DiffSource, _ worktreeURL: URL) async throws -> WorktreeDiff
  /// Full hunks/lines for one file, on demand. Empty when binary / capped.
  /// `contextLines` sets libgit2's `context_lines` (default 3); the viewer
  /// raises it to materialize an expanded inter-hunk gap. `source` selects the
  /// working-tree or base-branch diff.
  var diff:
    @Sendable (_ file: FileChange, _ worktreeURL: URL, _ contextLines: UInt32, _ source: DiffSource) async throws ->
      [DiffHunk]
  /// Streams the whole `source` diff as generation-stamped `FileDiffBatch`es for
  /// progressive render + incremental re-diff (Phase 9). The `generation` is the
  /// CALLER's — passed through and stamped onto every batch — so no token is
  /// baked into the C-facing API (the struct-of-closures shape stays).
  var stream:
    @Sendable (_ source: DiffSource, _ worktreeURL: URL, _ contextLines: UInt32, _ generation: Int) ->
      AsyncThrowingStream<DiffStreamEvent, Error>
}

extension DiffClient: DependencyKey {
  static let liveValue: DiffClient = {
    // One shared actor for the whole app: it serializes every diff op so
    // libgit2 (`GIT_THREADS=1`) stays single-threaded per repo.
    let provider = LibGit2DiffProvider()
    return DiffClient(
      changedFiles: { try await provider.changedFiles(source: $0, at: $1) },
      diff: { try await provider.diff(for: $0, at: $1, contextLines: $2, source: $3) },
      stream: { provider.stream(source: $0, at: $1, contextLines: $2, generation: $3) }
    )
  }()

  /// Realistic no-op default (matching `GitClientDependency.testValue`): an
  /// empty diff. Tests that need real data override the closures with
  /// fixture-backed stubs; `DiffClientTests` exercises the actor directly.
  static var testValue: DiffClient {
    DiffClient(
      changedFiles: { _, _ in WorktreeDiff(files: [], isUnbornHead: false, operation: .none) },
      diff: { _, _, _, _ in [] },
      // Empty stream by default; tests that exercise streaming override this
      // closure with a fixture-backed batch sequence.
      stream: { _, _, _, _ in AsyncThrowingStream { $0.finish() } }
    )
  }
}

extension DependencyValues {
  var diffClient: DiffClient {
    get { self[DiffClient.self] }
    set { self[DiffClient.self] = newValue }
  }
}
