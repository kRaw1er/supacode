import CoreGraphics

/// An identity-based scroll anchor. The identity is `(lineNumber, side)` for a
/// line chunk or `.widget(ChunkID)` for a sparse widget — NEVER a y or a view —
/// so it survives both view recycle AND a re-measure (pierre `getScrollAnchor`
/// returns a *line*, not a pixel/element; phase-2 Note B). `pixelOffset` is the
/// anchored chunk's top minus the viewport top and is always ≥ 0 because we
/// anchor the first *fully* visible chunk (pierre `lineOffset >= 0`,
/// `Virtualizer.ts:483`), not the row straddling the viewport top.
nonisolated struct ScrollAnchor: Equatable {
  /// What the anchor is pinned to. `Hashable` so it can key the bounded
  /// materialized-window map (`[Identity: yOrigin]`) the restore reads.
  enum Identity: Hashable {
    /// A dense code row, keyed by its git line number + side (survives re-diff /
    /// re-measure / a full from-scratch tree rebuild — the ChunkID would not).
    case line(lineNumber: Int, side: DiffSide)
    /// A sparse widget (file header / comment / expander) that has no line
    /// number, keyed by its stable `ChunkID`.
    case widget(ChunkID)
  }

  var identity: Identity
  var pixelOffset: CGFloat

  /// The clamped scroll target that re-lands the anchored chunk at the same
  /// pixel (pierre `applyScrollFix` `scrollTo({top})` + the `DiffTableController`
  /// `:489-490` maxY clamp). Pure geometry — no window, no view — so the
  /// flipped-coordinate + retina math is unit-testable in isolation:
  /// `min(max(0, anchorY − pixelOffset), max(0, documentHeight − clipHeight))`.
  static func clampedTargetY(
    anchorY: CGFloat,
    pixelOffset: CGFloat,
    documentHeight: CGFloat,
    clipHeight: CGFloat
  ) -> CGFloat {
    let maxY = max(0, documentHeight - clipHeight)
    return min(max(0, anchorY - pixelOffset), maxY)
  }
}
