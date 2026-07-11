import AppKit
import Testing

@testable import supacode

/// Phase B — the CONTROLLER-driven pull-model warm. A sized headless
/// `DiffViewportController` (`ViewportTestSupport`) over a real Swift-content tree,
/// with a FRESH injected `DiffHighlightEngine`, must fill the span cache for the
/// VISIBLE + overscan render window, off-main, coalesced, querying only the lines not
/// already cached. The view still reads the reducer push in Phase B, so these tests
/// assert only that the cache gets FILLED — repaint-from-cache is Phase C.
///
/// The tree's 1-based `newLineNumber` maps to the blob's 0-based line with the SAME
/// `-1` shift the warmer uses (`DiffHighlightEngine.blobWindow`), so a warmed source
/// line `n` is cached at blob line `n - 1`. `@MainActor` because the controller +
/// engine are.
@MainActor
struct DiffViewportHighlightWarmTests {
  /// 200 distinct, keyword-bearing Swift lines — so a non-empty `cachedRuns` result is
  /// MEANINGFUL (the query classified `let`/`compute`, not just whitespace) and the file
  /// is far longer than the visible + overscan window (proving the warm is windowed).
  private static let swiftLines: [String] = (1...200).map { "let value\($0) = compute(\($0))" }
  private static var swiftSource: String { Self.swiftLines.joined(separator: "\n") + "\n" }

  private static var queryName: String {
    DiffHighlightEngine.grammarQueryName(forPath: "a.swift") ?? ""
  }

  /// One single-line context leaf per Swift line, in order — leaf `i` carries
  /// old/new line number `i + 1` and content `swiftLines[i]`.
  private func codeTree() -> ChunkTree {
    let tree = ChunkTree(metrics: .production)
    let hunkID = HunkID(fileID: "f", index: 0)
    let diffLines = Self.swiftLines.enumerated().map { index, text in
      DiffLine(
        origin: .context, oldLineNumber: index + 1, newLineNumber: index + 1, content: text, noNewlineAtEof: false)
    }
    var after: ChunkID?
    for index in diffLines.indices {
      let segment = LineSegment(
        hunkID: hunkID, lines: diffLines, window: index..<(index + 1), classification: .context)
      after = tree.insert(.lineSegment(segment), after: after)
    }
    return tree
  }

  private func newBlob(_ oid: String) -> HighlightBlobInput {
    HighlightBlobInput(blobOID: oid, utf16: DiffFixture.blob(Self.swiftSource), path: "a.swift")
  }

