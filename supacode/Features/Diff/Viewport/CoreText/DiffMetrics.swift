import AppKit

/// Resolved rendering metrics for the diff viewer, derived from the system
/// monospaced font (no hardcoded sizes). `lineHeight` is the O(1) fixed height
/// returned from `heightOfRow`. Recomputed on font / appearance change.
///
/// **Relocated here in Phase 3 (⚠️ Deepening note 4 / S8).** `DiffMetrics` used to
/// live inside `DiffCellView.swift`; it is a KEPT (relocated) type — the new
/// CoreText render layer (Phase 2 viewport + Phase 3 typesetter) and the
/// still-compiling old `DiffTableController` both resolve against this one
/// definition. The type name is deliberately unchanged so Phase 13's later
/// `git rm` of `DiffCellView.swift` stays a no-op reference-wise. Do not rename it.
struct DiffMetrics {
  let font: NSFont
  let lineHeight: CGFloat
  let charWidth: CGFloat
  let vPad: CGFloat
  let hPad: CGFloat
  /// Width of one line-number gutter column (old and new each get one).
  let gutterWidth: CGFloat

  static func resolve() -> DiffMetrics {
    let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    let vPad: CGFloat = 1
    let lineHeight = ceil(font.ascender - font.descender + font.leading) + 2 * vPad
    let charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
    return DiffMetrics(
      font: font,
      lineHeight: lineHeight,
      charWidth: max(1, charWidth),
      vPad: vPad,
      hPad: 6,
      gutterWidth: charWidth * 5 + 8
    )
  }

  /// Returns a copy whose gutter is wide enough for `maxLineNumber` (keeps the
  /// code column aligned as numbers grow past 9,999). The tree viewport resolves
  /// the largest rendered line number from the visible window directly, so this
  /// takes a scalar (the flat `[DiffRow]` overload retired in the Phase-13 swap).
  func withGutter(forMaxLineNumber maxNumber: Int) -> DiffMetrics {
    let digits = max(3, String(maxNumber).count)
    let width = charWidth * CGFloat(digits) + 10
    return DiffMetrics(
      font: font,
      lineHeight: lineHeight,
      charWidth: charWidth,
      vPad: vPad,
      hPad: hPad,
      gutterWidth: width
    )
  }
}
