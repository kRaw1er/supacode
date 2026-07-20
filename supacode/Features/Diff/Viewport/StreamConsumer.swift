import CoreGraphics
import Foundation

/// The `@MainActor`, zero-I/O consumer of a `DiffStreamEvent` stream. It owns a
/// `ChunkTree` (Phase 1) and drives a `DiffViewportController` (Phase 2): a coarse
/// scaffold on `.started` (stable scrollbar frame 1), then per-file reconcile by
/// **content identity** (blob OID) on each `.fileReady`. Stale generations are
/// dropped ON ARRIVAL — belt-and-suspenders with the reducer's `.cancellable`,
/// matching pierre re-checking `isCurrentRequest()` at every await, not just at
/// abort (`usePatchLoader.ts:225`). It does zero libgit2 / disk I/O.
///
/// Reconcile semantics (pierre `CodeView.reconcileItems` + `syncItemRecord`
/// version gate, ported to a blob-OID content key):
/// - **Unchanged** `(fileID, oldBlobID, newBlobID)` ⇒ keep the existing sub-tree
///   (heights / CTLine / highlight survive) — a no-op, NOT an O(n) row diff.
/// - **Changed** ⇒ splice ONLY that file's sub-tree in place (`fileNodeSpan` →
///   O(log n) `remove` per node → `insertChunks`), unchanged siblings untouched.
/// - **New** ⇒ append below the fold (grow the scaffold, no relayout) when off
///   screen, else an anchored splice.
@MainActor
final class DiffStreamConsumer {
  /// The live generation the producer stamps every batch with. A batch whose
  /// generation differs is dropped on arrival.
  private(set) var generation = 0

  /// The tree this consumer owns and hands to the viewport (same reference, so an
  /// in-place mutation is visible to the controller's next layout).
  let tree: ChunkTree

  private unowned let viewport: DiffViewportController
  private var mode: DiffViewMode = .unified

  /// Materialized files in document order + their last-consumed content identity
  /// and last-node anchor (the append point for the next file).
  private(set) var fileOrder: [FileID] = []
  private var identities: [FileID: FileBlobIdentity] = [:]
  private var lastNodeID: [FileID: ChunkID] = [:]
  /// Files re-seen in the current generation — the un-seen survivors are pruned
  /// on `.finished` (a file that vanished on a re-diff).
  private var seenThisGeneration: Set<FileID> = []

  /// The coarse tail placeholder reserving height for not-yet-materialized files
  /// (first load only). Shrinks as files arrive; removed on `.finished`.
  private var scaffoldID: ChunkID?
  private var pendingFileCount = 0

  /// Instrumentation the fixtures assert on: which reconcile branch each batch
  /// took (the "below-fold append is a fast path, not a full relayout" and
  /// "unchanged file is a reuse, not a splice" acceptance checks).
  private(set) var diagnostics = Diagnostics()

  nonisolated struct Diagnostics: Equatable, Sendable {
    /// Unchanged `(fileID, blobOID)` ⇒ no-op reuse.
    var reuses = 0
    /// Below-fold new file ⇒ grow the scaffold only (no anchor restore).
    var belowFoldAppends = 0
    /// Intersecting new file ⇒ anchored apply.
    var anchoredAppends = 0
    /// Changed file ⇒ in-place splice.
    var splices = 0
    /// Stale-generation batch dropped on arrival.
    var staleDrops = 0
  }

  /// Coarse per-file line guess for the frame-1 scaffold (refined per batch).
  static let coarseLinesPerFile = 8
  /// The scaffold placeholder's synthetic file id — never collides with a real
  /// path and never registers in `fileHeaderNodes`.
  static let scaffoldFileID: FileID = "\u{1}__diff-stream-scaffold__"

  init(viewport: DiffViewportController, metrics: ChunkLayoutMetrics = .production) {
    self.viewport = viewport
    self.tree = ChunkTree(metrics: metrics)
  }

  // MARK: - Estimate arithmetic (pierre `computeEstimatedDiffHeights.ts:81`)

