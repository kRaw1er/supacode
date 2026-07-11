import AppKit
import CoreText
import Testing

@testable import supacode

/// FULL-FIDELITY render digest golden (CT-HEADLESS) — the native mirror of pierre
/// `packages/diffs/test/FileRenderer.test.ts` "render TypeScript code to AST matching
/// snapshot", the single full-fidelity snapshot pierre's suite centers on.
///
/// Our other goldens (`RowModelProjection`) are "never pixels" and deliberately OMIT
/// the rendered text + tokens, so a corrupted rendered line / token for a REAL file
/// was guarded only by two tiny hand-asserts in `DiffSyntaxRenderTests`. This digest
/// closes that gap: a realistic ~14-line Swift file is assembled through the REAL
/// `ChunkTreeBuilder`, tokenized through the REAL `StyleRunCompositor`, rendered by
/// `LineRowView`, and serialized per rendered row as
/// `rowIndex · class · old/new · "content" · [tokenRange:capture#bg]` — so a theme /
/// tokenizer / projection regression churns exactly this one golden (review it line
/// by line, do not blindly regenerate). Content is read back from the VIEW
/// (`visibleRowTexts`); the tokens are the compositor's real output; and one concrete
/// end-to-end `CTRun`-foreground assert proves a token's color actually reaches the
/// drawn glyphs.
@MainActor
struct DiffRenderDigestGoldenTests {

  // MARK: - Fixture: a realistic ~14-line Swift file with one 1:1 replacement

  /// The hunk lines in git order. One line (`count = count + 1` → `count += 1`) is
  /// replaced; every other line is aligned context, so old/new numbering stays 1:1.
  private func fixtureHunk() -> DiffHunk {
    DiffFixture.hunk([
      DiffFixture.line(.context, old: 1, new: 1, "import Foundation"),
      DiffFixture.line(.context, old: 2, new: 2, ""),
      DiffFixture.line(.context, old: 3, new: 3, "struct Counter {"),
      DiffFixture.line(.context, old: 4, new: 4, "  var count = 0"),
      DiffFixture.line(.context, old: 5, new: 5, ""),
      DiffFixture.line(.context, old: 6, new: 6, "  mutating func increment() {"),
      DiffFixture.line(.deletion, old: 7, new: nil, "    count = count + 1"),
      DiffFixture.line(.addition, old: nil, new: 7, "    count += 1"),
      DiffFixture.line(.context, old: 8, new: 8, "  }"),
      DiffFixture.line(.context, old: 9, new: 9, ""),
      DiffFixture.line(.context, old: 10, new: 10, "  func describe() -> String {"),
      DiffFixture.line(.context, old: 11, new: 11, "    return \"count: \\(count)\""),
      DiffFixture.line(.context, old: 12, new: 12, "  }"),
      DiffFixture.line(.context, old: 13, new: 13, "}"),
    ])
  }

  private func fixtureTree() -> ChunkTree {
    ChunkTreeFixture.files([
      ChunkTreeFixture.FileSpec(file: DiffFixture.file(path: "Counter.swift"), hunks: [fixtureHunk()])
    ])
  }

  // MARK: - Tokens (through the REAL compositor)

  private func fg(_ lower: Int, _ upper: Int, _ capture: String) -> StyleRun {
    StyleRun(range: lower..<upper, capture: capture)
  }

  private func span(_ lower: Int, _ upper: Int) -> WordDiff.Span { WordDiff.Span(range: lower..<upper) }

  private func compose(
    _ length: Int, _ foreground: [StyleRun], wordDiff: [WordDiff.Span] = [], background: StyleColor = .wordDiffAddition
  ) -> [StyleRun] {
    StyleRunCompositor.composite(
      length: length, foreground: foreground, wordDiff: wordDiff, defaultForeground: "", wordDiffBackground: background)
  }

