import AppKit
import CoreText

/// The Phase-11 search-match background pass — the **third** z-ordered draw pass in a
/// rendered diff row: `row-tint < word-diff < search < glyphs` (see `DiffRowLayer` and
/// the ⚠️ Deepening note — Phase 5 prose lumps search with the row-tint; the plan
/// index is authoritative and draws search ABOVE word-diff so an active match on a
/// changed token stays visible instead of being masked by the word-diff tint).
///
/// Stateless (a caseless `enum`, per CLAUDE.md), mirroring `WordDiffBackgroundPainter`:
/// it paints one rect per wrapped sub-line via `CTLineGetOffsetForStringIndex`, clips
/// each range to the sub-line's `CTLineGetStringRange`, and — because Core Text's
/// `CTLineDraw` fills glyph runs only and ignores `NSAttributedString.Key.background`
/// — hand-fills BEFORE the glyphs. It draws through `some DiffGraphics` so a headless
/// test records rects into a `RecordingContext` instead of sampling pixels; `CGContext`
/// conforms, so the live path is a zero-cost conformance. It never touches the syntax
/// foreground or the word-diff pass.
@MainActor
enum SearchMatchLayer {
  /// The search matches on ONE visible physical line: the line's content (whose UTF-16
  /// indices match the sub-lines' `CTLineGetStringRange`), every match `ranges`
  /// (line-relative UTF-16), and which one is the current-nav `active` match.
  struct LineMatches {
    var content: NSString
    var ranges: [Range<Int>]
    var active: Range<Int>?
  }

  /// The two search tints: `match` for every hit (dim), `active` for the current-nav
  /// hit (accent). Sourced from `DiffPalette.searchMatch` / `.searchCurrent`.
  struct Colors {
    var match: CGColor
    var active: CGColor
  }

  /// Fill `matches` behind `subLines`, snapped to the backing pixel grid at `scale`.
  /// The active range is filled with `colors.active`; every other range with
  /// `colors.match`. No ranges ⇒ no fill (not even a `setFillColor`).
  ///
  /// The clip of each range to a sub-line is snapped OUT to composed-character
  /// boundaries (`rangeOfComposedCharacterSequence`) so a rect never bisects a
  /// surrogate pair / combining sequence (Phase 3 grapheme rule).
  static func paint(
    _ matches: LineMatches,
    subLines: [WrappedSubLine],
    colors: Colors,
    scale: CGFloat,
    in ctx: some DiffGraphics
  ) {
    let content = matches.content
    guard !matches.ranges.isEmpty, !subLines.isEmpty else { return }
    for range in matches.ranges {
      ctx.setFillColor(range == matches.active ? colors.active : colors.match)
      for sub in subLines {
        let stringRange = CTLineGetStringRange(sub.line)  // this sub-line's UTF-16 bounds
        let subLow = stringRange.location
        let subHigh = stringRange.location + stringRange.length
        let clipLow = max(range.lowerBound, subLow)
        let clipHigh = min(range.upperBound, subHigh)
        guard clipLow < clipHigh else { continue }  // range doesn't touch this sub-line
        // Snap the clip OUT to composed-character boundaries (kept inside the sub-line)
        // so the rect covers whole graphemes, never half of one.
        let lower = Self.snappedLower(clipLow, in: content, floor: subLow)
        let upper = Self.snappedUpper(clipHigh, in: content, ceiling: subHigh)
        guard lower < upper else { continue }
        let xLower = CTLineGetOffsetForStringIndex(sub.line, lower, nil)
        let xUpper = CTLineGetOffsetForStringIndex(sub.line, upper, nil)
        let rect = CGRect(
          x: sub.origin.x + min(xLower, xUpper),
          y: sub.origin.y - sub.ascent,
          width: abs(xUpper - xLower),
          height: sub.ascent + sub.descent
        )
        ctx.fill(WordDiffBackgroundPainter.snap(rect, scale: scale))
      }
    }
  }

  /// Snap an index DOWN to the start of its composed-character sequence (so a rect
  /// never begins mid-grapheme), clamped to the sub-line's own start.
  private static func snappedLower(_ index: Int, in text: NSString, floor: Int) -> Int {
    guard index > floor, index < text.length else { return index }
    let cluster = text.rangeOfComposedCharacterSequence(at: index)
    return max(cluster.location, floor)
  }

  /// Snap an index UP to the end of its composed-character sequence (so a rect never
  /// ends mid-grapheme), clamped to the sub-line's own end.
  private static func snappedUpper(_ index: Int, in text: NSString, ceiling: Int) -> Int {
    guard index > 0, index < ceiling else { return index }
    let cluster = text.rangeOfComposedCharacterSequence(at: index)
    let snapped = cluster.location == index ? index : NSMaxRange(cluster)
    return min(snapped, ceiling)
  }
}
