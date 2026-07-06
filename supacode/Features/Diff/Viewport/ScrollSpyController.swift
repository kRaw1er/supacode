import AppKit

/// Ascending `(fileID, headerTop-y)` table over the chunk-tree, rebuilt on any
/// structural mutation (insert / expand / stream) AND on a mode toggle — the file
/// header y's are mode-keyed (split ≠ unified). Source of truth is Phase-1
/// `ChunkTree.offsetForFile(_:mode:)`; this is a thin O(#files) cache so scroll-spy
/// + sticky don't re-seek the tree per frame (C3: pass the current `mode`, read the
/// header top off `hit.yOrigin`, no new Phase-1 method — `nextTop` walks the cached
/// table, not an `offsetForFile(after:)` on the tree).
struct FileOffsetIndex: Equatable {
  private let sorted: [Entry]

  private struct Entry: Equatable {
    let id: FileChange.ID
    let top: CGFloat
  }

  /// Empty index — an empty diff / zero-file tree. Every query returns `nil`.
  init() {
    sorted = []
  }

  init(files: [FileChange.ID], tree: ChunkTree, mode: DiffViewMode) {
    sorted =
      files
      .compactMap { id in tree.offsetForFile(id, mode: mode).map { Entry(id: id, top: $0.yOrigin) } }
      .sorted { $0.top < $1.top }
  }

  /// Whether the index has any files.
  var isEmpty: Bool { sorted.isEmpty }

  /// Last file whose header top ≤ `target` — the file owning the clip top. O(log n).
  /// `nil` when `target` sits above the first file's header (or the index is empty).
  func file(atOrAbove target: CGFloat) -> FileChange.ID? {
    var low = 0
    var high = sorted.count - 1
    var answer: FileChange.ID?
    while low <= high {
      let mid = (low + high) / 2
      if sorted[mid].top <= target {
        answer = sorted[mid].id
        low = mid + 1
      } else {
        high = mid - 1
      }
    }
    return answer
  }

  /// The header top of `id`, or `nil` when it isn't in the index.
  func top(of id: FileChange.ID) -> CGFloat? { sorted.first { $0.id == id }?.top }

  /// The header top of the file that follows `id` in document order, or `nil` when
  /// `id` is the last file (or absent). Drives the sticky-header push-out.
  func nextTop(after id: FileChange.ID) -> CGFloat? {
    guard let index = sorted.firstIndex(where: { $0.id == id }), index + 1 < sorted.count else { return nil }
    return sorted[index + 1].top
  }
}

/// `y → chunk → file` scroll-spy over the chunk-tree. Drives BOTH directions of the
/// inspector ↔ body link: the body's `boundsDidChange` feeds `scrollDidReach`
/// (body → list, change-only dedupe) and the list's jump-to-file reads
/// `offset(forFile:)` (list → body). O(log #files) per query via `FileOffsetIndex`.
@MainActor
final class ScrollSpyController {
  private var index: FileOffsetIndex
  private(set) var activeFileID: FileChange.ID?

  /// Fires ONLY when the owning file changes (dedupe). A per-tick republish would
  /// re-select the inspector row every frame — the exact churn CLAUDE.md's
  /// sidebar-perf discipline forbids (a display-only mutation must not invalidate
  /// unrelated rows).
  var onActiveFileChanged: (FileChange.ID) -> Void = { _ in }

  init(files: [FileChange.ID] = [], tree: ChunkTree = ChunkTree(), mode: DiffViewMode = .unified) {
    index = FileOffsetIndex(files: files, tree: tree, mode: mode)
  }

  /// Rebuild the cache from the tree — call on any structural mutation (insert /
  /// expand / stream) or a mode toggle (header y's are mode-keyed).
  func rebuild(files: [FileChange.ID], tree: ChunkTree, mode: DiffViewMode) {
    index = FileOffsetIndex(files: files, tree: tree, mode: mode)
  }

  /// Body → list. Called from the viewport's `boundsDidChange` handler with the
  /// document-space y of the clip's top edge. Emits `onActiveFileChanged` ONLY on a
  /// real file change (dedupe).
  func scrollDidReach(clipTop: CGFloat) {
    guard let id = index.file(atOrAbove: clipTop), id != activeFileID else { return }
    activeFileID = id
    onActiveFileChanged(id)
  }

  /// List → body (jump-to-file). The document-space header top of `id`. O(log n).
  func offset(forFile id: FileChange.ID) -> CGFloat? { index.top(of: id) }

  /// The file owning the clip top (sticky-header resolve). O(log n).
  func fileID(atTop clipTop: CGFloat) -> FileChange.ID? { index.file(atOrAbove: clipTop) }

  /// The header top of the file after `id` (sticky-header push-out). O(log n).
  func nextFileTop(after id: FileChange.ID) -> CGFloat? { index.nextTop(after: id) }

  /// Whether the index has any files (empty diff ⇒ overlay hidden, nav no-ops).
  var isEmpty: Bool { index.isEmpty }
}
