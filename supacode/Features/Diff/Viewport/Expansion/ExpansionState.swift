import Foundation

/// Declarative, document-level expansion — the Swift port of pierre
/// `expandedHunks?: Map<number, HunkExpansionRegion> | true` (types.ts:707). The
/// ChunkTree is a projection of this; THIS is the source of truth, so it
/// survives a re-diff (Phase 9): the gap key is a hunk INDEX, not a line number.
///
/// Keyed by `GapKey.hunkIndex` (Phase 1, S13): the collapsed gap BEFORE hunk `i`
/// has key `i`; the trailing gap after the last hunk has key `hunks.count`. An
/// in-hunk edit shifts line numbers but not a gap's index, so the old
/// `expanded: Set<Int>` (line-number keyed, `DiffRowBuilder.swift:82,91,104`)
/// would NOT survive a re-diff — this deliberately does.
nonisolated enum ExpansionState: Equatable, Sendable {
  /// Whole-file reveal — pierre's `expandedHunks === true` / `expandUnchanged`.
  case full
  /// Per-gap reveal amounts, keyed by gap index (see `GapKey.hunkIndex`).
  case regions([Int: HunkExpansionRegion])

  static var collapsed: Self { .regions([:]) }

  /// pierre `DEFAULT_COLLAPSED_CONTEXT_THRESHOLD = 1` (constants.ts:59) — a gap of
  /// ≤ 1 unchanged line is never collapsed (C1).
  static let collapsedContextThreshold = 1
}

/// One collapsed gap's revealed slice — pierre `HunkExpansionRegion { fromStart;
/// fromEnd }` (types.ts:698). `fromStart` = lines revealed from the TOP of the
/// gap (downward from the hunk above); `fromEnd` = from the BOTTOM (upward toward
/// the hunk below). Default `{0,0}` (constants.ts:85). The TRAILING gap is
/// upward-only: `fromEnd` is ignored there (virtualDiffLayout.ts:195-196).
nonisolated struct HunkExpansionRegion: Equatable, Sendable {
  var fromStart: Int = 0
  var fromEnd: Int = 0
}

// MARK: - Resolve (pure math, port of `getExpandedRegion` virtualDiffLayout.ts:55-104)

extension ExpansionState {
  /// The resolved geometry of one gap: how many lines are revealed at the top /
  /// bottom, how many stay hidden, and whether nothing is left to collapse.
  nonisolated struct ResolvedRegion: Equatable, Sendable {
    var fromStart: Int  // lines revealed at the top of the gap
    var fromEnd: Int  // lines revealed at the bottom (0 for the trailing gap)
    var collapsedLines: Int  // lines still hidden — 0 ⇒ no expander leaf
    var renderAll: Bool

    init(fromStart: Int, fromEnd: Int, collapsedLines: Int, renderAll: Bool) {
      self.fromStart = fromStart
      self.fromEnd = fromEnd
      self.collapsedLines = collapsedLines
      self.renderAll = renderAll
    }
  }

