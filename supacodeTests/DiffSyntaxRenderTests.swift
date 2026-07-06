import AppKit
import CoreText
import Testing

@testable import supacode

/// RENDER-CORRECTNESS (CT-HEADLESS) — the seam that was MISSING and let syntax
/// highlighting ship completely dead. The reducer computed `DiffDocument.old/newStyleRuns`
/// and stored them in state, but NOTHING in the render path read them: `LineRowView`
/// typeset plain glyphs, so not a single file highlighted. These tests assert on the
/// ACTUAL `CTRun` foreground the viewport draws — no app launch, no screenshot — so
/// the seam can never silently break again.
///
/// `syntaxRunColorsTheTokenInTheRenderedCTLine` FAILS on the pre-fix code (the token
/// renders the same base color as the rest of the line) and passes once the runs are
/// applied.
@MainActor
struct DiffSyntaxRenderTests {
  private func context(newStyleRuns: [Int: [StyleRun]] = [:], oldStyleRuns: [Int: [StyleRun]] = [:])
    -> LineRowRenderContext
  {
    LineRowRenderContext(
      metrics: .resolve(),
      rowHeight: ChunkLayoutMetrics.production.lineHeight,
      mode: .unified,
      width: 4000,  // wide ⇒ one unwrapped CTLine ⇒ line-relative offsets are string offsets
      cache: CTLineCache(),
      palette: .shared,
      styleGeneration: 0,
      oldStyleRuns: oldStyleRuns,
      newStyleRuns: newStyleRuns
    )
  }

  private func contextSegment(_ content: String) -> LineSegment {
    LineSegment(
      hunkID: HunkID(fileID: "f", index: 0),
      lines: [DiffLine(origin: .context, oldLineNumber: 1, newLineNumber: 1, content: content, noNewlineAtEof: false)],
      window: 0..<1,
      classification: .context
    )
  }

  /// Foreground of the `CTRun` covering `stringIndex` in one `CTLine`.
  private func foreground(_ ctLine: CTLine, at stringIndex: Int) -> CGColor? {
    let runs = CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? []
    for run in runs {
      let range = CTRunGetStringRange(run)
      if stringIndex >= range.location && stringIndex < range.location + range.length {
        let attrs = CTRunGetAttributes(run) as NSDictionary
        // `NSMutableAttributedString.foregroundColor` rides the "NSColor" key as an
        // NSColor; CoreText's own key is CTForegroundColor (a CGColor). Accept either.
        if let nsColor = attrs[NSAttributedString.Key.foregroundColor.rawValue] as? NSColor {
          return nsColor.cgColor
        }
        return attrs[kCTForegroundColorAttributeName as String].flatMap { $0 as? CGColor }
      }
    }
    return nil
  }

  private func sameColor(_ lhs: CGColor?, _ rhs: CGColor?) -> Bool {
    guard let lhs, let rhs, let space = CGColorSpace(name: CGColorSpace.sRGB),
      let lhsSRGB = lhs.converted(to: space, intent: .defaultIntent, options: nil),
      let rhsSRGB = rhs.converted(to: space, intent: .defaultIntent, options: nil),
      let lhsParts = lhsSRGB.components, let rhsParts = rhsSRGB.components, lhsParts.count == rhsParts.count
    else { return false }
    return zip(lhsParts, rhsParts).allSatisfy { abs($0 - $1) < 0.02 }
  }

  // MARK: - the missing seam: styleRuns in state must reach the drawn CTLine

  @Test func syntaxRunColorsTheTokenInTheRenderedCTLine() throws {
    // "let x = 1" with "let" (UTF-16 0..<3) highlighted as a keyword.
    let view = LineRowView()
    view.configure(
      segment: contextSegment("let x = 1"),
      chunkID: ChunkID(raw: 1),
      context: context(newStyleRuns: [1: [StyleRun(range: 0..<3, capture: "keyword")]])
    )
    let ctLine = try #require(view.firstRowCTLines?.first, "the row must produce a CTLine")

    let tokenColor = try #require(foreground(ctLine, at: 1), "no foreground on the keyword glyphs")  // inside "let"
    let baseColor = try #require(foreground(ctLine, at: 6), "no foreground on the plain glyphs")  // inside "= 1"

    #expect(
      !sameColor(tokenColor, baseColor),
      "the highlighted token rendered the SAME foreground as the surrounding code — styleRuns never reached the CTLine")
    #expect(
      sameColor(tokenColor, HighlightTheme.color(for: "keyword").cgColor), "token fg must be the theme keyword color")
    #expect(
      sameColor(baseColor, DiffPalette.shared.codeForeground.cgColor), "unhighlighted fg must be the base code color")
  }

  // MARK: - control: a line with no runs is one uniform foreground

  @Test func plainLineWithoutStyleRunsHasUniformForeground() throws {
    let view = LineRowView()
    view.configure(segment: contextSegment("let x = 1"), chunkID: ChunkID(raw: 1), context: context())
    let ctLine = try #require(view.firstRowCTLines?.first)
    #expect(
      sameColor(foreground(ctLine, at: 1), foreground(ctLine, at: 6)),
      "with no styleRuns the whole line must be one uniform base foreground")
  }

  // MARK: - multiple tokens on one line each get their own color

  @Test func multipleRunsEachColorTheirOwnRange() throws {
    // "func f()" — "func" (0..<4) keyword, "f" (5..<6) a function name.
    let view = LineRowView()
    view.configure(
      segment: contextSegment("func f()"),
      chunkID: ChunkID(raw: 1),
      context: context(newStyleRuns: [
        1: [StyleRun(range: 0..<4, capture: "keyword"), StyleRun(range: 5..<6, capture: "function")]
      ])
    )
    let ctLine = try #require(view.firstRowCTLines?.first)
    let keyword = try #require(foreground(ctLine, at: 0))  // "func"
    let function = try #require(foreground(ctLine, at: 5))  // "f"
    let punctuation = try #require(foreground(ctLine, at: 6))  // "(" — no run ⇒ base
    #expect(sameColor(keyword, HighlightTheme.color(for: "keyword").cgColor))
    #expect(sameColor(function, HighlightTheme.color(for: "function").cgColor))
    #expect(sameColor(punctuation, DiffPalette.shared.codeForeground.cgColor))
  }
}