  /// A sized headless controller (800×600 ⇒ ~30 visible rows) over the Swift tree, with
  /// a FRESH engine injected so the warm writes to a cache the test owns.
  private func sizedController(engine: DiffHighlightEngine) -> DiffViewportController {
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: 600)
    controller.highlightEngine = engine
    controller.apply(tree: codeTree(), mode: .unified, scrollPreserving: false)
    return controller
  }

  /// After `setHighlightBlobs` + a layout on a real Swift tree, awaiting the warm leaves
  /// the span cache NON-EMPTY and keyword-bearing for lines inside the visible window.
  @Test func warmFillsCacheForVisibleWindow() async {
    let engine = DiffHighlightEngine()
    let controller = sizedController(engine: engine)

    controller.setHighlightBlobs(fileID: "f", old: nil, new: newBlob("warm-visible"), disabled: false)
    await controller.highlightWarmTask?.value

    // Blob line 0 (source line 1) is at the very top of the visible band.
    let cached = engine.cachedRuns(blobOID: "warm-visible", queryName: Self.queryName, blobLines: 0..<30)
    let runs = cached.values.flatMap { $0 }
    #expect(!runs.isEmpty, "the warm must fill the span cache for the visible window")
    #expect(runs.contains { $0.capture.hasPrefix("keyword") }, "the warmed runs must be real classified tokens")
  }

  /// The warmed window covers OVERSCAN rows, not just the visible band: a source line
  /// well beyond the ~30-row viewport but within the 1000px (~50-row) overscan below is
  /// cached-present. This is the whole point — the reducer's visible-only query left
  /// these white.
  @Test func warmCoversOverscanBeyondVisibleBand() async {
    let engine = DiffHighlightEngine()
    let controller = sizedController(engine: engine)

    controller.setHighlightBlobs(fileID: "f", old: nil, new: newBlob("warm-overscan"), disabled: false)
    await controller.highlightWarmTask?.value

    // Source line 55 (blob line 54) is beyond the visible ~30 rows but inside the
    // visible + overscan window (~80 rows), so it must be warmed, unlike a visible-only
    // query which would leave it missing.
    let overscanGaps = engine.missingBlobLines(blobOID: "warm-overscan", queryName: Self.queryName, blobLines: 54..<55)
    #expect(overscanGaps.isEmpty, "an overscan row (source line 55) must be warmed, not left white")
    #expect(
      !engine.cachedRuns(blobOID: "warm-overscan", queryName: Self.queryName, blobLines: 54..<55).isEmpty,
      "the overscan row must carry cached runs")

    // A line far below the render window is NOT warmed (the warm is windowed, not whole-file).
    let farGaps = engine.missingBlobLines(blobOID: "warm-overscan", queryName: Self.queryName, blobLines: 150..<151)
    #expect(farGaps == [150..<151], "a row far below the render window stays unwarmed (windowed, not O(file))")
  }

  /// A SECOND warm over the same, already-filled window queries NOTHING new: the missing
  /// check finds no gaps, so no fresh warm task launches and the cache does not grow.
  @Test func secondWarmOverFilledWindowIsNoOp() async {
    let engine = DiffHighlightEngine()
    let controller = sizedController(engine: engine)

    controller.setHighlightBlobs(fileID: "f", old: nil, new: newBlob("warm-noop"), disabled: false)
    await controller.highlightWarmTask?.value
    let launchesAfterFirst = controller.highlightWarmLaunchCount
    let cachedAfterFirst = engine.cachedRuns(blobOID: "warm-noop", queryName: Self.queryName, blobLines: 0..<200).count
    #expect(launchesAfterFirst == 1, "the first warm over a cold window launches exactly one task")

    // The whole render window is now cached ⇒ nothing missing.
    let renderWindow = 0..<80
    #expect(
      engine.missingBlobLines(blobOID: "warm-noop", queryName: Self.queryName, blobLines: renderWindow).isEmpty,
      "after the first warm the render window is fully cached")

    // A re-trigger over the same window must not launch a new warm or grow the cache.
    controller.setHighlightBlobs(fileID: "f", old: nil, new: newBlob("warm-noop"), disabled: false)
    await controller.highlightWarmTask?.value
    #expect(controller.highlightWarmLaunchCount == launchesAfterFirst, "a warm over a filled window launches nothing")
    #expect(
      engine.cachedRuns(blobOID: "warm-noop", queryName: Self.queryName, blobLines: 0..<200).count == cachedAfterFirst,
      "a warm over a filled window adds no cache entries")
  }

  /// The size gate (`highlightingDisabled == true`) suppresses the warm entirely: no
  /// task launches and the cache stays empty (a huge file renders plain, no parse stall).
  @Test func sizeGateSuppressesWarm() async {
    let engine = DiffHighlightEngine()
    let controller = sizedController(engine: engine)

    controller.setHighlightBlobs(fileID: "f", old: nil, new: newBlob("warm-gated"), disabled: true)
    await controller.highlightWarmTask?.value

    #expect(controller.highlightWarmLaunchCount == 0, "a plain-gated file must not launch a warm")
    #expect(
      engine.cachedRuns(blobOID: "warm-gated", queryName: Self.queryName, blobLines: 0..<80).isEmpty,
      "the size gate leaves the span cache empty")
  }

  /// A path with no bundled grammar is skipped: the warm resolves no `queryName`, so no
  /// task launches even with blobs present and the gate off.
  @Test func noGrammarPathSkipsWarm() async {
    let engine = DiffHighlightEngine()
    let controller = sizedController(engine: engine)

    let plain = HighlightBlobInput(
      blobOID: "warm-nogrammar", utf16: DiffFixture.blob(Self.swiftSource), path: "notes.unknownext")
    controller.setHighlightBlobs(fileID: "f", old: nil, new: plain, disabled: false)
    await controller.highlightWarmTask?.value

    #expect(controller.highlightWarmLaunchCount == 0, "a path with no grammar must not launch a warm")
  }
}
