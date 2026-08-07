import AppKit
import CoreText
import Testing

@testable import supacode

/// Phase 11 — the search-match background pass (CT-HEADLESS, real `CTLine` geometry
/// via `CoreTextHarness`, asserted as rects + color tokens through `RecordingContext`,
/// never pixels). Covers: one rect per wrapped sub-line via `CTLineGetOffsetForStringIndex`;
/// `.searchMatch` vs the active `.searchCurrent` color from `DiffPalette`; the empty /
/// out-of-range no-op; the 4-pass z-order (`row-tint < word-diff < search < glyphs`,
/// search drawn AFTER word-diff); and the grapheme-snapped clip that never bisects a
/// surrogate / combining sequence.
@MainActor
struct SearchMatchLayerTests {
  private var font: NSFont { CoreTextHarness.font }
  private var matchColor: CGColor { DiffPalette.shared.searchMatch.cgColor }
  private var activeColor: CGColor { DiffPalette.shared.searchCurrent.cgColor }
  private var colors: SearchMatchLayer.Colors { .init(match: matchColor, active: activeColor) }

  private func subLine(_ content: NSString, originY: CGFloat = 100) -> WrappedSubLine {
    WrappedSubLine(
      line: CoreTextHarness.ctLine(content), origin: CGPoint(x: 0, y: originY),
      ascent: font.ascender, descent: -font.descender)
  }

  // MARK: - C 13.x single sub-line rect matches the glyph extent

  @Test func singleSubLineRectMatchesGlyphExtent() {
    let content: NSString = "hello world"
    let ctLine = CoreTextHarness.ctLine(content)
    let xStart = CTLineGetOffsetForStringIndex(ctLine, 6, nil)  // "world" starts at index 6
    let xEnd = CTLineGetOffsetForStringIndex(ctLine, 11, nil)
    let sub = WrappedSubLine(
      line: ctLine, origin: CGPoint(x: 0, y: 100), ascent: font.ascender, descent: -font.descender)
    let recording = RecordingContext()

    SearchMatchLayer.paint(
      SearchMatchLayer.LineMatches(content: content, ranges: [6..<11], active: nil),
      subLines: [sub], colors: colors, scale: 2, in: recording)

    #expect(recording.fills.count == 1)
    let rect = recording.fills[0]
    #expect(abs(rect.minX - min(xStart, xEnd)) < 1)
    #expect(abs(rect.width - abs(xEnd - xStart)) < 1)
    #expect(abs(rect.height - (font.ascender - font.descender)) < 1)
  }

  // MARK: - C 13.x active match uses `.searchCurrent`, others `.searchMatch`

  @Test func activeMatchUsesSearchCurrentColor() {
    let content: NSString = "hello world"
    let sub = subLine(content)
    let recording = RecordingContext()

    SearchMatchLayer.paint(
      SearchMatchLayer.LineMatches(content: content, ranges: [0..<5, 6..<11], active: 6..<11),
      subLines: [sub], colors: colors, scale: 2, in: recording)

    let colored = recording.filledRects
    #expect(colored.count == 2)
    // First range (0..<5) is non-active → dim `.searchMatch` (alpha 0.35).
    #expect(abs(colored[0].color.alpha - 0.35) < 0.01)
    // Second range (6..<11) is the active nav match → `.searchCurrent` (alpha 0.55).
    #expect(abs(colored[1].color.alpha - 0.55) < 0.01)
  }

  // MARK: - C 13.x per-wrapped-sub-line rects

  @Test func perWrappedSubLineRects() {
    let content: NSString = String(repeating: "a", count: 40) as NSString
    let width = CoreTextHarness.advance * 10  // force several wrapped sub-lines
    let wrapped = CoreTextHarness.wrapped(content, width: width)
    let subLines = WrappedSubLine.lines(
      from: wrapped, font: font, origin: .zero, rowHeight: CoreTextHarness.lineHeight, scale: 2)
    #expect(subLines.count >= 2)
    let recording = RecordingContext()

    // A single match spanning the whole (wrapped) line → exactly ONE rect per
    // sub-line, each clipped to its own `CTLineGetStringRange`.
    SearchMatchLayer.paint(
      SearchMatchLayer.LineMatches(content: content, ranges: [0..<40], active: nil),
      subLines: subLines, colors: colors, scale: 2, in: recording)

    #expect(recording.fills.count == subLines.count)
    #expect(recording.fills.allSatisfy { $0.width > 0 })
  }

  // MARK: - C 13.x empty / out-of-range no-op

