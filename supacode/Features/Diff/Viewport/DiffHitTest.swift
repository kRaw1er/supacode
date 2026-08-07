import CoreGraphics

/// Which vertical x-band a point landed in. Each band belongs to a `DiffSide`
/// (in split the old/new panes are distinct; in unified the two gutters stack).
nonisolated enum DiffColumn: Equatable {
  case changeBar(DiffSide)
  case gutter(DiffSide)
  case content(DiffSide)

  /// The side this column's band belongs to.
  var side: DiffSide {
    switch self {
    case .changeBar(let side), .gutter(let side), .content(let side): return side
    }
  }

  /// Whether this band is a line-number gutter column. The gutter "+" range-select
  /// begins ONLY on a number column (pierre `requireNumberColumn: true` on down,
  /// `InteractionManager.ts:748-751`); a drag endpoint may sit over content
  /// (`requireNumberColumn: false`, `:889-892`).
  var isNumberColumn: Bool {
    if case .gutter = self { return true }
    return false
  }
}

/// A resolved geometric hit — which chunk / column / line a point is over. This
/// replaces pierre's `elementFromPoint` + `data-*` DOM reads
/// (`InteractionManager.ts:1395,1703`), which we can't use because there is no
/// per-line NSView: `y → chunk` is an O(log n) tree seek and `x → column` is a
/// linear scan of the ≤ 6 precomputed x-bands.
nonisolated struct DiffHit: Equatable {
  var chunkID: ChunkID
  var column: DiffColumn
  /// The git line number on the column's side, or `nil` for a widget row / a
  /// side the row carries no number on (an addition has no old number).
  var lineNumber: Int?
  /// The side the x-band belongs to (`nil` never happens today — a column always
  /// has a side — but kept optional for the widget-row phases).
  var side: DiffSide?
  /// Global rendered-row index (from the seek).
  var rowIndex: Int
  /// Wrapped visual sub-line; always `0` this phase (Phase 3 fills it).
  var subline: Int
}

/// Geometric hit-testing over the chunk-tree. Caseless `enum` — no free
/// functions (CLAUDE.md).
nonisolated enum DiffHitTest {
  /// One half-open x-band → the column it maps to.
  struct Band: Equatable {
    var range: Range<CGFloat>
    var column: DiffColumn
  }

  /// The width of a change-bar rail (plan spec: `[oldBar 4pt]`).
  static let changeBarWidth: CGFloat = 4

  /// The ≤ 6 precomputed, half-open x-bands for a row. In **unified** the five
  /// bands `[oldBar][oldNum][newBar][newNum][content]` sit in one row; in
  /// **split** the old pane is anchored at `x = 0` and the new pane at
  /// `round(width/2)`, three bands each (six total). Half-open ranges guarantee
  /// no gap / overlap: a point on a boundary lands in exactly one band.
  static func bands(mode: DiffViewMode, width: CGFloat, gutterW: CGFloat) -> [Band] {
    let bar = changeBarWidth
    switch mode {
    case .split:
      let mid = (width / 2).rounded()
      return pane(startX: 0, endX: mid, gutterW: gutterW, side: .old)
        + pane(startX: mid, endX: max(mid, width), gutterW: gutterW, side: .new)
    case .unified:
      let oldNumEnd = bar + gutterW
      let newBarEnd = oldNumEnd + bar
      let newNumEnd = newBarEnd + gutterW
      return [
        Band(range: 0..<bar, column: .changeBar(.old)),
        Band(range: bar..<oldNumEnd, column: .gutter(.old)),
        Band(range: oldNumEnd..<newBarEnd, column: .changeBar(.new)),
        Band(range: newBarEnd..<newNumEnd, column: .gutter(.new)),
        Band(range: newNumEnd..<max(newNumEnd, width), column: .content(.new)),
      ]
    }
  }

  /// The three bands of one pane (`[bar][gutter][content]`) anchored at `startX`.
  private static func pane(startX: CGFloat, endX: CGFloat, gutterW: CGFloat, side: DiffSide) -> [Band] {
    let bar = changeBarWidth
    let numEnd = startX + bar + gutterW
    return [
      Band(range: startX..<startX + bar, column: .changeBar(side)),
      Band(range: startX + bar..<numEnd, column: .gutter(side)),
      Band(range: numEnd..<max(numEnd, endX), column: .content(side)),
    ]
  }

  /// The column an x lands in (linear scan of the ≤ 6 bands). Falls back to the
  /// new-side content column for an x past the last band (wide-content overscroll).
  static func column(at positionX: CGFloat, mode: DiffViewMode, width: CGFloat, gutterW: CGFloat) -> DiffColumn {
    bands(mode: mode, width: width, gutterW: gutterW).first { $0.range.contains(positionX) }?.column ?? .content(.new)
  }

  /// Resolve a point (in flipped document coordinates) to a `DiffHit`: seek the
  /// tree for the chunk under `point.y` (O(log n)), map `point.x` to a column,
  /// and read the line number off the resolved rendered row.
  @MainActor
  static func hit(
    _ point: CGPoint,
    width: CGFloat,
    tree: ChunkTree,
    mode: DiffViewMode,
    metrics: DiffMetrics
  ) -> DiffHit? {
    guard let seekHit = tree.seek(y: point.y, mode: mode) else { return nil }
    let column = column(at: point.x, mode: mode, width: width, gutterW: metrics.gutterWidth)
    let resolved = seekHit.chunk.lineAndSide(for: column, localRow: seekHit.localRow, mode: mode)
    return DiffHit(
      chunkID: seekHit.id,
      column: column,
      lineNumber: resolved.line,
      side: resolved.side,
      rowIndex: seekHit.rowIndex,
      subline: 0
    )
  }

  /// Side-pinned resolve (drag continuation). The endpoint of a gutter range-drag
  /// may sit over content, not just the number column (pierre
  /// `requireNumberColumn: false` on drag, `InteractionManager.ts:889-892`), and
  /// the side is PINNED to the anchor's side — so we seek the chunk under `point.y`
  /// and read the line number on `side` regardless of which x-band `point.x` hit.
  /// (No `width` — the side variant forces `.gutter(side)`, so `point.x` and the
  /// x-band widths are irrelevant.)
  @MainActor
  static func hit(
    _ point: CGPoint,
    side: DiffSide,
    tree: ChunkTree,
    mode: DiffViewMode
  ) -> DiffHit? {
    guard let seekHit = tree.seek(y: point.y, mode: mode) else { return nil }
    let resolved = seekHit.chunk.lineAndSide(for: .gutter(side), localRow: seekHit.localRow, mode: mode)
    return DiffHit(
      chunkID: seekHit.id,
      column: .gutter(side),
      lineNumber: resolved.line,
      side: side,
      rowIndex: seekHit.rowIndex,
      subline: 0
    )
  }
}

