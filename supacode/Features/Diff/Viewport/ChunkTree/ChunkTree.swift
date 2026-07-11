import CoreGraphics
import Foundation

/// Resolved row descriptor (CETV `TextLinePosition` analog). `localRow` is the
/// rendered-row offset within the leaf (0 for widgets); `yOrigin` / `rowHeight`
/// are in `mode`'s space (already resolved — no argument needed). Carries the
/// resolved `chunk` so consumers read `chunk.reuseKind` / `chunk.id` without a
/// second seek.
///
/// `yOrigin` is the canonical "absolute top of the resolved row" (consumer phases
/// also spell it `y`); `rowIndex` is the canonical rendered index (alias `index`);
/// `rowHeight` is the already-mode-resolved height (alias `height`).
nonisolated struct ChunkHit: Equatable, Sendable {
  var id: ChunkID
  var chunk: Chunk
  var rowIndex: Int  // global rendered row index in `mode`
  var localRow: Int
  var yOrigin: CGFloat  // absolute top of the resolved row
  var rowHeight: CGFloat  // already resolved in `mode`
}

/// A half-open rendered-row index range (Phase 2 `fireVisibleRange`).
nonisolated struct ChunkRange: Equatable, Sendable {
  var rows: Range<Int>

  var lowerBound: Int { rows.lowerBound }
  var upperBound: Int { rows.upperBound }
}

/// The 1-based SOURCE-line ranges visible on screen, split by blob side — the ONLY
/// coordinate a blob highlighter may be queried with, and the space the row lookup
/// keys off (`DiffLine.old/newLineNumber`). Deliberately NOT a `ChunkRange`: rendered
/// row indices are shifted by every widget / expander / collapsed gap and are shared
/// across both sides, so handing them to a per-blob highlighter queries the wrong
/// region of the wrong file (the "all text white" bug). An empty side means no rows
/// of that blob are on screen (e.g. an all-addition hunk shows no old lines).
nonisolated struct VisibleLineWindow: Equatable, Sendable {
  var old: Range<Int>
  var new: Range<Int>

  static let empty = VisibleLineWindow(old: 0..<0, new: 0..<0)
}

/// Whether a within-leaf resolve is targeting a rendered-row index or a y-offset.
nonisolated enum ChunkTreeLocalTarget: Sendable {
  case index(Int)
  case offset(CGFloat)
}

/// A resolved within-leaf row: its local offset, its top relative to the leaf,
/// and its height (all in the query `mode`).
nonisolated struct RowResolution: Equatable, Sendable {
  var localRow: Int
  var rowY: CGFloat
  var rowHeight: CGFloat
}

/// The dense-segment, dual-mode red-black `SumTree`. Single source of "which
/// chunk is at row / pixel X, in unified AND split" — O(log n). Pure model, no
/// AppKit. Implicitly `@MainActor` (the app-target default); only ever mutated
/// from the Phase-2 viewport on main. NOT `@Observable` (not TCA state).
final class ChunkTree {
  private(set) var root: ChunkNode?

  /// The layout metrics this tree was built with (row heights / est seeds).
  let metrics: ChunkLayoutMetrics

  /// O(1) id → node lookup for mutation (`split` / `setMeasuredHeight` / `reaggregate`).
  var nodesByID: [ChunkID: ChunkNode] = [:]

  /// fileID → its leading `.widget(fileHeader)` node id (file-nav seek).
  var fileHeaderNodes: [FileID: ChunkID] = [:]

  /// `WidgetKey` → its node id. `WidgetKey` is per-instance identity (Phase 1 S1),
  /// so a widget resolves its MODEL and its measured-height write-back by key
  /// (Phase 6 `LayoutCoalescer` / comment-thread harness) without a linear walk.
  var widgetNodes: [WidgetKey: ChunkID] = [:]

  /// The node backing a `WidgetKey`, or `nil` when no such widget is in the tree.
  func widgetNode(for key: WidgetKey) -> ChunkNode? {
    guard let cid = widgetNodes[key] else { return nil }
    return nodesByID[cid]
  }

