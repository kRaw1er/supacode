import AppKit
import CoreText
import Testing

@testable import supacode

/// Phase 5 — the hand-drawn word-diff background pass (CT-HEADLESS, real `CTLine`
/// geometry via `CoreTextHarness`, asserted as rects + tokens through
/// `RecordingContext`, never pixels). Covers per-run bidi-safe rects, wrapped
/// sub-line intersection, the empty / out-of-range no-op, the 3-pass z-order, and
/// the async word-diff arrival that must NOT re-typeset the CTLine.
@MainActor
struct WordDiffBackgroundPainterTests {
  private var font: NSFont { CoreTextHarness.font }
  private var fillColor: CGColor { NSColor.systemGreen.cgColor }

  private func subLine(_ content: NSString, originY: CGFloat = 100) -> WrappedSubLine {
    WrappedSubLine(
      line: CoreTextHarness.ctLine(content), origin: CGPoint(x: 0, y: originY),
      ascent: font.ascender, descent: -font.descender)
  }

  // MARK: - C 5.11 single-run rect matches the glyph extent

  @Test func singleRunRectMatchesGlyphExtent() {
    let ctLine = CoreTextHarness.ctLine("hello world")
    let xStart = CTLineGetOffsetForStringIndex(ctLine, 0, nil)
    let xFive = CTLineGetOffsetForStringIndex(ctLine, 5, nil)
    let sub = WrappedSubLine(
      line: ctLine, origin: CGPoint(x: 0, y: 100), ascent: font.ascender, descent: -font.descender)
    let recording = RecordingContext()
    WordDiffBackgroundPainter.fill(
      spans: [WordDiff.Span(range: 0..<5)], subLines: [sub], color: fillColor, scale: 2, in: recording)
    #expect(recording.fills.count == 1)
    let rect = recording.fills[0]
    #expect(abs(rect.minX - min(xStart, xFive)) < 1)
    #expect(abs(rect.width - abs(xFive - xStart)) < 1)
    #expect(abs(rect.height - (font.ascender - font.descender)) < 1)
  }

  // MARK: - C 5.12 wrapped sub-line intersection

  @Test func wrappedSubLineIntersection() {
    let content: NSString = String(repeating: "a", count: 40) as NSString
    let width = CoreTextHarness.advance * 10  // force several wrapped sub-lines
    let wrapped = CoreTextHarness.wrapped(content, width: width)
    let subLines = WrappedSubLine.lines(
      from: wrapped, font: font, origin: .zero, rowHeight: CoreTextHarness.lineHeight, scale: 2)
    #expect(subLines.count >= 2)
    let recording = RecordingContext()
    // A span across the whole (wrapped) line → exactly ONE rect per sub-line, each
    // clipped to its own `CTLineGetStringRange`.
    WordDiffBackgroundPainter.fill(
      spans: [WordDiff.Span(range: 0..<40)], subLines: subLines, color: fillColor, scale: 2, in: recording)
    #expect(recording.fills.count == subLines.count)
    #expect(recording.fills.allSatisfy { $0.width > 0 })
  }

  // MARK: - D §5 / C 5.13 bidi per-run rects

  @Test func bidiPerRunBgRects() {
    // LTR base (Phase 3 paragraph style), a logical span across an LTR↔RTL boundary.
    let ctLine = CoreTextHarness.ctLine(UnicodeFixtures.bidiAssign as NSString)  // "let שלום = 1"
    let runs = (CTLineGetGlyphRuns(ctLine) as? [CTRun]) ?? []
    #expect(runs.count >= 2)  // bidi level changes force multiple runs
    let sub = WrappedSubLine(
      line: ctLine, origin: CGPoint(x: 0, y: 100), ascent: font.ascender, descent: -font.descender)
    let recording = RecordingContext()
    let length = (UnicodeFixtures.bidiAssign as NSString).length
    WordDiffBackgroundPainter.fill(
      spans: [WordDiff.Span(range: 0..<length)], subLines: [sub], color: fillColor, scale: 2, in: recording)
    // One rect per intersected CTRun — NOT a single start/end-x rect for the span.
    #expect(recording.fills.count == runs.count)
    #expect(recording.fills.allSatisfy { $0.width >= 0 })
  }

