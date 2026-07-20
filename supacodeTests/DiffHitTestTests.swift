import AppKit
import Testing

@testable import supacode

/// Phase 2 — pure x-band geometry + `y → chunk` hit resolution (C 2.1–2.4,
/// D wide-char x-band). Flipped-coordinate / retina math is proven here in
/// isolation, no window (plan §Edge cases: extract the x-band as pure funcs).
///
/// Bar-width reconciliation: the plan states `changeBarWidth = 4` twice (the
/// `DiffHitTest` sketch constant and the prose "[oldBar 4pt]"), and bar = 4
/// satisfies all five of test 2.1's probes; a bar of 2 would be required for the
/// lone `x=402→gutter(new)` probe in 2.2's one-line description but would break
/// 2.1's `x=2→changeBar(old)`. The load-bearing constant (bar = 4) wins; 2.2 is
/// tested at correct probe points for bar = 4 (the `x=402` example is a typo).
@MainActor
struct DiffHitTestTests {
  // MARK: - 2.1 unified bands

  @Test func xBandUnified() {
    func column(_ position: CGFloat) -> DiffColumn {
      DiffHitTest.column(at: position, mode: .unified, width: 800, gutterW: 40)
    }
    #expect(column(2) == .changeBar(.old))
    #expect(column(20) == .gutter(.old))
    #expect(column(46) == .changeBar(.new))
    #expect(column(64) == .gutter(.new))
    #expect(column(400) == .content(.new))
  }

  // MARK: - 2.2 split midline

  @Test func xBandSplitMidline() {
    func column(_ position: CGFloat) -> DiffColumn {
      DiffHitTest.column(at: position, mode: .split, width: 800, gutterW: 40)
    }
    // mid == round(800/2) == 400: old pane [0,400), new pane [400,800).
    #expect(column(0) == .changeBar(.old))  // old pane change bar [0,4)
    #expect(column(399) == .content(.old))  // old pane content [44,400)
    #expect(column(400) == .changeBar(.new))  // new pane change bar [400,404)
    #expect(column(405) == .gutter(.new))  // new pane gutter [404,444)
    #expect(column(444) == .content(.new))  // new pane content [444,800)
  }

  // MARK: - 2.3 boundary inclusivity (half-open, no gap / overlap)

  @Test func xBandBoundaryInclusivity() {
    for mode in [DiffViewMode.unified, .split] {
      let bands = DiffHitTest.bands(mode: mode, width: 800, gutterW: 40)
      // Contiguous: each band's upper bound is the next band's lower bound.
      for index in 0..<(bands.count - 1) {
        #expect(bands[index].range.upperBound == bands[index + 1].range.lowerBound)
      }
      // Covers [0, width) with no leading gap and reaches the full width.
      #expect(bands.first?.range.lowerBound == 0)
      #expect(bands.last?.range.upperBound == 800)
      // A point exactly on a boundary lands in the LATER band (half-open).
      for index in 1..<bands.count {
        let boundary = bands[index].range.lowerBound
        let hit = DiffHitTest.column(at: boundary, mode: mode, width: 800, gutterW: 40)
        #expect(hit == bands[index].column)
      }
    }
  }

  // MARK: - 2.4 gutter vs content, same chunk as the seek

  @Test func hitTestGutterVsContent() {
    let tree = ChunkTreeFixture.uniform(rows: 200)
    let metrics = ViewportTestSupport.metrics(gutter: 40)
    let seekHit = tree.seek(y: 1000, mode: .unified)
    let gutterHit = DiffHitTest.hit(CGPoint(x: 20, y: 1000), width: 800, tree: tree, mode: .unified, metrics: metrics)
    let contentHit = DiffHitTest.hit(CGPoint(x: 400, y: 1000), width: 800, tree: tree, mode: .unified, metrics: metrics)

    #expect(gutterHit?.column == .gutter(.old))
    #expect(contentHit?.column == .content(.new))
    #expect(gutterHit?.side == .old)
    #expect(contentHit?.side == .new)
    // Same chunk the tree seek resolves — the x-band only chooses the column.
    #expect(gutterHit?.chunkID == seekHit?.id)
    #expect(contentHit?.chunkID == seekHit?.id)
    // Row 50 of the uniform fixture is line 51 on both sides.
    #expect(gutterHit?.lineNumber == 51)
    #expect(contentHit?.lineNumber == 51)
    #expect(gutterHit?.rowIndex == seekHit?.rowIndex)
  }

  // MARK: - wide-char x-band (D §GHT) — pure x-band part only (P3 owns offset↔x)

  @Test func hitTestColumnOverWideChar() {
    // A single leaf whose content is full-width CJK — the x-bands are geometric
    // and glyph-width-independent, so a point in the content band resolves to
    // content(.new) regardless of the wide clusters drawn there. The CoreText
    // content-offset ↔ x round-trip over the wide char is Phase 3's concern.
    let tree = ChunkTree(metrics: .production)
    let lines = (0..<50).map {
      DiffLine(origin: .context, oldLineNumber: $0 + 1, newLineNumber: $0 + 1, content: "中文中文中文", noNewlineAtEof: false)
    }
    tree.insert(
      .lineSegment(
        LineSegment(hunkID: HunkID(fileID: "w", index: 0), lines: lines, window: 0..<50, classification: .context)),
      after: nil)
    let metrics = ViewportTestSupport.metrics(gutter: 40)
    let hit = DiffHitTest.hit(CGPoint(x: 400, y: 200), width: 800, tree: tree, mode: .unified, metrics: metrics)
    #expect(hit?.column == .content(.new))
    #expect(hit?.side == .new)
    #expect(hit?.lineNumber == 11)  // y=200 → row 10 → line 11
  }
}