extension Chunk {
  /// The git line number + side a geometric `column` resolves to on rendered row
  /// `localRow` of this chunk. `nil` line for a widget, or for a side the row
  /// carries no number on (an addition has no old number).
  func lineAndSide(for column: DiffColumn, localRow: Int, mode: DiffViewMode) -> (line: Int?, side: DiffSide?) {
    let side = column.side
    switch self {
    case .widget:
      return (nil, side)
    case .lineSegment(let segment):
      guard localRow >= 0 else { return (nil, side) }
      // Resolve the row's numbers in O(1) from the leaf's intrinsic numbering
      // (`LineSegment.lineNumbers`) instead of building the whole ≤maxLeafSpan
      // `renderedRows` array — the SAME fast path `ChunkTree.visibleLineRange`
      // uses. Building the full array here made hover / hit-test O(leaf) on every
      // `mouseMoved`. A no-newline-marker leaf (rare — EOF only) breaks the
      // rendered-row ↔ window-offset 1:1 mapping the O(1) resolver relies on, so
      // it falls back to the full projection.
      let deletionCount = segment.windowDeletionCount
      if segment.windowHasNoNewlineMarker(deletionCount: deletionCount) {
        let rows = segment.renderedRows(mode)
        guard rows.indices.contains(localRow) else { return (nil, side) }
        let row = rows[localRow]
        return (side == .old ? row.oldNumber : row.newNumber, side)
      }
      // Context / unified-change index the window directly, so guard the bound
      // (`lineNumbers` force-indexes `windowLine`); split-change's resolver is
      // internally bounds-guarded and returns `nil` past its paired rows.
      let indexesWindowDirectly = mode == .unified || segment.classification != .change
      if indexesWindowDirectly, localRow >= segment.window.count { return (nil, side) }
      let numbers = segment.lineNumbers(atRenderedRow: localRow, mode: mode, deletionCount: deletionCount)
      return (side == .old ? numbers.old : numbers.new, side)
    }
  }
}

/// Field-alias reconciliation for the tree↔viewport seam (S1b). Phase 1 stores
/// the canonical `rowIndex` / `rowHeight` and spells the row top `yOrigin`; other
/// phases spell those `index` / `height`. These computed aliases make every
/// spelling compile against the one stored value, so the seam is a single source
/// of truth rather than a latent contradiction. (The bare `y` spelling the seam
/// index also lists resolves to `yOrigin` — the one-character name would violate
/// the strict `identifier_name` lint, so `yOrigin` stays the canonical y spelling.)
extension ChunkHit {
  /// Alias for `rowIndex` (global rendered-row index).
  var index: Int { rowIndex }
  /// Alias for `rowHeight` (already mode-resolved height).
  var height: CGFloat { rowHeight }
}