  /// Monotonic id allocator — document order on a from-scratch build, so two
  /// deterministic builds mint the same id sequence.
  var nextRaw: UInt64 = 0

  /// Instrumentation the fixtures assert on (seek pressure, build calls).
  var diagnostics = Diagnostics()

  /// Instrumentation surface. `seekCount` is load-bearing for the Phase-8
  /// "toggle is O(log n), not O(n)" assertion; `buildRowsCallCount` is the
  /// builder spy.
  nonisolated struct Diagnostics: Equatable, Sendable {
    var seekCount: Int = 0
    var buildRowsCallCount: Int = 0
  }

  init(metrics: ChunkLayoutMetrics = .production) {
    self.metrics = metrics
  }

  /// Assign the root. Same-file setter so the balance extension (a sibling file)
  /// can re-root during rotations while `root` stays `private(set)` to consumers.
  func updateRoot(_ node: ChunkNode?) {
    root = node
  }

  /// Live node count — asserts "node count ≪ line count" at 1M scale.
  var nodeCount: Int { nodesByID.count }

  // MARK: - Seek (the primitive every later phase calls)

  /// Seek by absolute y in `mode`. Returns nil on an empty tree; clamps a y past
  /// the end to the last row.
  func seek(y target: CGFloat, mode: DiffViewMode) -> ChunkHit? {
    diagnostics.seekCount += 1
    guard let root, root.subtreeSummary.count(mode) > 0 else { return nil }
    var node = root
    var remaining = min(max(target, 0), root.subtreeSummary.height(mode))
    var startIndex = 0
    var startY: CGFloat = 0
    while true {
      let leftHeight = node.leftSubtree.height(mode)
      if remaining < leftHeight {
        node = node.left!
        continue
      }
      remaining -= leftHeight
      startIndex += node.leftSubtree.count(mode)
      startY += leftHeight
      let ownHeight = node.summary.height(mode)
      if remaining < ownHeight || node.right == nil {
        return resolveHit(node, startIndex: startIndex, startY: startY, local: .offset(remaining), mode: mode)
      }
      remaining -= ownHeight
      startIndex += node.summary.count(mode)
      startY += ownHeight
      node = node.right!
    }
  }

  /// Seek by global rendered-row index in `mode`. Returns nil when out of range.
  func seek(index target: Int, mode: DiffViewMode) -> ChunkHit? {
    diagnostics.seekCount += 1
    guard let root, target >= 0, target < root.subtreeSummary.count(mode) else { return nil }
    var node = root
    var remaining = target
    var startIndex = 0
    var startY: CGFloat = 0
    while true {
      let leftCount = node.leftSubtree.count(mode)
      if remaining < leftCount {
        node = node.left!
        continue
      }
      remaining -= leftCount
      startIndex += leftCount
      startY += node.leftSubtree.height(mode)
      let ownCount = node.summary.count(mode)
      if remaining < ownCount {
        return resolveHit(node, startIndex: startIndex, startY: startY, local: .index(remaining), mode: mode)
      }
      remaining -= ownCount
      startIndex += ownCount
      startY += node.summary.height(mode)
      node = node.right!
    }
  }

  // MARK: - Structural mutation

  /// Insert `chunk` as the in-order successor of `id` (`nil` prepends). O(log n).
  @discardableResult
  func insert(_ chunk: Chunk, after id: ChunkID?) -> ChunkID {
    let node = makeNode(for: chunk, heightDeltas: nil)
    register(node)
    bstInsertAsSuccessor(node, after: id)
    node.subtreeSummary = node.summary
    reaggregatePath(from: node.parent)
    insertFixup(node)
    root?.color = .black
    return node.id
  }