  /// New-side runs keyed by 1-based new line number (read for context/addition rows).
  private func newStyleRuns() -> [Int: [StyleRun]] {
    [
      // "import Foundation" — keyword + type, no word-diff.
      1: compose(17, [fg(0, 6, "keyword"), fg(7, 17, "type")]),
      // "struct Counter {" — keyword + type.
      3: compose(16, [fg(0, 6, "keyword"), fg(7, 14, "type")]),
      // "  var count = 0" — keyword + property + number.
      4: compose(15, [fg(2, 5, "keyword"), fg(6, 11, "property"), fg(14, 15, "number")]),
      // "    count += 1" — the ADDED line: operator + number UNDER a word-diff bg
      // (orthogonality: syntax fg survives beneath the addition emphasis).
      7: compose(14, [fg(10, 12, "operator"), fg(13, 14, "number")], wordDiff: [span(10, 14)]),
    ]
  }

  /// Old-side runs keyed by 1-based old line number (read for deletion rows).
  private func oldStyleRuns() -> [Int: [StyleRun]] {
    [
      // "    count = count + 1" — the DELETED line: two operators + number under a
      // deletion-side word-diff bg.
      7: compose(
        21, [fg(10, 11, "operator"), fg(18, 19, "operator"), fg(20, 21, "number")],
        wordDiff: [span(10, 21)], background: .wordDiffDeletion)
    ]
  }

  // MARK: - Digest (content from the VIEW, class/numbers from the tree, tokens from the compositor)

  private func renderContext(width: CGFloat) -> LineRowRenderContext {
    LineRowRenderContext(
      metrics: .resolve(),
      rowHeight: ChunkLayoutMetrics.production.lineHeight,
      mode: .unified,
      width: width,
      cache: CTLineCache(),
      palette: .shared,
      styleGeneration: 0,
      syntaxProvider: SyntaxRenderHarness.provider(new: newStyleRuns(), old: oldStyleRuns()),
      oldBlobOID: SyntaxRenderHarness.oldBlobOID,
      newBlobOID: SyntaxRenderHarness.newBlobOID,
      oldQueryName: SyntaxRenderHarness.queryName,
      newQueryName: SyntaxRenderHarness.queryName
    )
  }

  private func classLabel(_ origin: DiffLineOrigin) -> String {
    switch origin {
    case .context: "ctx"
    case .addition: "add"
    case .deletion: "del"
    case .noNewlineMarker: "nonl"
    }
  }

  private func widgetLabel(_ kind: WidgetReuseKind) -> String {
    switch kind {
    case .fileHeader: "fileHeader"
    case .hunkHeader: "hunkHeader"
    case .expander: "expander"
    case .commentThread: "commentThread"
    case .placeholder: "placeholder"
    case .noNewlineMarker: "noNewlineMarker"
    case .plainFallback: "plainFallback"
    }
  }

  /// `[lo..<hi:capture#bg …]` — every composited run, so the golden pins gap-free
  /// coverage, precedence, and coalescing (empty capture ⇒ nothing after the colon).
  private func tokenLabel(_ runs: [StyleRun]?) -> String {
    guard let runs, !runs.isEmpty else { return "[]" }
    let body = runs.map { run in
      let backgroundToken = run.background.map { "#\($0.rawValue)" } ?? ""
      return "\(run.range.lowerBound)..<\(run.range.upperBound):\(run.capture)\(backgroundToken)"
    }
    .joined(separator: " ")
    return "[\(body)]"
  }

  /// Walk every rendered row; read line content back from the configured
  /// `LineRowView` (one per line-segment chunk), pair it with the tree's line
  /// numbers + class and the compositor's tokens for that line.
  private func digest(_ tree: ChunkTree, width: CGFloat) -> String {
    let newRuns = newStyleRuns()
    let oldRuns = oldStyleRuns()
    var viewTextByChunk: [ChunkID: [Int: LineRowView.VisibleRowText]] = [:]
    var out: [String] = []

    var hit = tree.seek(index: 0, mode: .unified)
    while let current = hit {
      switch current.chunk {
      case .widget(let widget):
        out.append("\(current.rowIndex) · widget:\(widgetLabel(widget.reuseKind))")
      case .lineSegment(let segment):
        if viewTextByChunk[current.id] == nil {
          let view = LineRowView()
          view.configure(segment: segment, chunkID: current.id, context: renderContext(width: width))
          var map: [Int: LineRowView.VisibleRowText] = [:]
          for text in view.visibleRowTexts { map[text.localRow] = text }
          viewTextByChunk[current.id] = map
        }
        let row = segment.renderedRows(.unified)[current.localRow]
        let content = viewTextByChunk[current.id]?[current.localRow]?.unified ?? "«\(classLabel(row.origin))»"
        let runs =
          row.origin == .deletion ? row.oldNumber.flatMap { oldRuns[$0] } : row.newNumber.flatMap { newRuns[$0] }
        let old = row.oldNumber.map(String.init) ?? "-"
        let new = row.newNumber.map(String.init) ?? "-"
        out.append(
          "\(current.rowIndex) · \(classLabel(row.origin)) · o\(old)/n\(new) · \"\(content)\" · \(tokenLabel(runs))")
      }
      hit = tree.successor(of: current, mode: .unified)
    }
    return out.joined(separator: "\n") + "\n"
  }

