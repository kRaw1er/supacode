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

  func changedFiles(at worktreeURL: URL) async throws -> WorktreeDiff {
    try await ensureIndexUnlocked(worktreeURL)
    return try Libgit2Diff.changedFiles(at: worktreeURL, caps: caps)
  }

  func diff(for file: FileChange, at worktreeURL: URL) async throws -> [DiffHunk] {
    try await ensureIndexUnlocked(worktreeURL)
    return try Libgit2Diff.hunks(for: file, at: worktreeURL, caps: caps)
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
