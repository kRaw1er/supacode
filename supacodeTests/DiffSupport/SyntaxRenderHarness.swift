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

  /// Fixed per-side blob identities the harness provider round-trips against. A render
  /// context built for the harness declares THESE, so `LineRowView`'s pull resolves back
  /// into the passed maps.
  static let oldBlobOID = "old"
  static let newBlobOID = "new"
  static let queryName = "swift"

  /// A `SyntaxRunsProvider` that serves the passed 1-based per-line maps through the
  /// 0-based-blob-line pull: `LineRowView` hands `blobLine = number - 1`, so the provider
  /// re-adds 1 to index the maps. Lets a direct-construction render test (custom width /
  /// side) reuse the exact same cache/provider seam the wide `context` helper uses.
  static func provider(new: [Int: [StyleRun]] = [:], old: [Int: [StyleRun]] = [:]) -> SyntaxRunsProvider {
    SyntaxRunsProvider { blobOID, _, blobLine in
      (blobOID == newBlobOID ? new : old)[blobLine + 1] ?? []
    }
  }

  /// A wide, cache-fresh unified render context whose `syntaxProvider` serves the passed
  /// per-line maps through the pull path (line-relative offsets == string offsets at
  /// width 4000). Every harness-based test asserts the SAME color through the
  /// cache/provider seam without change.
  static func context(new: [Int: [StyleRun]] = [:], old: [Int: [StyleRun]] = [:]) -> LineRowRenderContext {
    LineRowRenderContext(
      metrics: .resolve(), rowHeight: ChunkLayoutMetrics.production.lineHeight, mode: .unified, width: 4000,
      cache: CTLineCache(), palette: .shared, styleGeneration: 0, syntaxProvider: provider(new: new, old: old),
      oldBlobOID: oldBlobOID, newBlobOID: newBlobOID, oldQueryName: queryName, newQueryName: queryName)
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
