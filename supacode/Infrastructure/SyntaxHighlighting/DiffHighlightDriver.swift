import Foundation

/// The diff-indirection driver: selects the **correct blob per side** for a
/// `FileDiffBatch`, fixing bug #1 (the old path always read the on-disk working-tree
/// file — `DiffViewerRepresentable.swift:129-133` — which broke base/three-dot,
/// deleted, and renamed files). The batch already carries the blob the libgit2 layer
/// decoded for the *selected* `DiffSource` (Phase 9): `.workingTree` → HEAD blob on
/// the old side (workdir on the new side, not decoded → `nil`); `.baseBranch` → the
/// three-dot merge-base blob on the old side and the branch-tip blob on the new side.
///
/// Both sides are returned (fixes bug #2 — the old path highlighted only the new
/// side and forced the old side `[]`, `DiffCellView.swift:407`). A deleted file has
/// no new blob (old highlighted, new empty); an added file has no old blob
/// (vice-versa); a rename that changes language keys each side on its OWN path so the
/// grammar resolves per side. `nonisolated` + pure so it is unit-testable and rides
/// into `@Sendable` closures.
nonisolated enum DiffHighlightDriver {
  /// The `(old, new)` blob inputs for a file diff — `nil` on a side whose blob is
  /// absent (added / deleted / working-tree new side) or byte-capped / non-UTF-8
  /// (the streaming layer already dropped its `[UInt16]`).
  static func blobInputs(for batch: FileDiffBatch) -> (old: HighlightBlobInput?, new: HighlightBlobInput?) {
    let oldPath = batch.file.oldPath ?? batch.file.newPath
    let newPath = batch.file.newPath ?? batch.file.oldPath

    var old: HighlightBlobInput?
    if let oid = batch.oldBlobID, let utf16 = batch.oldBlobUTF16, let path = oldPath {
      old = HighlightBlobInput(blobOID: oid, utf16: utf16, path: path)
    }

    var new: HighlightBlobInput?
    if let oid = batch.newBlobID, let utf16 = batch.newBlobUTF16, let path = newPath {
      new = HighlightBlobInput(blobOID: oid, utf16: utf16, path: path)
    }

    return (old, new)
  }
}
