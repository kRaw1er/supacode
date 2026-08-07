import Foundation

/// The aggregated, SCALAR-ONLY summary — the whole point of the tree. A monoid:
/// `+` / `zero` let node & subtree summaries combine in O(1). No text here, ever
/// (text / CTLines / spans / parse-trees are side caches in later phases). The
/// dual-mode fields let a single tree answer seeks in unified AND split with no
/// per-line reproject on toggle.
nonisolated struct ChunkSummary: Equatable, Sendable {
  var unifiedCount: Int  // rendered rows in unified
  var splitCount: Int  // rendered aligned-pair rows in split
  var unifiedEstHeight: CGFloat  // == unifiedCount * lineHeight at build (pierre estimate)
  var splitEstHeight: CGFloat
  var unifiedMeasuredDelta: CGFloat  // Σ(measured − estimate) over measured unified rows
  var splitMeasuredDelta: CGFloat
  /// The span of SOURCE line numbers this subtree carries, per side (`nil` when it
  /// carries none — an all-addition block spans no old lines). Monotonic within a
  /// file, which is what lets "which row holds line N" descend the tree in O(log n)
  /// instead of scanning the document.
  var oldLines: LineSpan?
  var newLines: LineSpan?

  init(
    unifiedCount: Int,
    splitCount: Int,
    unifiedEstHeight: CGFloat,
    splitEstHeight: CGFloat,
    unifiedMeasuredDelta: CGFloat = 0,
    splitMeasuredDelta: CGFloat = 0,
    oldLines: LineSpan? = nil,
    newLines: LineSpan? = nil
  ) {
    self.unifiedCount = unifiedCount
    self.splitCount = splitCount
    self.unifiedEstHeight = unifiedEstHeight
    self.splitEstHeight = splitEstHeight
    self.unifiedMeasuredDelta = unifiedMeasuredDelta
    self.splitMeasuredDelta = splitMeasuredDelta
    self.oldLines = oldLines
    self.newLines = newLines
  }

  /// The line span on `side`.
  func lines(on side: DiffSide) -> LineSpan? {
    side == .old ? oldLines : newLines
  }

  /// The monoid identity — an empty subtree.
  static let zero = ChunkSummary(
    unifiedCount: 0,
    splitCount: 0,
    unifiedEstHeight: 0,
    splitEstHeight: 0,
    unifiedMeasuredDelta: 0,
    splitMeasuredDelta: 0
  )

  /// Rendered-row count in `mode`.
  func count(_ mode: DiffViewMode) -> Int {
    mode == .unified ? unifiedCount : splitCount
  }

  /// Resolved height in `mode` (pierre `computeApproximateSize`: est + measured).
  func height(_ mode: DiffViewMode) -> CGFloat {
    mode == .unified
      ? unifiedEstHeight + unifiedMeasuredDelta
      : splitEstHeight + splitMeasuredDelta
  }

  /// Field-wise monoid combine — the O(1) glue for subtree aggregation.
  static func + (lhs: ChunkSummary, rhs: ChunkSummary) -> ChunkSummary {
    ChunkSummary(
      unifiedCount: lhs.unifiedCount + rhs.unifiedCount,
      splitCount: lhs.splitCount + rhs.splitCount,
      unifiedEstHeight: lhs.unifiedEstHeight + rhs.unifiedEstHeight,
      splitEstHeight: lhs.splitEstHeight + rhs.splitEstHeight,
      unifiedMeasuredDelta: lhs.unifiedMeasuredDelta + rhs.unifiedMeasuredDelta,
      splitMeasuredDelta: lhs.splitMeasuredDelta + rhs.splitMeasuredDelta,
      oldLines: LineSpan.union(lhs.oldLines, rhs.oldLines),
      newLines: LineSpan.union(lhs.newLines, rhs.newLines)
    )
  }
}

/// The inclusive `first…last` source-line span a subtree covers on one side.
nonisolated struct LineSpan: Equatable, Sendable {
  var first: Int
  var last: Int

  init(first: Int, last: Int) {
    self.first = min(first, last)
    self.last = max(first, last)
  }

  init(_ line: Int) {
    self.init(first: line, last: line)
  }

  func contains(_ line: Int) -> Bool { line >= first && line <= last }

  static func union(_ lhs: LineSpan?, _ rhs: LineSpan?) -> LineSpan? {
    guard let lhs else { return rhs }
    guard let rhs else { return lhs }
    return LineSpan(first: Swift.min(lhs.first, rhs.first), last: Swift.max(lhs.last, rhs.last))
  }
}