  /// The up-front per-file height estimate from a mode's line count:
  /// `count × lineHeight + diffHeaderHeight + separators`. Both modes use the same
  /// shape; the caller passes `unifiedLineCount` / `splitLineCount`.
  static func estimatedFileHeight(lineCount: Int, metrics: ChunkLayoutMetrics = .production) -> CGFloat {
    CGFloat(lineCount) * metrics.lineHeight + metrics.diffHeaderHeight + metrics.separatorHeight
  }

  /// The coarse per-file reservation used before any batch's real counts arrive.
  static func coarseFileHeight(metrics: ChunkLayoutMetrics) -> CGFloat {
    estimatedFileHeight(lineCount: coarseLinesPerFile, metrics: metrics)
  }

  // MARK: - Stream lifecycle

  /// `.started`: adopt the request `generation` (so stale batches drop on arrival)
  /// and, on a FIRST load (empty tree), lay a single coarse tail placeholder of
  /// `fileCount × coarse` so the scrollbar frame is stable from frame 1 (pierre
  /// `setInitialItems` then streams). A re-diff keeps the existing tree so
  /// unchanged files' sub-trees — and their measured heights — survive.
  func begin(fileCount: Int, mode: DiffViewMode, generation: Int) {
    self.generation = generation
    self.mode = mode
    self.pendingFileCount = fileCount
    self.seenThisGeneration = []
    guard fileOrder.isEmpty else { return }  // re-diff: reconcile in place, no scaffold
    scaffoldID = nil
    if fileCount > 0 {
      let coarse = Self.coarseFileHeight(metrics: tree.metrics)
      let widget = Widget(
        key: .placeholder(fileID: Self.scaffoldFileID),
        estimatedHeight: CGFloat(fileCount) * coarse,
        payload: .placeholder(.noChanges)
      )
      scaffoldID = tree.insert(.widget(widget), after: nil)
    }
    viewport.apply(tree: tree, mode: mode, scrollPreserving: false)
  }

  /// Drain one batch. Generation-drop on arrival (pierre `isCurrentRequest`), then
  /// content-identity reuse (no-op on an unchanged file), else splice / append.
  func consume(_ batch: FileDiffBatch) {
    guard batch.generation == generation else {
      diagnostics.staleDrops += 1  // stale → drop on arrival, no work
      return
    }
    let fileID = batch.file.id
    seenThisGeneration.insert(fileID)

    // Content-identity reuse: same file + same blob OIDs ⇒ byte-identical ⇒ keep
    // the existing sub-tree (heights / CTLine / highlight survive). This is pierre's
    // `reconcileItems` reuse + `syncItemRecord` version gate, keyed on the
    // `(oldBlobID, newBlobID)` content identity rather than an item index.
    if let existing = identities[fileID], existing == batch.identity {
      diagnostics.reuses += 1
      return
    }

    let chunks = ChunkTreeBuilder.classify(
      file: batch.file, hunks: batch.hunks, expanded: [],
      options: ChunkTreeBuilder.Options(metrics: tree.metrics))

    if fileOrder.contains(fileID) {
      replaceFile(fileID: fileID, with: chunks)
    } else if batch.file.status == .renamed, let old = batch.file.oldPath,
      fileOrder.contains(old), !seenThisGeneration.contains(old)
    {
      // A rename re-keys a materialized file: reuse its header element under the
      // new id (pierre `updateItemId`) rather than dropping + recreating it.
      renameFile(from: old, to: fileID, chunks: chunks)
    } else {
      appendFile(fileID: fileID, chunks: chunks)
    }
    identities[fileID] = batch.identity
  }

  /// `.finished`: prune files that vanished this generation (a deleted/renamed-away
  /// file on a re-diff), drop the scaffold placeholder, and re-land the anchored
  /// scroll against the settled tree.
  func finish() {
    for fileID in fileOrder where !seenThisGeneration.contains(fileID) {
      removeFile(fileID)
    }
    if let scaffoldID {
      tree.remove(scaffoldID)
      self.scaffoldID = nil
    }
    viewport.apply(tree: tree, mode: mode, scrollPreserving: true)
  }

  /// Hard reset (worktree switch): drop everything and start from an empty tree.
  func reset() {
    for id in tree.inorderNodes().map(\.id) { tree.remove(id) }
    fileOrder.removeAll()
    identities.removeAll()
    lastNodeID.removeAll()
    seenThisGeneration.removeAll()
    scaffoldID = nil
    pendingFileCount = 0
    viewport.apply(tree: tree, mode: mode, scrollPreserving: false)
  }

