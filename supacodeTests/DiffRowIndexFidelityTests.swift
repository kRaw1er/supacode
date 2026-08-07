import AppKit
import Testing

@testable import supacode

/// ROW-INDEX FIDELITY (PURE MODEL, NO NSScrollView) — the seam the scroll viewport
/// only ever *draws*: "given rendered-row index `i`, which source line do we get?"
///
/// The scroll layer is a dumb painter — it calls `tree.seek(index:)` / `seek(y:)` to
/// jump to an arbitrary offset and materializes whatever row the tree hands back. So
/// EVERY visible-content bug ("only the last few rows render", "wrong line at the top
/// of page 2", "rows change when you scroll back and forth") is ultimately a
/// `seek(index:i)` → `(chunkID, localRow)` → `renderedRows[localRow]` mapping bug.
///
/// The existing suite only exercises this seam two ways, and BOTH miss random access:
///   • `RowModelProjection` walks the tree SEQUENTIALLY (`seek(index:0)` + `successor`).
///     `successor` never re-descends from the root by count — a bug in the count-based
///     descent of `seek(index:i)` is invisible to it.
///   • `ChunkTreeTests` spot-checks a HANDFUL of hand-picked indices (0, 2, 3, 5, 80,
///     15_000). Nothing asserts that `seek(index:i)` is correct for *every* `i`, or
///     that it agrees with the sequential walk, over a COMPLEX mixed tree.
///
/// These tests close that gap with three tiers, over trees with many hunks, mixed
/// context / addition / deletion (incl. UNBALANCED del/add counts that shift split
/// alignment), collapsed inter-hunk gaps (expanders), multi-file widgets (file / hunk
/// headers), and no-newline markers — in unified AND split:
///   T1  Random access ≡ sequential walk, for every index, plus `rowIndex==i`, the
///       `rowIndex(for:)` round-trip, `seek(y:)`↔`seek(index:)` agreement, and
///       monotonic old/new line numbering (a wrong `localRow` breaks monotonicity).
///   T2  External content oracle: a distinct-content tree spanning MULTIPLE `maxLeafSpan`
///       leaves, where index `i` MUST yield `"line{i}"` — the literal "which line at
///       index 100" check, and its cross-leaf-boundary neighbours.
///   T3  Boundary / getter-consistency: out-of-range → nil, first / last, and the
///       renderer's own projection (`LineRowView`) shows the resolved row's text.
@MainActor
struct DiffRowIndexFidelityTests {

  // MARK: - Fixtures

  /// A deliberately gnarly multi-file tree assembled through the REAL `ChunkTreeBuilder`
  /// so it carries every index-shifting element the production path emits: file-header
  /// and hunk-header widgets, collapsed inter-hunk gap expanders, unbalanced del/add
  /// change blocks, and a trailing no-newline marker.
  private func kitchenSinkTree() -> ChunkTree {
    // File Alpha: two hunks with a big gap between them (→ a collapsed expander), and an
    // UNBALANCED change block (2 deletions vs 1 addition) so split alignment inserts a
    // buffer row and unified/split row counts diverge.
    let alphaHunk0 = DiffFixture.hunk(
      [
        DiffFixture.line(.context, old: 1, new: 1, "alpha one"),
        DiffFixture.line(.context, old: 2, new: 2, "alpha two"),
        DiffFixture.line(.deletion, old: 3, "alpha three old"),
        DiffFixture.line(.deletion, old: 4, "alpha four old"),
        DiffFixture.line(.addition, new: 3, "alpha three new"),
        DiffFixture.line(.context, old: 5, new: 4, "alpha five"),
      ],
      oldStart: 1, newStart: 1, header: "@@ -1,5 +1,4 @@")
    let alphaHunk1 = DiffFixture.hunk(
      [
        DiffFixture.line(.context, old: 40, new: 39, "alpha forty"),
        DiffFixture.line(.addition, new: 40, "alpha forty-one new"),
        DiffFixture.line(.context, old: 41, new: 41, "alpha forty-two"),
      ],
      oldStart: 40, newStart: 39, header: "@@ -40,2 +39,3 @@")

    // File Beta: one hunk ending in a no-newline-at-eof marker on the addition side.
    let betaHunk0 = DiffFixture.hunk(
      [
        DiffFixture.line(.context, old: 1, new: 1, "beta one"),
        DiffFixture.line(.deletion, old: 2, "beta two old"),
        DiffFixture.line(.addition, new: 2, "beta two new", noNewline: true),
      ],
      oldStart: 1, newStart: 1, header: "@@ -1,2 +1,2 @@")

    return ChunkTreeFixture.files([
      ChunkTreeFixture.FileSpec(file: DiffFixture.file(path: "Alpha.swift"), hunks: [alphaHunk0, alphaHunk1]),
      ChunkTreeFixture.FileSpec(file: DiffFixture.file(path: "Beta.swift"), hunks: [betaHunk0]),
    ])
  }

