import AppKit
import CoreText
import Testing

@testable import supacode

/// Phase 3 — the CoreText soft-wrap / tab / offset↔x layer (CT-HEADLESS off the
/// `CoreTextHarness`; no window). Rows 3.5–3.8 + the D-matrix CoreText regressions
/// (cluster-safe wrap, surrogate/CJK offset↔x, tab-across-emoji, LTR base).
@MainActor
struct LineTypesetterTests {
  // MARK: - 3.5 deterministic break points at a fixed monospace column width

  @Test func wrapBreakPointsDeterministic() {
    let advance = CoreTextHarness.advance
    let width = advance * 10 + 2  // exactly 10 ASCII glyphs fit, 11 do not
    let content = String(repeating: "a", count: 25) as NSString

    let first = CoreTextHarness.wrapped(content, width: width)
    let second = CoreTextHarness.wrapped(content, width: width)
    let lengthsA = first.ctLines.map { CTLineGetStringRange($0).length }
    let lengthsB = second.ctLines.map { CTLineGetStringRange($0).length }

    #expect(lengthsA == [10, 10, 5])
    #expect(lengthsA == lengthsB)  // deterministic
    #expect(lengthsA.reduce(0, +) == 25)
  }

  // MARK: - 3.6 a tab advances to 2×advance (real \t stays in the store)

  @Test func tabAdvanceIsTwoAdvances() {
    let advance = CoreTextHarness.advance
    let line = CoreTextHarness.ctLine("\tX")  // real tab retained, NOT pre-expanded
    let offsetOfX = CTLineGetOffsetForStringIndex(line, 1, nil)  // x of the "X" after the tab
    #expect(abs(offsetOfX - 2 * advance) < 0.5)  // tab jumped to the first stop (2·advance)
  }

  // MARK: - 3.7 offset↔x round-trips at a boundary

  @Test func utf16OffsetToXRoundTrip() {
    let line = CoreTextHarness.ctLine("abcdef")
    for index in 0...6 {
      let offset = CTLineGetOffsetForStringIndex(line, index, nil)
      let resolved = CTLineGetStringIndexForPosition(line, CGPoint(x: offset, y: 0))
      #expect(resolved == index)
    }
  }

  // MARK: - 3.8 empty line is one sub-line; width<=0 is a single no-wrap line

  @Test func emptyLineIsOneSubLineAndWidthLEZeroSingleLine() {
    let empty = CoreTextHarness.wrapped("", width: 100)
    #expect(empty.ctLines.count == 1)
    #expect(empty.height == CoreTextHarness.lineHeight)

    let long = String(repeating: "abcdefghij ", count: 40) as NSString
    let noWrapZero = CoreTextHarness.wrapped(long, width: 0)
    #expect(noWrapZero.ctLines.count == 1)
    let noWrapNeg = CoreTextHarness.wrapped(long, width: -5)
    #expect(noWrapNeg.ctLines.count == 1)
  }

  // MARK: - wrap never splits a grapheme cluster (1-column progress guard)

  @Test func wrapNeverSplitsCluster() {
    let content = "a\u{1F600}b" as NSString  // "a😀b" — 😀 spans units 1..<3
    let wrapped = CoreTextHarness.wrapped(content, width: CoreTextHarness.advance)  // 1-column width
    var boundaries: Set<Int> = []
    for line in wrapped.ctLines {
      let range = CTLineGetStringRange(line)
      boundaries.insert(range.location)
      boundaries.insert(range.location + range.length)
    }
    // No sub-line boundary lands inside the surrogate pair (offset 2).
    #expect(!boundaries.contains(2))
    // Each boundary is a composed-character-sequence edge.
    for boundary in boundaries where boundary > 0 && boundary < content.length {
      #expect(content.rangeOfComposedCharacterSequence(at: boundary).location == boundary)
    }
  }

  // MARK: - offset↔x round-trips across a surrogate pair and a CJK glyph

  @Test func utf16OffsetToXRoundTripSurrogateAndCJK() {
    // A caret can never sit BETWEEN the two surrogates of 😀 — the visual
    // midpoint resolves to a cluster edge (0 or 2), never the interior index 1.
    let emoji = CoreTextHarness.ctLine(UnicodeFixtures.grin as NSString)
    let full = CTLineGetOffsetForStringIndex(emoji, 2, nil)
    let midIndex = CTLineGetStringIndexForPosition(emoji, CGPoint(x: full / 2, y: 0))
    #expect(midIndex == 0 || midIndex == 2)
    #expect(midIndex != 1)

    // CJK: offsets are monotonic and round-trip at cluster boundaries — the offset
    // comes from CoreText, never `unit × charWidth`.
    let cjk = CoreTextHarness.ctLine(UnicodeFixtures.cjk as NSString)  // "中文", 2 units
    let offset0 = CTLineGetOffsetForStringIndex(cjk, 0, nil)
    let offset1 = CTLineGetOffsetForStringIndex(cjk, 1, nil)
    let offset2 = CTLineGetOffsetForStringIndex(cjk, 2, nil)
    #expect(offset0 < offset1)
    #expect(offset1 < offset2)
    #expect(CTLineGetStringIndexForPosition(cjk, CGPoint(x: offset1, y: 0)) == 1)
    #expect(CTLineGetStringIndexForPosition(cjk, CGPoint(x: offset2, y: 0)) == 2)
    // A wide CJK glyph is not `1 × advance` — proves x != unit × charWidth.
    #expect(offset1 > CoreTextHarness.advance)
  }

  // MARK: - offset↔x round-trips across a tab AND an emoji in one line

  @Test func tabAcrossEmojiOffsetRoundTrip() {
    let advance = CoreTextHarness.advance
    let line = CoreTextHarness.ctLine(UnicodeFixtures.tabEmoji as NSString)  // "\t😀\tx" — real tabs retained
    // The 😀 (index 1) begins at the first tab stop.
    #expect(abs(CTLineGetOffsetForStringIndex(line, 1, nil) - 2 * advance) < 0.5)
    // Round-trip across the tab + emoji + tab to the trailing "x" (index 4).
    let xOffset = CTLineGetOffsetForStringIndex(line, 4, nil)
    #expect(CTLineGetStringIndexForPosition(line, CGPoint(x: xOffset, y: 0)) == 4)
    // And the emoji cluster start round-trips.
    let emojiOffset = CTLineGetOffsetForStringIndex(line, 1, nil)
    #expect(CTLineGetStringIndexForPosition(line, CGPoint(x: emojiOffset, y: 0)) == 1)
  }

  // MARK: - LTR base (a leading RLO does not flip it)

  @Test func bidiForcesLTRBase() {
    let style = LineTypesetter.paragraphStyle(advance: CoreTextHarness.advance)
    #expect(style.baseWritingDirection == .leftToRight)

    // The attributed string carries the LTR base, so a leading RLO run does not
    // flip the paragraph base (Phase 5 extends the per-CTRun bidi bg rects).
    let attributed = CoreTextHarness.attributed((UnicodeFixtures.rlo + "abc") as NSString)
    let applied = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
    #expect(applied?.baseWritingDirection == .leftToRight)
  }
}
