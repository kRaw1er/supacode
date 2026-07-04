import Foundation

/// A `Sendable` source of the uncommitted worktree diff. The live
/// implementation confines all libgit2 access to a single background actor;
/// only the `Sendable` models above cross the boundary.
nonisolated protocol DiffProvider: Sendable {
  /// Cheap two-tier list: delta enumeration + per-file `line_stats`. Fills
  /// `status` / `addedLines` / `removedLines` / `isBinary` /
  /// `isLargeFileCapped` / `similarity` without walking every line.
  ///
  /// - Parameter source: `.workingTree` for the uncommitted diff, or
  ///   `.baseBranch(ref:)` for the branch's committed changes vs its base
  ///   (three-dot merge-base semantics).
  /// - Throws: `DiffError.indexLocked` when `<gitdir>/index.lock` exists (the
  ///   caller keeps its last-good diff), `DiffError.notARepository`,
  ///   `DiffError.baseRefUnresolved` when a `.baseBranch` ref does not resolve,
  ///   or `DiffError.libgit2` on a libgit2 failure.
  func changedFiles(source: DiffSource, at worktreeURL: URL) async throws -> WorktreeDiff

  /// The full hunks/lines for one file, fetched on demand (typically on click).
  /// Empty when the file is binary or large-file-capped. `contextLines` maps to
  /// libgit2's `context_lines` (3 = git default); the viewer raises it to
  /// materialize an expanded gap. `source` selects the working-tree or
  /// base-branch diff (the latter throws `DiffError.baseRefUnresolved` when its
  /// ref does not resolve).
  func diff(for file: FileChange, at worktreeURL: URL, contextLines: UInt32, source: DiffSource) async throws
    -> [DiffHunk]
}
