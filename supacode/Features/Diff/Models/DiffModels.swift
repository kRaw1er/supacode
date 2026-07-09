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
  /// Submodule (gitlink) commit SHAs on the old / new side. Populated ONLY for a
  /// `.submodule` change (the delta's gitlink OIDs) so the `.submodule` placeholder
  /// renders the concrete "Subproject commit <old> → <new>" pointer change; `nil`
  /// for every non-submodule file.
  var oldSubmoduleSHA: String?
  var newSubmoduleSHA: String?
  /// Octal file modes (e.g. `"100644"` → `"100755"`) on the old / new side, from
  /// the git delta's `old_file.mode` / `new_file.mode`. Drive the `.modeChangeOnly`
  /// placeholder's concrete mode transition; `nil` when a side has no mode (`0`).
  var oldMode: String?
  var newMode: String?
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
nonisolated enum DiffLineOrigin: Sendable, Equatable, Hashable {
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

  /// Short human-facing label for the in-progress operation, or `nil` when the
  /// repository is in its normal state. Drives the Phase 6 mid-operation banner.
  var inProgressLabel: String? {
    switch self {
    case .none: nil
    case .merge: "Merge"
    case .rebase, .rebaseInteractive, .rebaseMerge: "Rebase"
    case .cherryPick: "Cherry-pick"
    case .revert: "Revert"
    case .bisect: "Bisect"
    case .applyMailbox: "Mailbox apply"
    }
  }

  /// Full banner sentence shown in the inspector + diff-tab headers, or `nil` in
  /// the normal state. Explains that the diff reflects the working tree mid-op.
  var bannerMessage: String? {
    guard let label = inProgressLabel else { return nil }
    return "\(label) in progress — diffs reflect the working tree mid-\(label.lowercased())."
  }
}

/// Typed error surface for the diff data layer. `.indexLocked` is the
/// load-bearing case — callers keep their last-good diff rather than showing a
/// garbage/empty one while an agent is mid-commit.
nonisolated enum DiffError: Error, Equatable, Sendable {
  case indexLocked
  case notARepository
  case libgit2(code: Int32, message: String)
  /// The `.baseBranch` ref did not resolve to any git object (no candidate
  /// revparse succeeded). Not an error the user should see — the reducer treats
  /// it as "hide the base-branch section" rather than surfacing a failure.
  case baseRefUnresolved
}

/// A whole-file placeholder shown in place of a line list when there is no
/// textual diff to render (binary / mode / deleted / submodule / empty), plus the
/// two edge-diff kinds routed to a dedicated widget: an image compare and a merge
/// conflict. `nonisolated` so it embeds in the pure (off-main) chunk-tree value
/// types alongside `DiffLineOrigin` / `FileStatus`. (Relocated from the deleted
/// `DiffRow.swift` in the Phase-13 seam swap — the ChunkTree `WidgetPayload`
/// carries it.)
nonisolated enum FilePlaceholder: Hashable, Sendable {
  case binaryFile
  case deletedFile
  case addedEmpty
  case noChanges
  case modeChangeOnly(oldMode: String, newMode: String)
  case submodule(oldSHA: String, newSHA: String)
  /// A binary file whose path carries an image extension — routed to the
  /// `ImageCompareWidget` (before/after compare; blob-bytes read is a gated
  /// follow-up, ⚠️ note 1, so it renders the binary summary in the interim).
  case imageCompare
  /// A file with merge-conflict markers — routed to the `ConflictWidget`
  /// (line-type tint + accept-ours/theirs, gated on straddling hunks).
  case conflict
}