  /// One walked rendered row — the trusted reference the random-access seek is
  /// differentially checked against.
  private struct WalkRow: Equatable {
    var index: Int
    var chunk: ChunkID
    var localRow: Int
    var old: Int?
    var new: Int?
    var origin: DiffLineOrigin
    var isMarker: Bool
    var yOrigin: CGFloat
  }

  /// The reference: a sequential `seek(index:0)` + `successor` walk of the whole tree,
  /// capturing each row's identity. This path NEVER re-descends by count, so comparing
  /// `seek(index:i)` against `reference[i]` is a genuine cross-check of the two seek
  /// implementations, not a tautology.
  private func sequentialWalk(_ tree: ChunkTree, mode: DiffViewMode) -> [WalkRow] {
    var out: [WalkRow] = []
    var hit = tree.seek(index: 0, mode: mode)
    while let current = hit {
      let rendered = current.chunk.renderedRows(mode)
      let row = rendered[min(current.localRow, rendered.count - 1)]
      out.append(
        WalkRow(
          index: current.rowIndex, chunk: current.id, localRow: current.localRow,
          old: row.oldNumber, new: row.newNumber, origin: row.origin, isMarker: row.isMarker,
          yOrigin: current.yOrigin))
      hit = tree.successor(of: current, mode: mode)
    }
    return out
  }

  // MARK: - T1: random access ≡ sequential walk (+ round-trips, monotonicity)

  @Test(arguments: [DiffViewMode.unified, .split])
  func randomAccessSeekMatchesSequentialWalkForEveryIndex(mode: DiffViewMode) throws {
    let tree = kitchenSinkTree()
    let reference = sequentialWalk(tree, mode: mode)
    #expect(reference.count > 0)

    // The walk must itself be a gap-free 0-based sequence — the precondition for
    // treating `reference[i]` as "the row at index i".
    for (expected, row) in reference.enumerated() {
      #expect(row.index == expected, "sequential walk row \(expected) reported rowIndex \(row.index)")
    }

    // Every random-access seek lands on exactly the walk's row at that index.
    for index in 0..<reference.count {
      let hit = try #require(tree.seek(index: index, mode: mode), "seek(index: \(index)) returned nil in \(mode)")
      let want = reference[index]
      #expect(hit.rowIndex == index, "seek(index: \(index)).rowIndex == \(hit.rowIndex)")
      #expect(hit.id == want.chunk, "index \(index): chunk \(hit.id) != walk chunk \(want.chunk)")
      #expect(hit.localRow == want.localRow, "index \(index): localRow \(hit.localRow) != walk \(want.localRow)")

      // The row the RENDERER would read at this hit is the walk's row (right line at
      // right index — the literal render-fidelity property).
      let rendered = hit.chunk.renderedRows(mode)
      let row = rendered[min(hit.localRow, rendered.count - 1)]
      #expect(
        row.oldNumber == want.old,
        "index \(index): old \(String(describing: row.oldNumber)) != \(String(describing: want.old))")
      #expect(
        row.newNumber == want.new,
        "index \(index): new \(String(describing: row.newNumber)) != \(String(describing: want.new))")
      #expect(row.origin == want.origin, "index \(index): origin \(row.origin) != \(want.origin)")
      #expect(row.isMarker == want.isMarker, "index \(index): isMarker mismatch")

