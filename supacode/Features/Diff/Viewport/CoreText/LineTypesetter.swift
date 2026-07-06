import AppKit
import CoreText

/// Wraps one code line into visual sub-lines via CoreText and reports the
/// measured height back to the chunk-tree. Pure CoreText — no TextKit, no Swift
/// `String` on the offset path. Results are cached (`CTLineCache`); the viewport
/// writes the height into the tree via `setMeasuredHeight` (O(log n)) and
/// re-anchors (Phase 2). Caseless `enum` — no free functions (CLAUDE.md).
@MainActor
enum LineTypesetter {
  /// Wrapped sub-lines top→bottom plus the total measured height.
  struct Wrapped {
    let ctLines: [CTLine]
    let height: CGFloat
  }

  /// Build ONCE per metrics change. Empty `tabStops` + `defaultTabInterval` ⇒
  /// tab stops at every 2·advance, so a real `\t` in the store advances to the
  /// next stop WITHOUT pre-expanding (copy stays correct). tab-size 2 = pierre
  /// `style.css:778`. LTR base keeps columns / offsets stable under bidi
  /// (brainstorm §Round-3: "force LTR base on code lines").
  static func paragraphStyle(advance: CGFloat) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.tabStops = []  // ⇒ defaultTabInterval governs (stops at 0, 2a, 4a, …)
    style.defaultTabInterval = advance * 2
    style.baseWritingDirection = .leftToRight
    style.lineBreakMode = .byCharWrapping  // measured wrap, not clip
    return style
  }

  /// Plain foreground pass. Phase 4 / 5 layer syntax fg + word-diff bg onto the
  /// SAME string over UTF-16 ranges. Ligatures OFF (`.ligature = 0`) ⇒ offset↔x
  /// stays exact (brainstorm §Round-3).
  static func attributed(_ content: NSString, font: NSFont, style: NSParagraphStyle) -> NSAttributedString {
    NSAttributedString(
      string: content as String,
      attributes: [
        .font: font,
        .paragraphStyle: style,
        .foregroundColor: DiffPalette.shared.codeForeground,
        .ligature: 0,
      ]
    )
  }

  /// Soft-wrap at content-column `width`. `CTTypesetterSuggestLineBreak` returns a
  /// COUNT of chars from `start` that fit (CTTypesetter.h:225); loop until the
  /// whole line is consumed. `width <= 0` ⇒ single line (no-wrap h-scroll, Phase
  /// 8). Each computed break is snapped OUTWARD to a composed-character boundary
  /// so the `max(1, count)` progress guard on a too-narrow column can never split
  /// a surrogate pair / emoji (edge note: "snap first — do not trust the guard").
  static func wrap(_ attributedLine: NSAttributedString, width: CGFloat, lineHeight: CGFloat) -> Wrapped {
    let typesetter = CTTypesetterCreateWithAttributedString(attributedLine)
    let total = attributedLine.length
    if total == 0 {  // empty line still occupies exactly one row
      return Wrapped(ctLines: [CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: 0))], height: lineHeight)
    }
    if width <= 0 {  // no-wrap: one line covering the whole range
      return Wrapped(
        ctLines: [CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: total))],
        height: lineHeight
      )
    }
    let content = attributedLine.string as NSString
    var lines: [CTLine] = []
    var start = 0
    while start < total {
      let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
      var end = min(total, start + max(1, count))  // guarantee progress on a too-narrow column
      end = snapForward(content, offset: end)  // never split a grapheme cluster
      if end <= start { end = min(total, start + 1) }  // absolute progress guard
      lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: end - start)))
      start = end
    }
    return Wrapped(ctLines: lines, height: CGFloat(max(1, lines.count)) * lineHeight)
  }

  /// Snap a break offset OUTWARD to the end of the composed-character sequence it
  /// falls inside, so a wrapped sub-line boundary never bisects a cluster.
  private static func snapForward(_ string: NSString, offset: Int) -> Int {
    guard offset > 0, offset < string.length else { return offset }
    let range = string.rangeOfComposedCharacterSequence(at: offset)
    return range.location == offset ? offset : NSMaxRange(range)  // extend to the cluster END
  }
}