  // MARK: - Reconcile primitives

  /// Append a brand-new file's chunks before the scaffold placeholder. Below-fold
  /// (`insertY > visibleMaxY + overscan`) grows the scaffold only (append tail, no
  /// relayout / no anchor restore); an intersecting insert re-lands the anchor.
  private func appendFile(fileID: FileID, chunks: [Chunk]) {
    let insertY = scaffoldID.flatMap { tree.nodeYOffset($0, mode: mode) } ?? tree.totalHeight(mode)
    let anchor = fileOrder.last.flatMap { lastNodeID[$0] }
    let last = tree.insertChunks(chunks, after: anchor)
    lastNodeID[fileID] = last
    fileOrder.append(fileID)
    shrinkScaffold()
    if insertY > viewport.visibleMaxY + DiffViewportController.overscan {
      diagnostics.belowFoldAppends += 1
      viewport.appendBelowFold()
    } else {
      diagnostics.anchoredAppends += 1
      viewport.apply(tree: tree, mode: mode, scrollPreserving: true)
    }
  }

  /// Re-key a renamed file's sub-tree: reuse the header element under the new id
  /// (`retargetFileHeader`), re-splice the body, and move the ordering bookkeeping
  /// old → new. The old id is gone afterwards (pierre `getItem(old) == nil`).
  private func renameFile(from old: FileID, to new: FileID, chunks: [Chunk]) {
    guard let headerID = tree.retargetFileHeader(from: old, to: new) else {
      appendFile(fileID: new, chunks: chunks)
      return
    }
    // Drop the old body nodes (everything in the span except the reused header).
    if let span = tree.fileNodeSpan(fileID: new) {
      for id in span.nodes where id != headerID { tree.remove(id) }
    }
    // Reinsert the fresh body after the reused header (the classifier emits the
    // header first, so skip it — the existing instance stays).
    let last = tree.insertChunks(Array(chunks.dropFirst()), after: headerID)
    lastNodeID[new] = last ?? headerID
    if let index = fileOrder.firstIndex(of: old) {
      fileOrder[index] = new
    } else {
      fileOrder.append(new)
    }
    identities[old] = nil
    lastNodeID[old] = nil
    diagnostics.splices += 1
    viewport.apply(tree: tree, mode: mode, scrollPreserving: true)
  }

  /// Splice a changed file's sub-tree in place: remove its node span (O(log n) per
  /// node), reinsert the fresh chunks at the same position, keeping the
  /// content-anchored scroll. Unchanged siblings — and their measured heights —
  /// are never touched.
  private func replaceFile(fileID: FileID, with chunks: [Chunk]) {
    guard let span = tree.fileNodeSpan(fileID: fileID) else {
      appendFile(fileID: fileID, chunks: chunks)
      return
    }
    for id in span.nodes { tree.remove(id) }
    let last = tree.insertChunks(chunks, after: span.predecessor)
    lastNodeID[fileID] = last
    diagnostics.splices += 1
    viewport.apply(tree: tree, mode: mode, scrollPreserving: true)
  }

  /// Remove a vanished file entirely (finish-time prune).
  private func removeFile(_ fileID: FileID) {
    if let span = tree.fileNodeSpan(fileID: fileID) {
      for id in span.nodes { tree.remove(id) }
    }
    fileOrder.removeAll { $0 == fileID }
    identities[fileID] = nil
    lastNodeID[fileID] = nil
  }

  /// Reduce the scaffold placeholder to `pendingFileCount × coarse` (both modes)
  /// so the total refines below the fold as files materialize — never moving the
  /// anchored top, which sits above the placeholder.
  private func shrinkScaffold() {
    pendingFileCount = max(0, pendingFileCount - 1)
    guard let scaffoldID else { return }
    let target = CGFloat(pendingFileCount) * Self.coarseFileHeight(metrics: tree.metrics)
    tree.setMeasuredHeight(target, chunk: scaffoldID, localRow: 0, mode: .unified)
    tree.setMeasuredHeight(target, chunk: scaffoldID, localRow: 0, mode: .split)
  }
}