/// Per-leaf sparse override: only rows whose measured height ≠ estimate (wrap /
/// no-newline marker). Keyed by LOCAL rendered-row index within the segment,
/// dual-mode (a wide unified row and a narrow split row wrap differently).
nonisolated struct LineHeightDelta: Equatable, Sendable {
  var unified: CGFloat
  var split: CGFloat

  init(unified: CGFloat = 0, split: CGFloat = 0) {
    self.unified = unified
    self.split = split
  }

  /// The delta in `mode`.
  func value(_ mode: DiffViewMode) -> CGFloat {
    mode == .unified ? unified : split
  }
}

/// Intra-mega-leaf accelerator (pierre `LAYOUT_CHECKPOINT_INTERVAL`). Only present
/// on a leaf that reached `maxLeafSpan` before the builder chose to split it, so
/// a deep intra-leaf seek can binary-search a resume point instead of replaying
/// layout from the leaf's first row.
nonisolated struct LayoutCheckpoint: Equatable, Sendable {
  var localLine: Int
  var unifiedTop: CGFloat
  var splitTop: CGFloat

  /// The checkpoint's top offset in `mode`.
  func top(_ mode: DiffViewMode) -> CGFloat {
    mode == .unified ? unifiedTop : splitTop
  }
}

/// Layout constants — pierre's verified metrics, injectable so tests can pin the
/// arithmetic (est tests use pierre's `{lineHeight:10, diffHeaderHeight:30, …}`
/// base). Production values are the verified pierre constants.
nonisolated struct ChunkLayoutMetrics: Equatable, Sendable {
  var lineHeight: CGFloat
  var diffHeaderHeight: CGFloat
  /// The hunk separator row — ONE constant, because there is ONE such row: the
  /// collapsed-gap bar that also carries the `@@ … @@` header. It is both what the
  /// estimate reserves per collapsed gap and what the widget renders, so the two
  /// cannot drift. (It used to be two: `separatorHeight` for a standalone header
  /// leaf and `expanderHeight` for the bar, which is precisely how the estimate came
  /// to reserve a row the tree never built.)
  var separatorHeight: CGFloat  // pierre line-info separator body, 32
  var simpleSeparatorHeight: CGFloat  // simple-style middle rule (pierre 4)
  var placeholderHeight: CGFloat
  var commentThreadHeight: CGFloat
  var paddingTop: CGFloat
  var paddingBottom: CGFloat

  init(
    lineHeight: CGFloat = 20,
    diffHeaderHeight: CGFloat = 44,
    separatorHeight: CGFloat = 32,
    simpleSeparatorHeight: CGFloat = 4,
    placeholderHeight: CGFloat = 60,
    commentThreadHeight: CGFloat = 120,
    paddingTop: CGFloat = 0,
    paddingBottom: CGFloat = 8
  ) {
    self.lineHeight = lineHeight
    self.diffHeaderHeight = diffHeaderHeight
    self.separatorHeight = separatorHeight
    self.simpleSeparatorHeight = simpleSeparatorHeight
    self.placeholderHeight = placeholderHeight
    self.commentThreadHeight = commentThreadHeight
    self.paddingTop = paddingTop
    self.paddingBottom = paddingBottom
  }

  /// The verified pierre production metrics (`lineHeight 20`, `diffHeaderHeight 44`,
  /// hunk separator `32` / simple `4`).
  static let production = ChunkLayoutMetrics()

  /// Max rendered rows a single dense leaf may span before the builder splits it
  /// (= pierre `LAYOUT_CHECKPOINT_INTERVAL`). A 1M-line file → ~200 leaves.
  static let maxLeafSpan = 5_000
}

/// The two hunk-separator styles we keep (pierre ships 5; GAP §4.3 reduces us to
/// these two). `lineInfo` reserves spacing + a rule body; `simple` reserves only
/// a thin middle rule.
nonisolated enum HunkSeparatorStyle: Equatable, Sendable {
  case lineInfo
  case simple
}

/// Where a hunk separator sits relative to the hunk sequence — the spacing rules
/// differ (pierre `first / middle / trailing`).
nonisolated enum SeparatorPosition: Equatable, Sendable {
  case first
  case middle
  case trailing
}