  // MARK: - The golden

  @Test func unifiedRenderDigestMatchesGolden() {
    GoldenText.assert(digest(fixtureTree(), width: 4_000), "renderDigestUnified")
  }

  // MARK: - Concrete end-to-end: a token's color actually reaches the drawn glyphs

  /// Not a tautology on the golden: configure the head-context leaf, pull the FIRST
  /// row's real `CTLine`, and prove the `keyword` token in "import Foundation" renders
  /// the theme keyword color while the surrounding code stays the base foreground —
  /// the "corrupted rendered token" guard, tied to the actual CoreText runs the
  /// viewport draws.
  @Test func firstTokenForegroundReachesTheRenderedCTLine() throws {
    let tree = fixtureTree()
    // The head-context leaf (lines 1..6) — its first rendered row is "import Foundation".
    let headContext = try #require(
      firstLineSegment(tree), "the fixture must produce a line-segment leaf")
    let view = LineRowView()
    view.configure(segment: headContext.segment, chunkID: headContext.id, context: renderContext(width: 4_000))

    #expect(view.firstRowText == "import Foundation")
    let ctLine = try #require(view.firstRowCTLines?.first, "the first row must produce exactly one unwrapped CTLine")
    // No truncation: the single CTLine covers the whole line's UTF-16 length.
    let range = CTLineGetStringRange(ctLine)
    #expect(range.length == ("import Foundation" as NSString).length)

    let keyword = try #require(foreground(ctLine, at: 1), "no foreground on the keyword glyphs")  // inside "import"
    let base = try #require(foreground(ctLine, at: 6), "no foreground on the plain glyphs")  // the space
    #expect(!sameColor(keyword, base), "the highlighted keyword rendered the same color as plain code")
    #expect(sameColor(keyword, HighlightTheme.color(for: "keyword").cgColor), "keyword fg must be the theme color")
    #expect(sameColor(base, DiffPalette.shared.codeForeground.cgColor), "unhighlighted fg must be the base code color")
  }

  /// The first `.lineSegment` chunk in the tree (its id + value), for the CTLine assert.
  private func firstLineSegment(_ tree: ChunkTree) -> (id: ChunkID, segment: LineSegment)? {
    var hit = tree.seek(index: 0, mode: .unified)
    while let current = hit {
      if case .lineSegment(let segment) = current.chunk { return (current.id, segment) }
      hit = tree.successor(of: current, mode: .unified)
    }
    return nil
  }

  // MARK: - CTRun foreground extraction (the `DiffSyntaxRenderTests` bridge, reused)

  /// Foreground of the `CTRun` covering `stringIndex` in one `CTLine`.
  private func foreground(_ ctLine: CTLine, at stringIndex: Int) -> CGColor? {
    let runs = CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? []
    for run in runs {
      let range = CTRunGetStringRange(run)
      if stringIndex >= range.location && stringIndex < range.location + range.length {
        let attrs = CTRunGetAttributes(run) as NSDictionary
        if let nsColor = attrs[NSAttributedString.Key.foregroundColor.rawValue] as? NSColor {
          return nsColor.cgColor
        }
        // CoreText's own key holds a raw `CGColor`; a plain `as? CGColor` is a Swift 6
        // compile error, so gate on the CFTypeID and bridge directly (CLAUDE.md).
        guard let value = attrs[kCTForegroundColorAttributeName as String],
          CFGetTypeID(value as CFTypeRef) == CGColor.typeID
        else { return nil }
        return unsafeDowncast(value as AnyObject, to: CGColor.self)
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
}