  @Test func perRunRectsNotSingleStartEndX() {
    let ctLine = CoreTextHarness.ctLine(UnicodeFixtures.bidiAssign as NSString)
    let runs = (CTLineGetGlyphRuns(ctLine) as? [CTRun]) ?? []
    let sub = WrappedSubLine(
      line: ctLine, origin: CGPoint(x: 0, y: 100), ascent: font.ascender, descent: -font.descender)
    let recording = RecordingContext()
    let length = (UnicodeFixtures.bidiAssign as NSString).length
    WordDiffBackgroundPainter.fill(
      spans: [WordDiff.Span(range: 0..<length)], subLines: [sub], color: fillColor, scale: 2, in: recording)
    // A single start/end-x implementation would produce exactly ONE rect; per-run
    // offsets produce one per run (> 1 for a bidi line). `left = min(x0,x1)`,
    // `width = abs(x1-x0) >= 0`.
    #expect(recording.fills.count > 1)
    #expect(recording.fills.count == runs.count)
    #expect(recording.fills.allSatisfy { $0.width >= 0 })
  }

  // MARK: - C 5.14 empty / out-of-range no-op

  @Test func emptySpansNoFill() {
    let recording = RecordingContext()
    WordDiffBackgroundPainter.fill(
      spans: [], subLines: [subLine("hello")], color: fillColor, scale: 2, in: recording)
    #expect(recording.fills.isEmpty)
    #expect(recording.events.isEmpty)  // not even a setFillColor
  }

  @Test func spanOutsideSubRangeNoRect() {
    let recording = RecordingContext()
    // "hello" is [0,5); a span at [10,15) never intersects the sub-line.
    WordDiffBackgroundPainter.fill(
      spans: [WordDiff.Span(range: 10..<15)], subLines: [subLine("hello")], color: fillColor, scale: 2, in: recording)
    #expect(recording.fills.isEmpty)
  }

  // MARK: - E 3.1 / C 5.15 three-pass z-order

  @Test func drawOrderRowtintWorddiffText() {
    // P5 shipped three passes; P11 inserts its `.search` band between wordDiff and
    // glyphs (⚠️ z-order: search draws AFTER word-diff). Glyphs are the terminal,
    // non-fill pass.
    #expect(DiffRowLayer.drawOrder == [.rowTint, .wordDiff, .search, .glyphs])

    let palette = DiffPalette.shared
    let gutter = GutterRenderer(metrics: CoreTextHarness.metrics, scale: 2, palette: palette)
    let sub = subLine("abcdef", originY: 20)
    let recording = RecordingContext()

    // Drive the passes in the ENUM's declared order (not a hand-order) so the
    // recording reflects `DiffRowLayer.drawOrder`.
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
        break  // Phase 5 row draws no search band (Phase 11 owns that pass)
      case .glyphs:
        break  // CTLineDraw — terminal pass, not a DiffGraphics fill
      }
    }

    // The row-tint fill (alpha 0.12) is recorded BEFORE the word-diff fill (alpha 0.18).
    let firstTint = recording.filledRects.firstIndex { abs($0.color.alpha - 0.12) < 0.01 }
    let firstWord = recording.filledRects.firstIndex { abs($0.color.alpha - 0.18) < 0.01 }
    #expect(firstTint != nil)
    #expect(firstWord != nil)
    if let firstTint, let firstWord { #expect(firstTint < firstWord) }
  }

  // MARK: - E 3.3 async word-diff arrival does not re-typeset

  @Test func asyncArrivalNoReTypeset() {
    let cache = CTLineCache()
    let view = LineRowView()
    let segment = LineSegment(
      hunkID: HunkID(fileID: "f", index: 0),
      lines: [
        DiffLine(origin: .deletion, oldLineNumber: 1, newLineNumber: nil, content: "let x = 1", noNewlineAtEof: false),
        DiffLine(origin: .addition, oldLineNumber: nil, newLineNumber: 1, content: "let x = 2", noNewlineAtEof: false),
      ],
      window: 0..<2,
      classification: .change
    )
    func context(wordDiffVersion: Int) -> LineRowRenderContext {
      LineRowRenderContext(
        metrics: .resolve(), rowHeight: ChunkLayoutMetrics.production.lineHeight, mode: .unified, width: 800,
        cache: cache, palette: .shared, styleGeneration: 0, wordDiffEnabled: true, syntaxVersion: 0,
        wordDiffVersion: wordDiffVersion)
    }
    view.configure(segment: segment, chunkID: ChunkID(raw: 1), context: context(wordDiffVersion: 0))
    let typesetCount = cache.count
    #expect(typesetCount > 0)
    // Word-diff "arrives" → bump ONLY `wordDiffVersion` (content / width / style
    // unchanged). Because `wordDiffVersion` is excluded from the CTLine key, the
    // glyphs are recomposited/redrawn but NOT re-typeset — the cache does not grow.
    view.configure(segment: segment, chunkID: ChunkID(raw: 1), context: context(wordDiffVersion: 1))
    #expect(cache.count == typesetCount)
  }
}
