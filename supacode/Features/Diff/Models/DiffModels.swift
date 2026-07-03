import Foundation

/// The full uncommitted diff of a worktree (`git diff HEAD` + untracked),
/// materialized into `Sendable` value types. Produced by `DiffProvider`
/// entirely inside the confinement actor — no libgit2 pointer ever rides
/// along. Phases 2-6 consume these unchanged.
nonisolated struct WorktreeDiff: Sendable, Equatable {
  var files: [FileChange]
  /// `git init` with no commits yet — every file surfaces as an addition
  /// against the empty tree.
  var isUnbornHead: Bool
  /// Mid-operation repo state from `git_repository_state()`. Phase 6 renders
  /// the banner; produced here so the actor stays the single libgit2 owner.
  var operation: RepositoryOperation
}

/// One changed file in the uncommitted diff. `changedFiles` fills the cheap
/// metadata (status, counts, caps); the per-file hunks are fetched lazily via
/// `DiffProvider.diff(for:at:)`.
nonisolated struct FileChange: Sendable, Equatable, Identifiable {
  /// Stable across a re-diff by path — the new path wins, falling back to the
  /// old path for deletions.
  var id: String { newPath ?? oldPath ?? "" }
  /// `nil` when the file is added / untracked (no pre-image).
  var oldPath: String?
  /// `nil` when the file is deleted (no post-image).
  var newPath: String?
  var status: FileStatus
  var addedLines: Int
  var removedLines: Int
  var isBinary: Bool
  /// `> byteCap` or `> lineCap` → hunks omitted, counts best-effort.
  var isLargeFileCapped: Bool
  /// Any line longer than `longLineCap` — metadata for the Phase 4 renderer.
  var hasLongLines: Bool
  /// 0-100, meaningful for `.renamed` / `.copied`.
  var similarity: Int
}

/// A single hunk of a file diff — the `@@ … @@` header plus its lines.
nonisolated struct DiffHunk: Sendable, Equatable {
  var oldStart: Int
  var oldCount: Int
  var newStart: Int
  var newCount: Int
  /// The raw `"@@ -a,b +c,d @@ …"` header line.
  var header: String
  var lines: [DiffLine]
}

/// A single line inside a hunk, carrying both line numbers so a two-pane
/// renderer can align old and new without re-deriving them.
nonisolated struct DiffLine: Sendable, Equatable {
  var origin: DiffLineOrigin
  /// `nil` for additions (libgit2 reports `-1`).
  var oldLineNumber: Int?
  /// `nil` for deletions (libgit2 reports `-1`).
  var newLineNumber: Int?
  /// The line content without its trailing newline — exactly `content_len`
  /// bytes decoded as UTF-8.
  var content: String
  /// From the `'='` / `'>'` / `'<'` EOFNL origins.
  var noNewlineAtEof: Bool
}

/// The file's change classification. `.modeChanged` is a permission/type
/// change with no content lines; `.binary` files never carry hunks.
nonisolated enum FileStatus: Sendable, Equatable {
  case added
  case modified
  case deleted
  case renamed
  case copied
  case modeChanged
  case binary
  case submodule
  case conflicted
  case untracked
}

/// The role of a diff line. `noNewlineMarker` is retained for completeness;
/// the "no newline at EOF" fact is also surfaced on `DiffLine.noNewlineAtEof`
/// of the affected content line.
nonisolated enum DiffLineOrigin: Sendable, Equatable {
  case context
  case addition
  case deletion
  case noNewlineMarker
}

/// Mid-operation repo state from `git_repository_state()` (Phase 6 renders the
/// banner; produced here).
nonisolated enum RepositoryOperation: Sendable, Equatable {
  case none
  case merge
  case rebase
  case rebaseInteractive
  case rebaseMerge
  case cherryPick
  case revert
  case bisect
  case applyMailbox
}

/// Typed error surface for the diff data layer. `.indexLocked` is the
/// load-bearing case — callers keep their last-good diff rather than showing a
/// garbage/empty one while an agent is mid-commit.
nonisolated enum DiffError: Error, Equatable, Sendable {
  case indexLocked
  case notARepository
  case libgit2(code: Int32, message: String)
}
