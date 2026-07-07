import AppKit
import CoreText

@testable import supacode

/// CT-HEADLESS render harness for the syntax-pipeline suites: configure one `.line`
/// chunk with a set of per-line style runs and read back the foreground a probed
/// glyph actually draws. Wraps the `LineRowView` + `LineRowRenderContext` boilerplate
/// so Cat 2 (cross-grammar) / Cat 5 (async ordering) assert on real CTRun color
/// without re-deriving it. Pairs with `CTRunColorProbe`.
@MainActor
enum SyntaxRenderHarness {
  /// The base code foreground (what an unhighlighted glyph — the "white" bug — draws).
  static var baseColor: CGColor { DiffPalette.shared.codeForeground.cgColor }

  /// A wide, cache-fresh unified render context carrying `newStyleRuns` / `oldStyleRuns`
  /// (line-relative offsets == string offsets at width 4000).
  static func context(new: [Int: [StyleRun]] = [:], old: [Int: [StyleRun]] = [:]) -> LineRowRenderContext {
    LineRowRenderContext(
      metrics: .resolve(), rowHeight: ChunkLayoutMetrics.production.lineHeight, mode: .unified, width: 4000,
      cache: CTLineCache(), palette: .shared, styleGeneration: 0, oldStyleRuns: old, newStyleRuns: new)
  }

  /// A single-row context segment carrying `content` at 1-based `lineNumber`.
  static func contextSegment(_ content: String, lineNumber: Int) -> LineSegment {
    LineSegment(
      hunkID: HunkID(fileID: "f", index: 0),
      lines: [
        DiffLine(
          origin: .context, oldLineNumber: lineNumber, newLineNumber: lineNumber, content: content,
          noNewlineAtEof: false)
      ],
      window: 0..<1,
      classification: .context)
  }

  /// Render one line with the given new-side runs and return the foreground of the
  /// glyph at `offset` (nil if no CTLine / no color) — for the "was it highlighted"
  /// assertion `token != baseColor`.
  static func foreground(
    _ content: String, lineNumber: Int, newRuns: [Int: [StyleRun]], at offset: Int
  ) -> CGColor? {
    let view = LineRowView()
    view.configure(
      segment: contextSegment(content, lineNumber: lineNumber),
      chunkID: ChunkID(raw: UInt64(lineNumber)),
      context: context(new: newRuns))
    guard let ctLine = view.firstRowCTLines?.first else { return nil }
    return CTRunColorProbe.foreground(ctLine, at: offset)
  }
}