  /// Split a `.lineSegment` at a LOCAL row offset into (left, right). The existing
  /// node keeps `lo..<lo+offset`; a new node (its in-order successor) takes
  /// `lo+offset..<hi` over the same COW `lines` backing. Widgets cannot be split.
  @discardableResult
  func split(_ id: ChunkID, atLocalRow offset: Int) -> (left: ChunkID, right: ChunkID) {
    guard let node = nodesByID[id], let segment = node.chunk.lineSegment else {
      preconditionFailure("split requires a .lineSegment leaf")
    }
    let low = segment.window.lowerBound
    let high = segment.window.upperBound
    precondition(offset > 0 && offset < (high - low), "split offset \(offset) out of range for window \(low..<high)")

    let rightNode = performSplit(node: node, segment: segment, low: low, high: high, offset: offset)
    register(rightNode)
    bstInsertAsSuccessor(rightNode, after: id)
    rightNode.subtreeSummary = rightNode.summary
    reaggregatePath(from: rightNode)
    insertFixup(rightNode)
    root?.color = .black
    return (id, rightNode.id)
  }

  // MARK: - Measured-height write-back

  /// Record a row's measured height, updating the leaf's sparse delta + summary,
  /// then re-aggregating ancestors ONLY (siblings untouched). O(log n).
  func setMeasuredHeight(_ height: CGFloat, chunk id: ChunkID, localRow: Int, mode: DiffViewMode) {
    guard let node = nodesByID[id] else { return }
    if let widget = node.chunk.widget {
      let delta = height - widget.estimatedHeight
      if mode == .unified {
        node.summary.unifiedMeasuredDelta = delta
      } else {
        node.summary.splitMeasuredDelta = delta
      }
    } else {
      let delta = height - metrics.lineHeight
      var deltas = node.heightDeltas ?? [:]
      var entry = deltas[localRow] ?? LineHeightDelta()
      if mode == .unified { entry.unified = delta } else { entry.split = delta }
      deltas[localRow] = entry
      node.heightDeltas = deltas
      node.summary = leafSummary(for: node.chunk, heightDeltas: deltas)
    }
    reaggregatePath(from: node)
  }

  /// Recompute a node's aggregate from its chunk + children and propagate up the
  /// root path only. The public batch re-aggregate hook.
  func reaggregate(from id: ChunkID) {
    reaggregatePath(from: nodesByID[id])
  }

  // MARK: - Navigation

  /// In-order successor of a hit (the viewport walks the visible window). nil at
  /// the last row.
  func successor(of hit: ChunkHit, mode: DiffViewMode) -> ChunkHit? {
    guard let node = nodesByID[hit.id] else { return nil }
    if hit.localRow + 1 < node.summary.count(mode) {
      return makeHit(for: node, localRow: hit.localRow + 1, mode: mode)
    }
    guard let next = inorderSuccessorNode(node) else { return nil }
    return makeHit(for: next, localRow: 0, mode: mode)
  }

  /// The rendered-row index range intersecting a rect (Phase 2 `fireVisibleRange`).
  func indexRange(in rect: CGRect, mode: DiffViewMode) -> ChunkRange {
    guard let top = seek(y: rect.minY, mode: mode), let bottom = seek(y: rect.maxY, mode: mode) else {
      return ChunkRange(rows: 0..<0)
    }
    return ChunkRange(rows: top.rowIndex..<(bottom.rowIndex + 1))
  }

