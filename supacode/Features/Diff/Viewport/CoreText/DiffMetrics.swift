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

  /// Returns a copy whose gutter is wide enough for the largest line number in
  /// `rows` (keeps the code column aligned as numbers grow past 9,999).
  func withGutter(for rows: [DiffRow]) -> DiffMetrics {
    var maxNumber = 0
    for row in rows {
      switch row {
      case .line(let line):
        maxNumber = max(maxNumber, line.oldLineNumber ?? 0, line.newLineNumber ?? 0)
      case .splitLine(_, let old, let new):
        maxNumber = max(maxNumber, old?.oldLineNumber ?? 0, new?.newLineNumber ?? 0)
      case .plainFallback(let number, _):
        maxNumber = max(maxNumber, number)
      default:
        break
      }
    }
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
