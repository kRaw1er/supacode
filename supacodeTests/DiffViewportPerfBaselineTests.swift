import AppKit
import Testing

@testable import supacode

/// WALL-CLOCK BASELINE (NOT a CI gate — a measurement harness). The scale-invariance
/// GATES live in `DiffViewportScalePerfTests` (spy counters, machine-independent).
/// This suite prints real timings of the PRODUCTION render path at 25k / 100k / 1M
/// lines so we have "data before optimizations" to compare against.
///
/// The git provider caps big files (byteCap 2MB / lineCap 50k), but the tree +
/// viewport themselves are uncapped, so we can measure the render layer at 1M lines
/// right now — a new (all-additions) file, exactly like the `testNk.swift` fixtures.
///
/// Run just this suite:
///   xcodebuild test -workspace supacode.xcworkspace -scheme supacode \
///     -destination 'platform=macOS' \
///     -only-testing:supacodeTests/DiffViewportPerfBaselineTests ...
@MainActor
struct DiffViewportPerfBaselineTests {
  private static let clock = ContinuousClock()

  private static func ms(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
  }

  /// One all-additions "new file" hunk of `rows` distinct lines — the worst case
  /// (a single giant change run), matching the untracked `testNk.swift` fixtures.
  private static func newFileHunk(rows: Int) -> ([DiffHunk], FileChange) {
    var lines: [DiffLine] = []
    lines.reserveCapacity(rows)
    for index in 0..<rows {
      lines.append(DiffFixture.line(.addition, new: index + 1, "let value\(index) = compute(\(index)) + offset"))
    }
    let hunk = DiffHunk(
      oldStart: 0, oldCount: 0, newStart: 1, newCount: rows, header: "@@ -0,0 +1,\(rows) @@", lines: lines)
    return ([hunk], DiffFixture.file(path: "big.swift", status: .added))
  }

  @Test(arguments: [25_000, 100_000, 1_000_000])
  func baseline(rows: Int) {
    let (hunks, file) = Self.newFileHunk(rows: rows)

    // 1) Synchronous tree build on the production path (classify walk + RB inserts).
    var tree: ChunkTree!
    let buildT = Self.clock.measure { tree = ChunkTreeBuilder.build(file: file, hunks: hunks, mode: .unified) }

    // 2) The per-load O(n) flatten the reducer runs (`hunks.flatMap(\.lines)` in
    //    relocateComments + highlight setup) — risk #2 from the review.
    let flatT = Self.clock.measure { _ = hunks.flatMap(\.lines) }

    // 3) First layout (apply → materialize the visible window + measure convergence).
    let controller = ViewportTestSupport.controller()
    let applyT = Self.clock.measure { controller.apply(tree: tree, mode: .unified, scrollPreserving: false) }

    // 4) A mid-document scroll layout pass (should be O(window)).
    let total = controller.documentView.bounds.height
    let scrollT = Self.clock.measure { controller.scroll(toY: total * 0.5) }

    // 5) A width-change reflow (the resize path this PR added) — measured as the
    //    whole reaction (new width → re-fit → re-tile → re-wrap the window). In
    //    headless AppKit setting the clip frame already drives `layout()`, so wrap
    //    the frame change too rather than only `viewportResized()` (which would then
    //    early-out on the already-applied width).
    let resizeT = Self.clock.measure {
      controller.scrollView.frame = NSRect(x: 0, y: 0, width: 400, height: 600)
      controller.scrollView.tile()
      controller.viewportResized()
    }

    print(
      String(
        format: "[perf-baseline] rows=%9d  nodes=%6d  build=%8.2fms  flatMap=%7.2fms  apply=%7.2fms  "
          + "scroll=%6.2fms  resize=%6.2fms",
        rows, tree.nodeCount, Self.ms(buildT), Self.ms(flatT), Self.ms(applyT), Self.ms(scrollT), Self.ms(resizeT)))

    // Not a gate — only fail on an absurd regression (e.g. an accidental O(n²)).
    #expect(Self.ms(scrollT) < 2_000, "a single scroll pass took \(Self.ms(scrollT))ms — that is not O(window)")
  }
}