  /// The 1-based source-line ranges actually visible in `rect`, per blob side — the
  /// highlight-query window. Resolves the visible RENDERED rows (which `indexRange`
  /// returns as widget-shifted, side-shared indices — the wrong coordinate for a blob
  /// query) back to the `DiffLine.old/newLineNumber` space the highlighter and the row
  /// lookup share. Walks only the rows intersecting `rect` (bounded by the viewport,
  /// O(visible-rows · log n)); widget / marker rows contribute no line number.
  func visibleLineRange(in rect: CGRect, mode: DiffViewMode) -> VisibleLineWindow {
    guard let top = seek(y: rect.minY, mode: mode) else { return .empty }
    var oldLo = Int.max
    var oldHi = Int.min
    var newLo = Int.max
    var newHi = Int.min
    var hit: ChunkHit? = top
    // Resolve each visible row's source numbers in O(1) from the leaf's intrinsic
    // numbering (`LineSegment.lineNumbers`) instead of building the whole ≤maxLeafSpan
    // `renderedRows` array per distinct visible leaf — that array build (+ its two
    // `windowDeletions`/`windowAdditions` filters) was ~75% of the per-frame scroll cost
    // on a big leaf. The per-leaf `deletionCount` (O(log window) binary search) is
    // memoized across the walk; a leaf carrying a no-newline marker (rare — EOF only,
    // where rendered-row ≠ window offset) falls back to the full projection.
    var cachedID: ChunkID?
    var cachedSegment: LineSegment?
    var cachedDelCount = 0
    var cachedFallback: [RenderedRow]?
    while let current = hit, current.yOrigin < rect.maxY {
      if current.id != cachedID {
        cachedID = current.id
        cachedSegment = current.chunk.lineSegment
        cachedFallback = nil
        cachedDelCount = 0
        if let segment = cachedSegment {
          cachedDelCount = segment.windowDeletionCount
          if segment.windowHasNoNewlineMarker(deletionCount: cachedDelCount) {
            cachedFallback = current.chunk.renderedRows(mode)
          }
        }
      }
      if let segment = cachedSegment, current.localRow >= 0 {
        let numbers: (old: Int?, new: Int?)
        if let fallback = cachedFallback {
          guard current.localRow < fallback.count else {
            hit = successor(of: current, mode: mode)
            continue
          }
          let row = fallback[current.localRow]
          numbers = (row.oldNumber, row.newNumber)
        } else {
          numbers = segment.lineNumbers(atRenderedRow: current.localRow, mode: mode, deletionCount: cachedDelCount)
        }
        if let old = numbers.old {
          oldLo = min(oldLo, old)
          oldHi = max(oldHi, old)
        }
        if let new = numbers.new {
          newLo = min(newLo, new)
          newHi = max(newHi, new)
        }
      }
      hit = successor(of: current, mode: mode)
    }
    return VisibleLineWindow(
      old: oldLo <= oldHi ? oldLo..<(oldHi + 1) : 0..<0,
      new: newLo <= newHi ? newLo..<(newHi + 1) : 0..<0)
  }

  /// Seek to a file's leading `.widget(fileHeader)`. O(log n) via the file index.
  func offsetForFile(_ file: FileID, mode: DiffViewMode) -> ChunkHit? {
    guard let cid = fileHeaderNodes[file], let node = nodesByID[cid] else { return nil }
    return makeHit(for: node, localRow: 0, mode: mode)
  }

  /// The leading `.widget(fileHeader)` node for a file, if present.
  func fileNode(id file: FileID) -> ChunkNode? {
    guard let cid = fileHeaderNodes[file] else { return nil }
    return nodesByID[cid]
  }

  // MARK: - Mode toggle (re-seek by `(chunkID, localRow)`, never a row index)

  /// The `(chunkID, localRow)` anchor for a rendered-row index in `mode`. Toggle
  /// = `locate` in the current mode, then `rowIndex(for:mode:)` in the other —
  /// same chunk, new y, no O(n) reproject.
  func locate(rowIndex: Int, mode: DiffViewMode) -> (chunk: ChunkID, localRow: Int)? {
    guard let hit = seek(index: rowIndex, mode: mode) else { return nil }
    return (hit.id, hit.localRow)
  }

  /// The rendered-row index of a `(chunkID, localRow)` anchor in `mode`.
  func rowIndex(for anchor: (chunk: ChunkID, localRow: Int), mode: DiffViewMode) -> Int? {
    guard let node = nodesByID[anchor.chunk] else { return nil }
    let (startIndex, _) = rank(of: node, mode: mode)
    let clamped = min(max(anchor.localRow, 0), max(node.summary.count(mode) - 1, 0))
    return startIndex + clamped
  }

