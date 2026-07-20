import AppKit
import CoreText
import Testing

@testable import supacode

/// CAT 0 — the KEYSTONE integration test. `DiffSyntaxRenderTests` proved the LAST
/// mile (state style-runs → `CTRun` foreground) but did it by HAND-KEYING the runs
/// to the row's line numbers — bypassing the exact seam that ships broken: the
/// `DiffHighlightEngine` buckets runs by **0-based blob line index**, while
/// `LineRowView.syntaxRuns` looks them up by **1-based** `DiffLine.old/newLineNumber`
/// (libgit2). So the dictionary lookups miss for every real row, `syntax` arrives
/// empty, `LineTypesetter` early-outs, and every glyph of every file renders the
/// base `.labelColor` (white in dark mode) — the "all text white" bug.
///
/// These tests drive the REAL engine (`DiffHighlightEngine`, over real tree-sitter)
/// end-to-end into a REAL `LineRowView` through the `SyntaxRunsProvider` pull, and
/// assert the drawn `CTRun` foreground. They resolve the 1-based visible line (the
/// app's coordinate) to the engine's 0-based blob line and are RED on the pre-fix code
/// (the row lookup missed the 0-based key), GREEN
/// once the client speaks 1-based in and out.
@MainActor
struct DiffSyntaxPipelineRenderTests {
  /// A wide, cache-fresh context to typeset one line unwrapped (line-relative
  /// offsets == string offsets), pulling the row's runs SYNCHRONOUSLY from `engine`'s
  /// warmed span cache via `SyntaxRunsProvider.live` — the TRUE pull path the app now
  /// draws through (no reducer push, no hand-keyed map). The new side declares the
  /// blob's OID + grammar query name so `LineRowView`'s 0-based-blob-line pull resolves
  /// straight into the cache the engine just filled.
  private func context(engine: DiffHighlightEngine, input: HighlightBlobInput) -> LineRowRenderContext {
    LineRowRenderContext(
      metrics: .resolve(),
      rowHeight: ChunkLayoutMetrics.production.lineHeight,
      mode: .unified,
      width: 4000,
      cache: CTLineCache(),
      palette: .shared,
      styleGeneration: 0,
      syntaxProvider: .live(engine),
      oldBlobOID: nil,
      newBlobOID: input.blobOID,
      oldQueryName: nil,
      newQueryName: DiffHighlightEngine.grammarQueryName(forPath: input.path)
    )
  }

  /// A single context row carrying `content` at 1-based `newLineNumber` — the SAME
  /// 1-based line number the real diff model + gutter use, so the view's lookup key
  /// is exactly what the app produces.
  private func contextSegment(_ content: String, newLineNumber: Int) -> LineSegment {
    LineSegment(
      hunkID: HunkID(fileID: "f", index: 0),
      lines: [
        DiffLine(
          origin: .context, oldLineNumber: newLineNumber, newLineNumber: newLineNumber, content: content,
          noNewlineAtEof: false)
      ],
      window: 0..<1,
      classification: .context
    )
  }

  /// Render one Swift source line (given its 1-based line number) and return the
  /// foreground of the glyph at `probeOffset` plus the base foreground for comparison.
  /// The row PULLS its runs from `engine`'s already-warmed span cache (via the live
  /// provider) exactly as the app does — this is the seam that shipped broken.
  private func renderedColors(
    _ content: String, newLineNumber: Int, engine: DiffHighlightEngine, input: HighlightBlobInput, probeOffset: Int
  ) throws -> (token: CGColor, base: CGColor) {
    let view = LineRowView()
    view.configure(
      segment: contextSegment(content, newLineNumber: newLineNumber),
      chunkID: ChunkID(raw: UInt64(newLineNumber)),
      context: context(engine: engine, input: input))
    let ctLine = try #require(view.firstRowCTLines?.first, "row \(newLineNumber) must produce a CTLine")
    let token = try #require(
      CTRunColorProbe.foreground(ctLine, at: probeOffset), "no foreground at offset \(probeOffset)")
    let base = DiffPalette.shared.codeForeground.cgColor
    return (token, base)
  }

  // MARK: - the seam DiffSyntaxRenderTests could not see: engine output → drawn CTLine

  /// A one-line Swift file. The engine buckets the `let` keyword under 0-based line
  /// index `0`; the view renders that same source as 1-based `newLineNumber == 1`.
  /// Pre-fix the lookup `newStyleRuns[1]` misses the engine's `[0]` entirely, so the
  /// keyword renders the base color — this asserts it renders a DISTINCT (theme)
  /// color, i.e. the real pipeline colored it.
  @Test func realEngineColorsTheKeywordOnTheRenderedRow() async throws {
    let source = "let alpha = 1\n"
    let input = HighlightBlobInput(blobOID: "kw-1", utf16: DiffFixture.blob(source), path: "Sample.swift")
    // Warm a REAL engine over the 0-based blob line window (line 0 for a one-line file),
    // filling the span cache the view then pulls from.
    let engine = DiffHighlightEngine()
    let warmed = await engine.styleRuns(for: input, visibleLines: 0..<1)
    #expect(!warmed.values.flatMap { $0 }.isEmpty, "sanity: the engine must produce runs for real Swift")

    let colors = try renderedColors(
      "let alpha = 1", newLineNumber: 1, engine: engine, input: input, probeOffset: 1)  // inside "let"
    #expect(
      !CTRunColorProbe.sameColor(colors.token, colors.base),
      "the `let` keyword rendered the BASE color — the engine's line-0 runs never reached the 1-based row lookup")
  }

  /// EVERY line of a multi-line file must highlight — the user report was "any file,
  /// all white". Each line owns a keyword at a DISTINCT offset so a neighbor's runs
  /// (the off-by-one lands there) cannot accidentally paint the probe position.
  @Test func realEngineColorsEveryLineOfAMultiLineFile() async throws {
    // Three top-level declarations, each with a LEADING keyword (valid at file scope so
    // tree-sitter classifies it): `let` / `struct` / `func`, all probed at offset 1.
    let lines = ["let a = 1", "struct B {}", "func g() {}"]
    let source = lines.joined(separator: "\n") + "\n"
    let input = HighlightBlobInput(blobOID: "kw-multi", utf16: DiffFixture.blob(source), path: "Multi.swift")
    // Warm a REAL engine over the 0-based blob window covering all three lines: 0..<3.
    let engine = DiffHighlightEngine()
    _ = await engine.styleRuns(for: input, visibleLines: 0..<lines.count)

    struct Probe {
      var line: Int
      var content: String
      var offset: Int
    }
    let probes = [
      Probe(line: 1, content: lines[0], offset: 1),  // "let" at 0..<3
      Probe(line: 2, content: lines[1], offset: 1),  // "struct" at 0..<6
      Probe(line: 3, content: lines[2], offset: 1),  // "func" at 0..<4
    ]
    for probe in probes {
      let colors = try renderedColors(
        probe.content, newLineNumber: probe.line, engine: engine, input: input, probeOffset: probe.offset)
      #expect(
        !CTRunColorProbe.sameColor(colors.token, colors.base),
        "line \(probe.line) (\"\(probe.content)\") rendered the base color — its keyword was not highlighted")
    }
  }
}
