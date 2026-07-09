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
  /// `ignoreWhitespace` maps to libgit2's `GIT_DIFF_IGNORE_WHITESPACE`: a
  /// whitespace-only change drops out of the hunks entirely (the header toggle
  /// re-diffs the open document through this flag).
  func diff(
    for file: FileChange, at worktreeURL: URL, contextLines: UInt32, source: DiffSource, ignoreWhitespace: Bool
  ) async throws -> [DiffHunk]

  /// Streams the whole `source` diff as frozen, generation-stamped
  /// `FileDiffBatch`es: `.started(fileCount:)` first (a coarse scaffold), then
  /// one `.fileReady` per delta IN ORDER, then `.finished`. The whole libgit2
  /// walk runs on the actor's serial executor (satisfying `GIT_THREADS=1`),
  /// decoupled from the `@MainActor` consumer by the continuation buffer. The
  /// caller's `generation` is stamped onto every batch so a stale one is dropped
  /// on arrival; consumer teardown cancels the walk at the next file boundary.
  /// Errors (`.indexLocked` / `.notARepository` / `.baseRefUnresolved` /
  /// `.libgit2`) surface via the stream's throw.
  func stream(
    source: DiffSource, at worktreeURL: URL, contextLines: UInt32, generation: Int, ignoreWhitespace: Bool
  ) -> AsyncThrowingStream<DiffStreamEvent, Error>
}
