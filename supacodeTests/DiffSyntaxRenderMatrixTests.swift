import AppKit
import CoreText
import Testing

@testable import supacode

/// CAT 3 — the render-side highlight MATRIX. The keystone covers a unified context
/// row (new-side runs); this covers the branches it does not: a deletion row must
/// colour from the OLD-side runs (`LineRowView.syntaxRuns` `isOldSide` == true), an
/// addition/context row from the NEW side, the two sides must not leak into each
/// other, and a wrapped long line must still colour its leading token. Semantic CTRun
/// assertions ("rects + tokens, never pixels"), no golden image.
@MainActor
struct DiffSyntaxRenderMatrixTests {
  /// A `.change` segment pairing one deletion (old line `oldNo`) with one addition
  /// (new line `newNo`) — unified projects the deletion first.
  private func changeSegment(del: String, oldNo: Int, add: String, newNo: Int) -> LineSegment {
    LineSegment(
      hunkID: HunkID(fileID: "f", index: 0),
      lines: [
        DiffLine(origin: .deletion, oldLineNumber: oldNo, newLineNumber: nil, content: del, noNewlineAtEof: false),
        DiffLine(origin: .addition, oldLineNumber: nil, newLineNumber: newNo, content: add, noNewlineAtEof: false),
      ],
      window: 0..<2,
      classification: .change)
  }

  private func render(
    _ segment: LineSegment, width: CGFloat = 4000, old: [Int: [StyleRun]] = [:], new: [Int: [StyleRun]] = [:]
  ) -> LineRowView {
    let view = LineRowView()
    view.configure(
      segment: segment,
      chunkID: ChunkID(raw: 1),
      context: LineRowRenderContext(
        metrics: .resolve(), rowHeight: ChunkLayoutMetrics.production.lineHeight, mode: .unified, width: width,
        cache: CTLineCache(), palette: .shared, styleGeneration: 0,
        syntaxProvider: SyntaxRenderHarness.provider(new: new, old: old), oldBlobOID: SyntaxRenderHarness.oldBlobOID,
        newBlobOID: SyntaxRenderHarness.newBlobOID, oldQueryName: SyntaxRenderHarness.queryName,
        newQueryName: SyntaxRenderHarness.queryName))
    return view
  }

  /// A deletion row shows the OLD line, so it must colour from the OLD-side runs —
  /// with the NEW side deliberately empty, proving the `isOldSide` branch is taken.
  @Test func unifiedDeletionRowColorsFromOldSideRuns() throws {
    let segment = changeSegment(del: "let gone = 1", oldNo: 5, add: "let kept = 2", newNo: 5)
    let view = render(segment, old: [5: [StyleRun(range: 0..<3, capture: "keyword")]], new: [:])
    let ctLine = try #require(view.firstRowCTLines?.first, "the deletion row must produce a CTLine")
    let token = try #require(CTRunColorProbe.foreground(ctLine, at: 1))
    #expect(
      !CTRunColorProbe.sameColor(token, DiffPalette.shared.codeForeground.cgColor),
      "the deletion row did not colour from the old-side runs (isOldSide branch missed)")
  }

  /// The old-side runs must NOT bleed onto a row keyed to the new side: give ONLY the
  /// old side runs and render a context (new-keyed) row — it must stay base color.
  @Test func oldSideRunsDoNotLeakToNewKeyedRow() throws {
    let context = SyntaxRenderHarness.contextSegment("let x = 1", lineNumber: 5)
    // Runs are provided ONLY on the old side; a context row reads the NEW side.
    let view = LineRowView()
    view.configure(
      segment: context, chunkID: ChunkID(raw: 1),
      context: LineRowRenderContext(
        metrics: .resolve(), rowHeight: ChunkLayoutMetrics.production.lineHeight, mode: .unified, width: 4000,
        cache: CTLineCache(), palette: .shared, styleGeneration: 0,
        syntaxProvider: SyntaxRenderHarness.provider(old: [5: [StyleRun(range: 0..<3, capture: "keyword")]]),
        oldBlobOID: SyntaxRenderHarness.oldBlobOID, newBlobOID: SyntaxRenderHarness.newBlobOID,
        oldQueryName: SyntaxRenderHarness.queryName, newQueryName: SyntaxRenderHarness.queryName))
    let ctLine = try #require(view.firstRowCTLines?.first)
    #expect(
      CTRunColorProbe.sameColor(CTRunColorProbe.foreground(ctLine, at: 1), DiffPalette.shared.codeForeground.cgColor),
      "a new-keyed context row must ignore old-side runs")
  }

  /// A wrapped long line still colours its leading token: the run offsets are applied
  /// to the whole attributed string BEFORE the soft wrap, so the first sub-line's
  /// glyphs carry the foreground.
  @Test func wrappedLineStillColorsLeadingToken() throws {
    let long = "func compute() { return alpha + beta + gamma + delta + epsilon + zeta + eta }"
    let segment = SyntaxRenderHarness.contextSegment(long, lineNumber: 1)
    // Narrow width forces a wrap into multiple sub-lines.
    let view = LineRowView()
    view.configure(
      segment: segment, chunkID: ChunkID(raw: 1),
      context: LineRowRenderContext(
        metrics: .resolve(), rowHeight: ChunkLayoutMetrics.production.lineHeight, mode: .unified, width: 240,
        cache: CTLineCache(), palette: .shared, styleGeneration: 0,
        syntaxProvider: SyntaxRenderHarness.provider(new: [1: [StyleRun(range: 0..<4, capture: "keyword")]]),
        oldBlobOID: SyntaxRenderHarness.oldBlobOID, newBlobOID: SyntaxRenderHarness.newBlobOID,
        oldQueryName: SyntaxRenderHarness.queryName, newQueryName: SyntaxRenderHarness.queryName))
    let ctLines = try #require(view.firstRowCTLines)
    #expect(ctLines.count > 1, "the line must actually wrap for this to test sub-line colouring")
    let token = try #require(CTRunColorProbe.foreground(ctLines[0], at: 1), "no glyph on the first sub-line")
    #expect(
      !CTRunColorProbe.sameColor(token, DiffPalette.shared.codeForeground.cgColor),
      "the wrapped line's leading keyword lost its colour")
  }
}