  @Test func emptyRangesNoFill() {
    let recording = RecordingContext()
    SearchMatchLayer.paint(
      SearchMatchLayer.LineMatches(content: "hello", ranges: [], active: nil),
      subLines: [subLine("hello")], colors: colors, scale: 2, in: recording)
    #expect(recording.fills.isEmpty)
    #expect(recording.events.isEmpty)  // not even a setFillColor
  }

  @Test func rangeOutsideSubLineNoRect() {
    let recording = RecordingContext()
    // "hello" is [0,5); a range at [10,15) never intersects the sub-line.
    SearchMatchLayer.paint(
      SearchMatchLayer.LineMatches(content: "hello", ranges: [10..<15], active: nil),
      subLines: [subLine("hello")], colors: colors, scale: 2, in: recording)
    #expect(recording.fills.isEmpty)
  }

  // MARK: - E 3.1 / S4 four-pass z-order (search AFTER word-diff)

  @Test func searchLayerZOrderAfterWordDiff() {
    // P11 owns the 4th pass: search slots between word-diff and glyphs. The ordered
    // pass list is authoritative (⚠️ note — Phase 5 prose disagrees; Phase 11 wins).
    #expect(DiffRowLayer.drawOrder == [.rowTint, .wordDiff, .search, .glyphs])

    let palette = DiffPalette.shared
    let gutter = GutterRenderer(metrics: CoreTextHarness.metrics, scale: 2, palette: palette)
    let content: NSString = "abcdef"
    let sub = subLine(content, originY: 20)
    let recording = RecordingContext()

    // Drive every pass in the ENUM's declared order so the recording reflects
    // `DiffRowLayer.drawOrder` — the search band must be recorded AFTER word-diff.
    for layer in DiffRowLayer.drawOrder {
      switch layer {
      case .rowTint:
        gutter.draw(
          row: LineRowGeometry(rowRect: CGRect(x: 0, y: 0, width: 200, height: 20), barX: 4),
          origin: .addition, in: recording)
      case .wordDiff:
        WordDiffBackgroundPainter.fill(
          spans: [WordDiff.Span(range: 0..<3)], subLines: [sub],
          color: palette.wordEmphasis(isOld: false).cgColor, scale: 2, in: recording)
      case .search:
        SearchMatchLayer.paint(
          SearchMatchLayer.LineMatches(content: content, ranges: [0..<3], active: 0..<3),
          subLines: [sub],
          colors: .init(match: palette.searchMatch.cgColor, active: palette.searchCurrent.cgColor),
          scale: 2, in: recording)
      case .glyphs:
        break  // CTLineDraw — terminal pass, not a DiffGraphics fill
      }
    }

    // The word-diff fill (alpha 0.18) is recorded BEFORE the active-search fill
    // (alpha 0.55) — so under the active match the last writer is the search color,
    // NOT the word-diff tint.
    let firstWord = recording.filledRects.firstIndex { abs($0.color.alpha - 0.18) < 0.01 }
    let firstSearch = recording.filledRects.firstIndex { abs($0.color.alpha - 0.55) < 0.01 }
    #expect(firstWord != nil)
    #expect(firstSearch != nil)
    if let firstWord, let firstSearch { #expect(firstWord < firstSearch) }
  }

  // MARK: - D §SRCH grapheme-snapped clip never bisects a glyph

  @Test func searchGraphemeMatchPaintClipSnapped() {
    // "x" + grin (a surrogate PAIR, u16 2) + "y" → indices: 0=x, 1..3=grin, 3=y.
    let content = "x\(UnicodeFixtures.grin)y" as NSString
    #expect(content.length == 4)
    let ctLine = CoreTextHarness.ctLine(content)
    let sub = WrappedSubLine(
      line: ctLine, origin: CGPoint(x: 0, y: 100), ascent: font.ascender, descent: -font.descender)
    let recording = RecordingContext()

    // A range that STARTS on the low surrogate of the grin (index 2) — snapping must
    // expand the clip OUT to the whole grin cluster [1,3) so the rect never bisects it.
    SearchMatchLayer.paint(
      SearchMatchLayer.LineMatches(content: content, ranges: [2..<3], active: nil),
      subLines: [sub], colors: colors, scale: 2, in: recording)

    #expect(recording.fills.count == 1)
    let rect = recording.fills[0]
    let xGrinStart = CTLineGetOffsetForStringIndex(ctLine, 1, nil)  // composed-sequence start
    let xGrinEnd = CTLineGetOffsetForStringIndex(ctLine, 3, nil)  // composed-sequence end
    #expect(abs(rect.minX - min(xGrinStart, xGrinEnd)) < 1)
    #expect(abs(rect.width - abs(xGrinEnd - xGrinStart)) < 1)  // the WHOLE grapheme, never half
    #expect(rect.width > 0)
  }
}
