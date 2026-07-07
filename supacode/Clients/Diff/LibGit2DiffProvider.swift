import Foundation

/// The single confinement actor for all libgit2 access. It serializes every
/// diff operation (satisfying libgit2's per-repo single-thread requirement,
/// since the C library is built `GIT_THREADS=1`) and never lets a raw handle
/// escape: the `Libgit2Diff` binding opens the repo, diffs, and frees every C
/// object inside one synchronous call, returning only the `Sendable` models.
///
/// Handle lifetime is one repo-open per operation (open → diff → find_similar →
/// enumerate/patch → free-all) rather than a cached per-repo handle: a cached
/// `OpaquePointer` would be non-`Sendable` actor state that has to survive
/// suspension points and stay valid while the workdir mutates under it. One
/// open per op sidesteps the staleness and the lock/HEAD race entirely.
actor LibGit2DiffProvider: DiffProvider {
  /// > 2 MB → `isLargeFileCapped` (a generated lockfile hits this).
  static let byteCap = 2 * 1024 * 1024
  /// Hunks omitted above this line count.
  static let lineCap = 50_000
  /// Per-line metadata threshold for the Phase 4 renderer.
  static let longLineCap = 2_000

  init() {
    Libgit2Diff.initialize()
  }

  private var caps: Libgit2Diff.Caps {
    Libgit2Diff.Caps(byteCap: Self.byteCap, lineCap: Self.lineCap, longLineCap: Self.longLineCap)
  }

  func changedFiles(source: DiffSource = .workingTree, at worktreeURL: URL) async throws -> WorktreeDiff {
    try await ensureIndexUnlocked(worktreeURL)
    switch source {
    case .workingTree:
      return try Libgit2Diff.changedFiles(at: worktreeURL, caps: caps)
    case .baseBranch(let ref):
      return try Libgit2Diff.baseChangedFiles(at: worktreeURL, baseRef: ref, caps: caps)
    }
  }

  func diff(
    for file: FileChange,
    at worktreeURL: URL,
    contextLines: UInt32 = 3,
    source: DiffSource = .workingTree
  ) async throws -> [DiffHunk] {
    try await ensureIndexUnlocked(worktreeURL)
    switch source {
    case .workingTree:
      return try Libgit2Diff.hunks(for: file, at: worktreeURL, caps: caps, contextLines: contextLines)
    case .baseBranch(let ref):
      return try Libgit2Diff.baseHunks(for: file, at: worktreeURL, baseRef: ref, caps: caps, contextLines: contextLines)
    }
  }

  /// The old + new highlight blob inputs for ONE file in the `source` diff. The
  /// on-demand `.diffLoaded` load fetches these alongside the hunks so the production
  /// path feeds the highlighter (the streaming path is gated off in production).
  func highlightBlobs(
    for file: FileChange, at worktreeURL: URL, source: DiffSource = .workingTree
  ) async throws -> (old: HighlightBlobInput?, new: HighlightBlobInput?) {
    try await ensureIndexUnlocked(worktreeURL)
    return try Libgit2Diff.fileHighlightBlobs(for: file, at: worktreeURL, source: source, caps: caps)
  }

  /// Streams the whole `source` diff as frozen, generation-stamped batches. The
  /// actor owns the walk: the whole libgit2 span runs on its serial executor
  /// (satisfying `GIT_THREADS=1`), decoupled from the MainActor consumer by the
  /// continuation buffer. `onTermination` cancels the walk at the next file
  /// boundary when the consumer tears down (pierre `controller.abort`).
  nonisolated func stream(
    source: DiffSource, at worktreeURL: URL, contextLines: UInt32, generation: Int
  ) -> AsyncThrowingStream<DiffStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          try await self.ensureIndexUnlocked(worktreeURL)  // actor hop BEFORE the walk (last-good guard)
          try await self.runStream(  // actor-isolated synchronous walk
            source: source, at: worktreeURL, contextLines: contextLines,
            generation: generation, continuation: continuation)
          continuation.finish()
        } catch {
          // .indexLocked / .notARepository / .baseRefUnresolved / .libgit2 surface here.
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }  // consumer teardown → cancel at next file boundary
    }
  }

  /// Actor-isolated, synchronous: no `await` inside, so the C handle never spans
  /// a suspension point. `Task.isCancelled` is polled at each file boundary by
  /// the walk; `continuation.yield` does not suspend, so the diff stays valid.
  private func runStream(
    source: DiffSource, at worktreeURL: URL, contextLines: UInt32,
    generation: Int, continuation: AsyncThrowingStream<DiffStreamEvent, Error>.Continuation
  ) throws {
    try Libgit2Diff.streamChangedFiles(
      at: worktreeURL,
      Libgit2Diff.WalkRequest(source: source, caps: caps, contextLines: contextLines, generation: generation),
      isCancelled: { Task.isCancelled }, emit: { continuation.yield($0) })
  }

  /// Replicates `GitClient.lineChanges`'s `.git/index.lock` guard verbatim —
  /// resolves the real git dir (linked worktrees + `--separate-git-dir`) via
  /// `GitWorktreeHeadResolver`, then throws `.indexLocked` if the lock exists so
  /// the caller keeps its last-good diff instead of a garbage/empty one while an
  /// agent is mid-commit.
  private func ensureIndexUnlocked(_ worktreeURL: URL) async throws {
    let headURL = await MainActor.run {
      GitWorktreeHeadResolver.headURL(for: worktreeURL, fileManager: .default)
    }
    guard let headURL else { return }
    let gitDirectory = headURL.deletingLastPathComponent()
    let lockURL = gitDirectory.appending(path: "index.lock")
    if FileManager.default.fileExists(atPath: lockURL.path(percentEncoded: false)) {
      throw DiffError.indexLocked
    }
  }
}
