import AppKit
import CoreText
import Testing

@testable import supacode

/// CAT 4 — the LIVE `NSScrollView` seam the headless keystone could not reach, and
/// the exact one the "all white" bug hid behind: a real (window-less but SIZED)
/// `DiffViewportController` must (1) fire a NON-EMPTY visible-line window on the first
/// layout so the highlight query actually issues without a manual scroll (Finding C),
/// (2) resolve that window to the right 1-based line numbers through real scroll
/// geometry, (3) re-fire on scroll, and (4) — the full loop — repaint an already
/// materialized `LineRowView` in colour when `setSyntax` delivers runs.
@MainActor
struct DiffViewportHighlightIntegrationTests {
  /// One single-line context leaf per `(lineNumber, content)`, in order — leaf `i`
  /// renders at row `i` carrying old/new line number `lines[i].no`.
  private func codeTree(_ lines: [(no: Int, text: String)]) -> ChunkTree {
    let tree = ChunkTree(metrics: .production)
    let hunkID = HunkID(fileID: "f", index: 0)
    let diffLines = lines.map {
      DiffLine(origin: .context, oldLineNumber: $0.no, newLineNumber: $0.no, content: $0.text, noNewlineAtEof: false)
    }
    var after: ChunkID?
    for index in diffLines.indices {
      let segment = LineSegment(
        hunkID: hunkID, lines: diffLines, window: index..<(index + 1), classification: .context)
      after = tree.insert(.lineSegment(segment), after: after)
    }
    return tree
  }

  private func manyLines(_ count: Int) -> [(no: Int, text: String)] {
    (1...count).map { ($0, "let value\($0) = compute(\($0))") }
  }

  /// The first layout of a SIZED viewport fires a non-empty window covering the top
  /// source lines — the initial highlight query issues with no user scroll.
  @Test func initialApplyFiresNonEmptyVisibleWindow() {
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: 600)
    var fired: [VisibleLineWindow] = []
    controller.onVisibleRangeChanged = { fired.append($0) }

    controller.apply(tree: codeTree(manyLines(200)), mode: .unified, scrollPreserving: false)

    let window = fired.last
    #expect(window != nil, "the initial layout must fire a visible-line window")
    #expect(window?.new.isEmpty == false, "the fired window must be non-empty (the initial highlight query)")
    #expect(window?.new.lowerBound == 1, "the top of an unscrolled file is line 1")
    // 600pt / 20pt rows ≈ 30 visible lines — bounded by the viewport, not the file.
    #expect((window?.new.count ?? 0) < 200, "the window is bounded by the viewport, not the whole file")
  }

  /// `apply` resets the dedupe baseline, so re-opening / re-diffing a file always
  /// re-fires its window even if it coincides with the prior one (the guard against
  /// the initial query being swallowed).
  @Test func applyRefiresEvenWhenWindowUnchanged() {
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: 600)
    var fires = 0
    controller.onVisibleRangeChanged = { _ in fires += 1 }
    let tree = codeTree(manyLines(200))
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
    let afterFirst = fires
    controller.apply(tree: codeTree(manyLines(200)), mode: .unified, scrollPreserving: false)
    #expect(fires > afterFirst, "a fresh apply must re-fire the window, not dedupe it away")
  }

  /// Scrolling to new lines fires an updated window with higher line numbers (a pure
  /// re-layout at the same offset stays deduped; a real move gets through).
  @Test func scrollFiresUpdatedWindow() {
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: 600)
    var fired: [VisibleLineWindow] = []
    controller.onVisibleRangeChanged = { fired.append($0) }
    controller.apply(tree: codeTree(manyLines(400)), mode: .unified, scrollPreserving: false)
    let top = fired.last?.new

    controller.scroll(toY: 2000)  // 100 rows down
    let scrolled = fired.last?.new
    #expect(top != nil && scrolled != nil)
    #expect((scrolled?.lowerBound ?? 0) > (top?.lowerBound ?? 0), "scrolling down must advance the visible line window")
  }

  /// THE FULL LOOP: apply → the row materializes plain → `setSyntax` delivers runs →
  /// the SAME materialized `LineRowView` re-typesets in colour. This is the live
  /// path (`setSyntax` → `layoutVisibleChunks` → `configure(syntaxVersion:)`) that the
  /// headless keystone bypassed.
  @Test func setSyntaxRepaintsMaterializedRowInColor() throws {
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: 600)
    controller.apply(
      tree: codeTree([(1, "func run() {}")] + manyLines(60).map { ($0.no + 1, $0.text) }),
      mode: .unified, scrollPreserving: false)

    // Before syntax: the "func run()" row is plain (base foreground).
    func funcRow() -> LineRowView? {
      (controller.pools[.line]?.used.values).flatMap { views in
        views.compactMap { $0 as? LineRowView }.first { $0.firstRowText == "func run() {}" }
      }
    }
    let before = try #require(funcRow(), "line 1 must be materialized at the top")
    let beforeLine = try #require(before.firstRowCTLines?.first)
    #expect(
      CTRunColorProbe.sameColor(
        CTRunColorProbe.foreground(beforeLine, at: 1), DiffPalette.shared.codeForeground.cgColor),
      "before syntax arrives the row is plain")

    // Deliver runs for line 1 (new side): `func` keyword at 0..<4.
    controller.setSyntax(old: [:], new: [1: [StyleRun(range: 0..<4, capture: "keyword")]])

    let after = try #require(funcRow(), "the row is still materialized after setSyntax")
    let afterLine = try #require(after.firstRowCTLines?.first)
    #expect(
      !CTRunColorProbe.sameColor(
        CTRunColorProbe.foreground(afterLine, at: 1), DiffPalette.shared.codeForeground.cgColor),
      "setSyntax must repaint the materialized row in colour (the live loop that stayed white)")
  }
}