      // Inverse: the anchor round-trips back to the same global index.
      let roundTrip = tree.rowIndex(for: (chunk: hit.id, localRow: hit.localRow), mode: mode)
      #expect(roundTrip == index, "rowIndex(for: index \(index)) == \(String(describing: roundTrip))")

      // `locate` (used by the mode toggle) resolves the same anchor.
      let located = tree.locate(rowIndex: index, mode: mode)
      #expect(located?.chunk == hit.id && located?.localRow == hit.localRow, "locate(\(index)) != seek anchor")
    }

    // Out of range on both ends.
    #expect(tree.seek(index: -1, mode: mode) == nil)
    #expect(tree.seek(index: reference.count, mode: mode) == nil)
    #expect(tree.seek(index: reference.count + 1_000, mode: mode) == nil)
  }

  /// `seek(y:)` (pixel offset, the scroll entry point) must resolve to the SAME row as
  /// `seek(index:)` for that row — a probe just inside the row's vertical band.
  @Test(arguments: [DiffViewMode.unified, .split])
  func seekByPixelAgreesWithSeekByIndex(mode: DiffViewMode) throws {
    let tree = kitchenSinkTree()
    let reference = sequentialWalk(tree, mode: mode)
    for index in 0..<reference.count {
      let byIndex = try #require(tree.seek(index: index, mode: mode))
      // Probe a hair below the row top so we stay inside the row (heights vary).
      let probeY = byIndex.yOrigin + 0.5
      let byPixel = try #require(tree.seek(y: probeY, mode: mode), "seek(y: \(probeY)) nil at index \(index)")
      #expect(byPixel.id == byIndex.id, "index \(index): seek(y) chunk \(byPixel.id) != seek(index) \(byIndex.id)")
      #expect(
        byPixel.localRow == byIndex.localRow,
        "index \(index): seek(y) localRow \(byPixel.localRow) != \(byIndex.localRow)")
      #expect(byPixel.rowIndex == index, "index \(index): seek(y).rowIndex == \(byPixel.rowIndex)")
    }
  }

  /// Old and new line numbers, read down the rendered rows of ONE file, are each
  /// non-decreasing — a diff can only move forward through both blobs. A `seek`/`localRow`
  /// bug that returns the wrong source line for some index breaks this monotonicity even
  /// though each individual row still "looks" valid. Independent of the sequential walk.
  /// The counters reset at each file-header widget (numbering restarts per file).
  @Test(arguments: [DiffViewMode.unified, .split])
  func renderedLineNumbersAreMonotonicWithinEachFile(mode: DiffViewMode) throws {
    let tree = kitchenSinkTree()
    let reference = sequentialWalk(tree, mode: mode)
    var lastOld = Int.min
    var lastNew = Int.min
    for index in 0..<reference.count {
      let hit = try #require(tree.seek(index: index, mode: mode))
      if hit.chunk.widget?.reuseKind == .fileHeader {
        lastOld = Int.min  // a new file — numbering restarts
        lastNew = Int.min
        continue
      }
      let rendered = hit.chunk.renderedRows(mode)
      let row = rendered[min(hit.localRow, rendered.count - 1)]
      if let old = row.oldNumber {
        #expect(old >= lastOld, "old line number went backwards at index \(index): \(old) < \(lastOld)")
        lastOld = old
      }
      if let new = row.newNumber {
        #expect(new >= lastNew, "new line number went backwards at index \(index): \(new) < \(lastNew)")
        lastNew = new
      }
    }
  }

  // MARK: - T2: external content oracle — "which line do we get at index 100"

  /// A 12_000-row distinct-content tree (`"line{i}"`, all context, 1:1 numbering) spans
  /// THREE `maxLeafSpan` (5_000) leaves. So global index `i` MUST resolve to the leaf
  /// `i / 5_000`, local row `i % 5_000`, source text `"line{i}"`, numbered `i+1`. This
  /// is the literal getter contract the scroll viewport relies on, checked at deep
  /// indices AND exactly across both leaf seams (where an off-by-one in the count
  /// descent would surface).
  @Test func deepIndexResolvesToExactSourceLineAcrossLeafBoundaries() throws {
    let rows = 12_000
    let tree = ChunkTreeFixture.uniform(rows: rows) { "line\($0)" }
    let span = ChunkLayoutMetrics.maxLeafSpan

    // Deep, boundary, and the user's literal example (100).
    let probes = [0, 1, 100, span - 1, span, span + 1, 2 * span - 1, 2 * span, 2 * span + 1, rows - 1]
    for index in probes {
      let hit = try #require(tree.seek(index: index, mode: .unified), "seek(index: \(index)) nil")
      #expect(hit.rowIndex == index)
      let segment = try #require(hit.chunk.lineSegment, "index \(index) did not resolve to a line segment")
      #expect(hit.localRow == index % span, "index \(index): localRow \(hit.localRow) != \(index % span)")
      let line = segment.windowLine(at: hit.localRow)
      #expect(line.content == "line\(index)", "index \(index): got \"\(line.content)\", want \"line\(index)\"")
      #expect(
        line.newLineNumber == index + 1,
        "index \(index): newLineNumber \(String(describing: line.newLineNumber)) != \(index + 1)")
      #expect(
        line.oldLineNumber == index + 1,
        "index \(index): oldLineNumber \(String(describing: line.oldLineNumber)) != \(index + 1)")

      // The model-sourced copy getter must name the same new-side line.
      let copy = tree.diffLine(atRow: index, mode: .unified)
      #expect(
        copy?.side == .new && copy?.lineNumber == index + 1, "diffLine(atRow: \(index)) == \(String(describing: copy))")
    }
  }

  /// A full sweep (every index) over a smaller cross-leaf tree — nothing may drift by a
  /// single row anywhere across a leaf seam, not just at the sampled probes.
  @Test func everyIndexResolvesToItsOwnLineInACrossLeafTree() throws {
    let rows = ChunkLayoutMetrics.maxLeafSpan + 250  // spans exactly two leaves
    let tree = ChunkTreeFixture.uniform(rows: rows) { "line\($0)" }
    for index in 0..<rows {
      let hit = try #require(tree.seek(index: index, mode: .split), "seek(index: \(index)) nil")
      let segment = try #require(hit.chunk.lineSegment)
      #expect(
        segment.windowLine(at: hit.localRow).content == "line\(index)", "index \(index) resolved to the wrong line")
    }
    #expect(tree.seek(index: rows, mode: .split) == nil)
  }

  // MARK: - T3: getter consistency with the renderer's own projection

  /// The row the tree resolves at a deep index and the text `LineRowView` actually
  /// typesets for that same leaf-local row are the same line — proving the index the
  /// scroll layer seeks to and the glyphs it paints cannot diverge.
  @Test func lineRowViewProjectsTheSameTextTheTreeResolvesAtIndex() throws {
    let tree = ChunkTreeFixture.uniform(rows: 8_000) { "line\($0)" }
    let view = LineRowView()
    for index in [100, 4_999, 5_000, 7_999] {
      let hit = try #require(tree.seek(index: index, mode: .unified))
      let segment = try #require(hit.chunk.lineSegment)
      // Whole-leaf typeset (renderRange nil) so `visibleRowTexts` carries every local row.
      view.configure(
        segment: segment, chunkID: hit.id,
        rowHeight: ChunkLayoutMetrics.production.lineHeight,
        font: .monospacedSystemFont(ofSize: 12, weight: .regular), mode: .unified)
      let painted = view.visibleRowTexts.first { $0.localRow == hit.localRow }
      let text = try #require(painted, "LineRowView did not project local row \(hit.localRow) for index \(index)")
      #expect(
        text.unified == "line\(index)",
        "index \(index): view painted \"\(String(describing: text.unified))\", want \"line\(index)\"")
    }
  }

  /// The two INDEPENDENT projections must agree for every leaf: `SegmentProjection`
  /// (`renderedRows`, the MODEL the tree seeks by, and the height the tree reserves) and
  /// `LineRowView` (the DRAWN rows). If their row counts diverge, the leaf frame — sized
  /// to the model count — mis-sizes the drawn rows, so index `i` seeks to one row while
  /// the view paints another at that offset (rows "drift" / land at the wrong place).
  /// Checked over the kitchen-sink's unbalanced change blocks + no-newline marker, both
  /// modes — exactly the mixed cases the two hand-written projections could disagree on.
  @Test(arguments: [DiffViewMode.unified, .split])
  func drawnRowProjectionMatchesModelRowProjectionForEveryLeaf(mode: DiffViewMode) throws {
    let tree = kitchenSinkTree()
    let view = LineRowView()
    var hit = tree.seek(index: 0, mode: mode)
    var checkedLeaves = 0
    var seen = Set<ChunkID>()
    while let current = hit {
      defer { hit = tree.successor(of: current, mode: mode) }
      guard let segment = current.chunk.lineSegment, seen.insert(current.id).inserted else { continue }
      let modelRows = segment.renderedRows(mode)

      // The tree reserves height for exactly the model's row count.
      let reserved = current.chunk.baseSummary(metrics: tree.metrics).count(mode)
      #expect(
        reserved == modelRows.count,
        "leaf \(current.id): tree reserved \(reserved) rows, model has \(modelRows.count) [\(mode)]")

      view.configure(
        segment: segment, chunkID: current.id,
        rowHeight: ChunkLayoutMetrics.production.lineHeight,
        font: .monospacedSystemFont(ofSize: 12, weight: .regular), mode: mode)
      #expect(
        view.renderedRowCount == modelRows.count,
        "leaf \(current.id): view drew \(view.renderedRowCount) rows, model projected \(modelRows.count) [\(mode)]")

      // Row-for-row: a model marker row draws no content; a model content row draws it.
      for (localRow, modelRow) in modelRows.enumerated() {
        let drawn = try #require(
          view.visibleRowTexts.first { $0.localRow == localRow },
          "leaf \(current.id) localRow \(localRow) was not drawn in \(mode)")
        let hasContent = (drawn.unified ?? drawn.old ?? drawn.new) != nil
        #expect(
          hasContent != modelRow.isMarker,
          "leaf \(current.id) row \(localRow): content \(hasContent) vs isMarker \(modelRow.isMarker) [\(mode)]")
      }
      checkedLeaves += 1
    }
    #expect(checkedLeaves > 0, "no line-segment leaves were checked in \(mode)")
  }

  /// First and last index of the kitchen-sink tree resolve, and the very first rendered
  /// row of a builder-assembled file is its file-header widget (a widget row, no numbers).
  @Test func firstAndLastIndexResolveAndFirstRowIsFileHeaderWidget() throws {
    let tree = kitchenSinkTree()
    let count = sequentialWalk(tree, mode: .unified).count

    let first = try #require(tree.seek(index: 0, mode: .unified))
    #expect(first.chunk.widget != nil, "the first rendered row of a built tree is the file-header widget")
    #expect(first.chunk.renderedRows(.unified).first?.oldNumber == nil)

    let last = try #require(tree.seek(index: count - 1, mode: .unified))
    #expect(last.rowIndex == count - 1)
  }
}
