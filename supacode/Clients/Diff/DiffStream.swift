import Foundation

/// One fully-materialized file diff, FROZEN for transport across the actor
/// boundary. Every field is a Swift value type (`Sendable`) — NO `NSString`,
/// NO libgit2 pointer. `[UInt16]` blobs carry UTF-16 code units so the Phase 4
/// highlighter can index without re-decoding (a value copy is safe to share;
/// `NSString` bridging is not). The `generation` travels WITH the data so a
/// stale batch is dropped on arrival (pierre `isCurrentRequest`,
/// `usePatchLoader.ts:225`).
nonisolated struct FileDiffBatch: Sendable, Equatable {
  /// status / counts / caps — reuses `Libgit2Diff.makeFileChange`.
  var file: FileChange
  /// Decoded lines — reuses `Libgit2Diff.walkPatch`.
  var hunks: [DiffHunk]
  /// Up-front row counts for BOTH modes (est height = count × lineHeight
  /// pre-measurement). Unified = Σ lines; split ≈ Σ_hunk max(oldCount, newCount)
  /// + shared context. The exact split count is `PairSequencer`'s (Phase 1); this
  /// is the coarse estimate the scaffold uses for a stable frame-1 scrollbar.
  var unifiedLineCount: Int
  var splitLineCount: Int
  /// Content-identity keys = blob OIDs (`git_diff_file.id` → `git_oid_tostr_s`).
  /// The OLD side is a fixed blob (highlighted ONCE, survives re-diff); the NEW
  /// side is a blob for tree / base diffs, `nil` (workdir) for the working-tree
  /// diff, or `nil` for a zero OID (add / delete side).
  var oldBlobID: String?
  var newBlobID: String?
  /// Full-side UTF-16 for the highlighter + gap expansion without a full-context
  /// re-diff. `nil` when a side is absent (add / delete), byte-capped, non-UTF-8,
  /// or on the working-tree new side (workdir). Bounded: the consumer extracts
  /// what it needs, then releases the batch per file.
  var oldBlobUTF16: [UInt16]?
  var newBlobUTF16: [UInt16]?
  /// The request generation this batch belongs to — dropped on arrival when it no
  /// longer matches the live generation (pierre `isCurrentRequest`).
  var generation: Int

  init(
    file: FileChange,
    hunks: [DiffHunk],
    unifiedLineCount: Int,
    splitLineCount: Int,
    oldBlobID: String?,
    newBlobID: String?,
    oldBlobUTF16: [UInt16]?,
    newBlobUTF16: [UInt16]?,
    generation: Int
  ) {
    self.file = file
    self.hunks = hunks
    self.unifiedLineCount = unifiedLineCount
    self.splitLineCount = splitLineCount
    self.oldBlobID = oldBlobID
    self.newBlobID = newBlobID
    self.oldBlobUTF16 = oldBlobUTF16
    self.newBlobUTF16 = newBlobUTF16
    self.generation = generation
  }

  /// The content-identity of this batch's two blob sides — the reconcile key. A
  /// re-diff whose batch has the same identity is byte-identical, so the consumer
  /// keeps the existing sub-tree (heights / CTLine / highlight survive).
  var identity: FileBlobIdentity {
    FileBlobIdentity(oldBlobID: oldBlobID, newBlobID: newBlobID)
  }
}

/// The `(oldBlobID, newBlobID)` content-identity of one file's diff. The OLD side
/// is a real blob for every diff kind (highlight the base once); the working-tree
/// NEW side is a zero OID (workdir), so reuse keys primarily on `oldBlobID`.
nonisolated struct FileBlobIdentity: Hashable, Sendable {
  var oldBlobID: String?
  var newBlobID: String?
}

/// Producer→consumer events. `.started` first (coarse scaffold), then `.fileReady`
/// per delta IN ORDER, then `.finished`. Errors surface via the stream's throw.
nonisolated enum DiffStreamEvent: Sendable, Equatable {
  case started(fileCount: Int, operation: RepositoryOperation, generation: Int)
  case fileReady(FileDiffBatch)
  case finished(generation: Int)
}