  // MARK: - Model-sourced copy projection (Phase 11)

  /// Resolve a rendered-row index to the single `(side, lineNumber)` the row
  /// displays, for model-sourced clean copy. `.old` for a deletion row, `.new` for a
  /// context / addition row; `nil` for a widget row, a no-newline marker row, or an
  /// empty split pane (nothing to copy). `lineNumber` is the git line number on
  /// `side` (1-based, matching `DiffLine.oldLineNumber` / `.newLineNumber`); the
  /// copy path translates it to the side store's own index. O(log n) via `seek`.
  func diffLine(atRow row: Int, mode: DiffViewMode) -> (side: DiffSide, lineNumber: Int)? {
    guard let hit = seek(index: row, mode: mode) else { return nil }
    let rendered = hit.chunk.renderedRows(mode)
    guard hit.localRow >= 0, hit.localRow < rendered.count else { return nil }
    let renderedRow = rendered[hit.localRow]
    guard !renderedRow.isMarker else { return nil }
    if renderedRow.origin == .deletion {
      guard let lineNumber = renderedRow.oldNumber else { return nil }
      return (.old, lineNumber)
    }
    guard let lineNumber = renderedRow.newNumber else { return nil }
    return (.new, lineNumber)
  }

  // MARK: - Accessibility geometry (Phase 12 consumer-API)

  /// The document-space rect of a materialized row in `mode` — a pure O(log n) seek
  /// that is VALID OFFSCREEN (no dependency on any live / recycled view), so
  /// `DiffLineAXElement.accessibilityFrameInParentSpace` hands VoiceOver a real frame
  /// for a line far off either edge. `x` is always 0 (full-bleed rows); `width` is
  /// the AX-parent (documentView) width. `.zero` for an out-of-range row.
  func rowFrameInDocument(_ row: Int, mode: DiffViewMode, width: CGFloat) -> CGRect {
    guard let hit = seek(index: row, mode: mode) else { return .zero }
    return CGRect(x: 0, y: hit.yOrigin, width: width, height: hit.rowHeight)
  }

  // MARK: - Totals

  /// Rendered-row count in `mode` (root aggregate). O(1).
  func rowCount(_ mode: DiffViewMode) -> Int {
    root?.subtreeSummary.count(mode) ?? 0
  }

  /// Total document height in `mode` (root aggregate). O(1).
  func totalHeight(_ mode: DiffViewMode) -> CGFloat {
    root?.subtreeSummary.height(mode) ?? 0
  }

  /// The in-order chunk list (document order) — the structural-equality projection.
  func inorderChunks() -> [Chunk] {
    var out: [Chunk] = []
    appendInorder(root, into: &out)
    return out
  }

  /// The in-order node list (document order).
  func inorderNodes() -> [ChunkNode] {
    var out: [ChunkNode] = []
    appendInorderNodes(root, into: &out)
    return out
  }

  /// The largest source line number (old or new) carried by any line segment in
  /// the tree — the digit count the line-number gutter must fit so a 6+ digit file
  /// (or a long file below a short one in a multi-file diff) never clips its
  /// numbers. Line numbers rise monotonically within a segment, so only the last
  /// non-nil number per side per segment is inspected: O(leaves) with a tiny
  /// constant, not O(total lines). Keyed off `nodesByID` (order-independent — a max
  /// needs no ordering) so no in-order array is materialized.
  var maxLineNumber: Int {
    var best = 0
    for node in nodesByID.values {
      guard let segment = node.chunk.lineSegment else { continue }
      var foundOld = false
      var foundNew = false
      for line in segment.windowedLines.reversed() {
        if !foundOld, let old = line.oldLineNumber {
          best = max(best, old)
          foundOld = true
        }
        if !foundNew, let new = line.newLineNumber {
          best = max(best, new)
          foundNew = true
        }
        if foundOld, foundNew { break }
      }
    }
    return best
  }
}