  /// `rangeSize` = the gap's hidden-line count (from the bounding hunks).
  /// `isTrailing` clamps to upward-only per virtualDiffLayout.ts:195-208.
  ///
  /// - `.full` (expandUnchanged) OR a sub-threshold gap (`size <= threshold`)
  ///   reveals everything (C1: `fromStart = size`, `collapsedLines = 0`).
  /// - Otherwise clamp `fromStart` / `fromEnd` to `[0, size]`; `renderAll` when
  ///   `fromStart + fromEnd >= size`; `collapsedLines = max(size - expanded, 0)`.
  func resolve(
    gap: Int,
    rangeSize: Int,
    isTrailing: Bool = false,
    threshold: Int = ExpansionState.collapsedContextThreshold
  ) -> ResolvedRegion {
    let size = max(rangeSize, 0)
    // A gap that no longer maps to any hidden lines (stale index after a re-diff,
    // or a gap that ends exactly at the next hunk) is an inert no-op — never a crash.
    if size == 0 { return ResolvedRegion(fromStart: 0, fromEnd: 0, collapsedLines: 0, renderAll: false) }
    // `.full` (expandUnchanged) OR a sub-threshold gap ⇒ reveal everything (C1).
    if case .full = self { return ResolvedRegion(fromStart: size, fromEnd: 0, collapsedLines: 0, renderAll: true) }
    if size <= threshold { return ResolvedRegion(fromStart: size, fromEnd: 0, collapsedLines: 0, renderAll: true) }
    let region: HunkExpansionRegion
    if case .regions(let map) = self {
      region = map[gap] ?? HunkExpansionRegion()
    } else {
      region = HunkExpansionRegion()
    }
    let fromStart = min(max(region.fromStart, 0), size)
    let fromEnd = isTrailing ? 0 : min(max(region.fromEnd, 0), size)
    let expanded = fromStart + fromEnd
    let renderAll = expanded >= size
    return ResolvedRegion(
      fromStart: renderAll ? size : fromStart,
      fromEnd: renderAll ? 0 : fromEnd,
      collapsedLines: max(size - expanded, 0),
      renderAll: renderAll
    )
  }
}

// MARK: - Mutate (port of `expandHunk` DiffHunksRenderer.ts:268-287) + OUR step ladder (C2)

extension ExpansionState {
  /// C2: OUR granularity ladder — the "100-line step" is NOT a pierre constant
  /// (pierre's `expansionLineCount` is a per-embed option: demo 10, docs 100/5).
  /// We choose ±20 (fine) / ±100 (coarse) / whole. Do NOT attribute to pierre.
  nonisolated enum Step: Equatable, Sendable {
    case lines(Int)
    case whole
    static let fine: Step = .lines(20)
    static let coarse: Step = .lines(100)

    /// The line count of a `.lines` step (for expander tooltips), `nil` for `.whole`.
    var lineCount: Int? {
      if case .lines(let count) = self { return count }
      return nil
    }
  }

  /// Which end(s) of a collapsed gap an expand reveals. `.up` reveals from the
  /// top (downward from the hunk above → `fromStart`); `.down` from the bottom
  /// (upward toward the hunk below → `fromEnd`); `.both` reveals both ends. This
  /// is also the "accept / reject / both" axis of the region math.
  nonisolated enum Direction: Equatable, Sendable {
    case up
    case down
    case both
  }

  /// Additive on the gap's region (pierre expandHunk). `.whole` promotes the gap
  /// past its `rangeSize` (clamped to `renderAll` in `resolve`). No-op on `.full`
  /// (whole-file is all-or-nothing, matching pierre's boolean `expandUnchanged`).
  mutating func expand(gap: Int, by step: Step, direction: Direction) {
    guard case .regions(var map) = self else { return }
    var region = map[gap] ?? HunkExpansionRegion()
    switch step {
    case .whole:
      region.fromStart = .max  // clamped to `size` in `resolve`
    case .lines(let amount):
      let count = max(amount, 0)
      if direction == .up || direction == .both { region.fromStart = Self.saturatingAdd(region.fromStart, count) }
      if direction == .down || direction == .both { region.fromEnd = Self.saturatingAdd(region.fromEnd, count) }
    }
    map[gap] = region
    self = .regions(map)
  }

  /// Re-hide a gap. No-op on `.full` (whole-file is all-or-nothing, matching
  /// pierre's boolean `expandUnchanged`).
  mutating func collapse(gap: Int) {
    guard case .regions(var map) = self else { return }
    map[gap] = nil
    self = .regions(map)
  }

  /// Saturating add so a `.whole` (`fromStart == .max`) followed by a `.lines`
  /// expand cannot overflow-trap — `resolve` clamps the ceiling anyway.
  private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? .max : sum
  }
}
