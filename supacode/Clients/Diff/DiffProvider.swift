import Foundation

/// A `Sendable` source of the uncommitted worktree diff. The live
/// implementation confines all libgit2 access to a single background actor;
/// only the `Sendable` models above cross the boundary.
nonisolated protocol DiffProvider: Sendable {
  /// Cheap two-tier list: delta enumeration + per-file `line_stats`. Fills
  /// `status` / `addedLines` / `removedLines` / `isBinary` /
  /// `isLargeFileCapped` / `similarity` without walking every line.
  ///
  /// - Throws: `DiffError.indexLocked` when `<gitdir>/index.lock` exists (the
  ///   caller keeps its last-good diff), `DiffError.notARepository`, or
  ///   `DiffError.libgit2` on a libgit2 failure.
  func changedFiles(at worktreeURL: URL) async throws -> WorktreeDiff

  /// The full hunks/lines for one file, fetched on demand (typically on click).
  /// Empty when the file is binary or large-file-capped.
  func diff(for file: FileChange, at worktreeURL: URL) async throws -> [DiffHunk]
}
