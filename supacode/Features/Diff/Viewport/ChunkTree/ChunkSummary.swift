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

  init(
    unifiedCount: Int,
    splitCount: Int,
    unifiedEstHeight: CGFloat,
    splitEstHeight: CGFloat,
    unifiedMeasuredDelta: CGFloat = 0,
    splitMeasuredDelta: CGFloat = 0
  ) {
    self.unifiedCount = unifiedCount
    self.splitCount = splitCount
    self.unifiedEstHeight = unifiedEstHeight
    self.splitEstHeight = splitEstHeight
    self.unifiedMeasuredDelta = unifiedMeasuredDelta
    self.splitMeasuredDelta = splitMeasuredDelta
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
      splitMeasuredDelta: lhs.splitMeasuredDelta + rhs.splitMeasuredDelta
    )
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
  var separatorHeight: CGFloat  // line-info hunk separator body (pierre 32)
  var simpleSeparatorHeight: CGFloat  // simple-style middle rule (pierre 4)
  var spacing: CGFloat
  var expanderHeight: CGFloat
  var placeholderHeight: CGFloat
  var commentThreadHeight: CGFloat
  var paddingTop: CGFloat
  var paddingBottom: CGFloat

  init(
    lineHeight: CGFloat = 20,
    diffHeaderHeight: CGFloat = 44,
    separatorHeight: CGFloat = 32,
    simpleSeparatorHeight: CGFloat = 4,
    spacing: CGFloat = 8,
    expanderHeight: CGFloat = 28,
    placeholderHeight: CGFloat = 60,
    commentThreadHeight: CGFloat = 120,
    paddingTop: CGFloat = 0,
    paddingBottom: CGFloat = 8
  ) {
    self.lineHeight = lineHeight
    self.diffHeaderHeight = diffHeaderHeight
    self.separatorHeight = separatorHeight
    self.simpleSeparatorHeight = simpleSeparatorHeight
    self.spacing = spacing
    self.expanderHeight = expanderHeight
    self.placeholderHeight = placeholderHeight
    self.commentThreadHeight = commentThreadHeight
    self.paddingTop = paddingTop
    self.paddingBottom = paddingBottom
  }

  /// The verified pierre production metrics (`lineHeight 20`, `diffHeaderHeight 44`,
  /// `spacing 8`, hunk separator `32` / simple `4`).
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
