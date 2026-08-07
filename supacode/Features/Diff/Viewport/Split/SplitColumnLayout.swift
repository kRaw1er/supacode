import CoreGraphics

/// How split renders for the current geometry + wrap setting (C4).
nonisolated enum SplitPresentation: Equatable, Sendable {
  /// OUR wrap-only divergence: ONE full-width row per pair, two cells, height
  /// `max(hLeft,hRight)`; single vertical scroll, NO h-scroll, NO sync. Valid only
  /// while soft-wrap is on (an unwrapped long line would clip).
  case wrapSingleRow
  /// pierre parity (C4): two independently h-scrollable columns aligned by a shared
  /// per-pair row-height table (our analog of grid rowspan, `FileDiff.ts:1871`),
  /// synced by `HScrollSyncController`, sticky-left gutter (`style.css:906-909`).
  case noWrapTwoColumns
}

/// Presentation + geometry policy for split mode. Pure, `@MainActor` (reads no
/// mutable state; `@MainActor` only so it composes with the view/controller layer
/// without hops). Caseless enum — no free functions (CLAUDE.md).
@MainActor
enum SplitColumnLayout {
  /// Monaco `renderSideBySideInlineBreakpoint` (default 900pt): below this the
  /// two-column split is coerced to inline (unified) for THIS render only — the
  /// stored `diffViewMode` flag is untouched, so widening restores split.
  static let inlineBreakpoint: CGFloat = 900

  /// The mode actually rendered for `stored` at `availableWidth`. Split below the
  /// breakpoint coerces to unified (view-only); unified is never coerced. The
  /// caller keeps the stored flag intact, so widening past the breakpoint restores
  /// split with no persisted change.
  static func effectiveMode(stored: DiffViewMode, availableWidth: CGFloat) -> DiffViewMode {
    guard stored == .split else { return stored }
    return availableWidth >= inlineBreakpoint ? .split : .unified
  }

  /// Which split presentation to use. Soft-wrap on ⇒ our single-row divergence;
  /// off ⇒ pierre's two h-scroll columns. `.presentation` is the one-line clamp the
  /// phase's no-wrap-slip escape hatch flips: forcing `.wrapSingleRow` unconditionally
  /// ships wrap-split first without a silent drop.
  static func presentation(wrap: Bool) -> SplitPresentation {
    wrap ? .wrapSingleRow : .noWrapTwoColumns
  }

  /// Per-pair row height, ALWAYS `max` of both sides (a nil side reports the bare
  /// line height). Heights are MODE-KEYED: measure split at ≈ half width, never
  /// reuse unified heights (brainstorm `:217-219`). The nil-side buffer contributes
  /// `bareLineHeight` so a one-sided pair still reserves a full row.
  static func rowHeight(leftHeight: CGFloat, rightHeight: CGFloat) -> CGFloat {
    max(leftHeight, rightHeight)
  }

  /// No-wrap content width per side = widest measured line in the VISIBLE window
  /// (not the whole file — brainstorm `:288`) plus the gutter band. The gutter is
  /// EXCLUDED from the scrollable code width so it stays sticky-left: the cell draws
  /// the gutter at a fixed x and translates only the code by `-hScrollOffset`
  /// (reuses the existing `drawPane` gutter/content split). A window with no
  /// measured lines yields the gutter width alone (nothing to scroll).
  static func contentWidth(visibleLineWidths: [CGFloat], gutterWidth: CGFloat) -> CGFloat {
    (visibleLineWidths.max() ?? 0) + gutterWidth
  }

  /// The maximum horizontal scroll offset for a column: how far the code can slide
  /// left before its right edge reaches the pane's right edge. Clamped to `≥ 0` so a
  /// column narrower than its pane never scrolls. `paneWidth` is the on-screen
  /// column width (half the viewport, minus the divider); `contentWidth` is the
  /// scrollable code extent from `contentWidth(visibleLineWidths:gutterWidth:)`.
  static func maxHScrollOffset(contentWidth: CGFloat, paneWidth: CGFloat) -> CGFloat {
    max(0, contentWidth - paneWidth)
  }
}
