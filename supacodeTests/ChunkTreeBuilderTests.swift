import Foundation
import Testing

@testable import supacode

/// Pure coverage for `ChunkTreeBuilder` — the `DiffRowBuilder` port with
/// **edgeContext = 1** (C1), dual-mode counts matching pierre, all placeholders,
/// nullable split pairs, no-newline metadata, large-file cap, the estimate
/// arithmetic, and the `verifyHunkLineValues` count oracle.
@MainActor
struct ChunkTreeBuilderTests {
  // MARK: - Projection helpers

  private func segments(_ chunks: [Chunk]) -> [LineSegment] {
    chunks.compactMap(\.lineSegment)
  }

  private func expanders(_ chunks: [Chunk]) -> [(anchor: Int, hidden: Int)] {
    chunks.compactMap { chunk in
      if case .widget(let widget) = chunk, case .expander(let anchor, _, let hidden) = widget.payload {
        return (anchor, hidden)
      }
      return nil
    }
  }

  private func placeholders(_ chunks: [Chunk]) -> [FilePlaceholder] {
    chunks.compactMap { chunk in
      if case .widget(let widget) = chunk, case .placeholder(let placeholder) = widget.payload { return placeholder }
      return nil
    }
  }

  private var headerless: ChunkTreeBuilder.Options { ChunkTreeBuilder.Options(disableFileHeader: true) }

  // MARK: - Classification

  @Test func modifiedSingleHunkEmitsSegmentWithCorrectNumbers() {
    let hunk = DiffFixture.hunk(
      [DiffFixture.line(.deletion, old: 1, "old"), DiffFixture.line(.addition, new: 1, "new")]
    )
    let chunks = ChunkTreeBuilder.classify(file: DiffFixture.file(), hunks: [hunk], expanded: [], options: headerless)
    let segs = segments(chunks)
    #expect(segs.count == 1)
    #expect(segs[0].classification == .change)
    #expect(segs[0].windowDeletions.first?.oldLineNumber == 1)
    #expect(segs[0].windowAdditions.first?.newLineNumber == 1)
  }

  @Test func noTrailingNewlineEmitsMarkerRow() {
    let hunk = DiffFixture.hunk(
      [
        DiffFixture.line(.context, old: 1, new: 1, "keep"),
        DiffFixture.line(.addition, new: 2, "last", noNewline: true),
      ]
    )
    let chunks = ChunkTreeBuilder.classify(file: DiffFixture.file(), hunks: [hunk], expanded: [], options: headerless)
    let change = segments(chunks).first { $0.classification == .change }!
    // +1 no-newline marker row in each mode.
    #expect(change.renderedRows(.unified).filter(\.isMarker).count == 1)
    #expect(change.renderedRows(.split).filter(\.isMarker).count == 1)
    #expect(change.baseSummary(metrics: .production).unifiedCount == 2)
    #expect(change.baseSummary(metrics: .production).splitCount == 2)
    // The real addition keeps its number; the marker is synthetic.
    #expect(change.renderedRows(.unified).first?.newNumber == 2)
  }

  @Test func interHunkGapsBecomeExpanderWidgets() {
    let first = DiffFixture.hunk(
      [
        DiffFixture.line(.context, old: 10, new: 10, "c"),
        DiffFixture.line(.addition, new: 11, "a"),
        DiffFixture.line(.context, old: 11, new: 12, "c"),
      ],
      oldStart: 10, newStart: 10
    )
    let second = DiffFixture.hunk(
      [DiffFixture.line(.context, old: 200, new: 206, "c"), DiffFixture.line(.deletion, old: 201, "d")],
      oldStart: 200, newStart: 206
    )
    let chunks = ChunkTreeBuilder.classify(
      file: DiffFixture.file(), hunks: [first, second], expanded: [],
      options: ChunkTreeBuilder.Options(totalNewLines: 210)
    )
    let gaps = expanders(chunks)
    #expect(gaps.count == 3)  // leading + between + trailing
    #expect(gaps.first { $0.anchor == 13 }?.hidden == 193)  // first.newEnd(13)..<206
  }

  @Test func expandedGapAnchorSuppressesExpander() {
    let first = DiffFixture.hunk([DiffFixture.line(.addition, new: 1, "a")], oldStart: 1, newStart: 1)
    let second = DiffFixture.hunk([DiffFixture.line(.addition, new: 202, "a")], oldStart: 1, newStart: 202)
    let collapsed = ChunkTreeBuilder.classify(file: DiffFixture.file(), hunks: [first, second], expanded: [])
    let expanded = ChunkTreeBuilder.classify(file: DiffFixture.file(), hunks: [first, second], expanded: [2])
    #expect(expanders(collapsed).count == 1)
    #expect(expanders(expanded).isEmpty)
  }

  @Test func longInteriorContextRunCollapsesWithContextOne() {
    var lines = [DiffFixture.line(.addition, new: 1, "a")]
    for offset in 0..<40 {
      lines.append(DiffFixture.line(.context, old: offset + 1, new: offset + 2, "ctx"))
    }
    lines.append(DiffFixture.line(.deletion, old: 41, "d"))
    let chunks = ChunkTreeBuilder.classify(
      file: DiffFixture.file(),
      hunks: [DiffFixture.hunk(lines, header: "@@ -1,41 +1,41 @@")],
      expanded: [],
      options: ChunkTreeBuilder.Options(collapseThreshold: 10, edgeContext: 1)
    )
    let gaps = expanders(chunks)
    #expect(gaps.count == 1)
    #expect(gaps[0].hidden == 38)  // 40 − 2×1
    let contextLines = segments(chunks).filter { $0.classification == .context }.reduce(0) { $0 + $1.window.count }
    #expect(contextLines == 2)  // C1: 1 head + 1 tail (not 3)
  }

  // MARK: - Split pairing & dual-mode counts

  @Test func splitPairsCountedAsMaxDelAdd() {
    let hunk = DiffFixture.hunk([
      DiffFixture.line(.deletion, old: 1, "d0"),
      DiffFixture.line(.deletion, old: 2, "d1"),
      DiffFixture.line(.deletion, old: 3, "d2"),
      DiffFixture.line(.addition, new: 1, "a0"),
      DiffFixture.line(.addition, new: 2, "a1"),
    ])
    let change = segments(
      ChunkTreeBuilder.classify(file: DiffFixture.file(), hunks: [hunk], expanded: [], options: headerless)
    ).first { $0.classification == .change }!
    #expect(change.baseSummary(metrics: .production).splitCount == 3)  // max(3,2)
    #expect(change.baseSummary(metrics: .production).unifiedCount == 5)  // 3 + 2
    // The leftover deletion pairs against nil in split.
    #expect(change.renderedRows(.split).last?.newNumber == nil)
  }

  @Test func splitPureAddAndPureDelete() {
    let adds = segments(
      ChunkTreeBuilder.classify(
        file: DiffFixture.file(status: .added),
        hunks: [
          DiffFixture.hunk([DiffFixture.line(.addition, new: 1, "a"), DiffFixture.line(.addition, new: 2, "b")])
        ],
        expanded: [], options: headerless
      )
    ).first { $0.classification == .change }!
    #expect(adds.renderedRows(.split).allSatisfy { $0.oldNumber == nil && $0.newNumber != nil })

    let deletes = segments(
      ChunkTreeBuilder.classify(
        file: DiffFixture.file(status: .deleted),
        hunks: [
          DiffFixture.hunk([DiffFixture.line(.deletion, old: 1, "a"), DiffFixture.line(.deletion, old: 2, "b")])
        ],
        expanded: [], options: headerless
      )
    ).first { $0.classification == .change }!
    #expect(deletes.renderedRows(.split).allSatisfy { $0.oldNumber != nil && $0.newNumber == nil })
  }

  @Test func splitContextPairsBothSides() {
    let context = segments(
      ChunkTreeBuilder.classify(
        file: DiffFixture.file(),
        hunks: [
          DiffFixture.hunk([DiffFixture.line(.context, old: 1, new: 1, "c"), DiffFixture.line(.addition, new: 2, "a")])
        ],
        expanded: [], options: headerless
      )
    ).first { $0.classification == .context }!
    let pair = context.renderedRows(.split).first!
    #expect(pair.oldNumber == 1 && pair.newNumber == 1)
  }

  @Test func dualModeCountsMatchPierre() {
    let mixed = DiffFixture.hunk([
      DiffFixture.line(.context, old: 1, new: 1),
      DiffFixture.line(.context, old: 2, new: 2),
      DiffFixture.line(.deletion, old: 3),
      DiffFixture.line(.addition, new: 3),
    ])
    let counts = ChunkTreeBuilder.hunkCounts(mixed)
    #expect(counts.unified == counts.deletions + counts.additions + counts.context)  // del+add+ctx
    #expect(counts.split == max(counts.deletions, counts.additions) + counts.context)  // max(del,add)+ctx
    #expect(counts.unified == 4)
    #expect(counts.split == 3)
  }

  // MARK: - Placeholders & cap

  @Test func placeholderCasesEmitSingleWidgetLeaf() {
    func single(_ file: FileChange) -> FilePlaceholder? {
      let chunks = ChunkTreeBuilder.classify(file: file, hunks: [], expanded: [], options: headerless)
      #expect(chunks.count == 1)
      return placeholders(chunks).first
    }
    #expect(single(DiffFixture.file(binary: true)) == .binaryFile)
    #expect(single(DiffFixture.file(status: .deleted)) == .deletedFile)
    #expect(single(DiffFixture.file(status: .modeChanged)) == .modeChangeOnly(oldMode: "", newMode: ""))
    #expect(single(DiffFixture.file(status: .added)) == .addedEmpty)
    #expect(single(DiffFixture.file(status: .submodule)) == .submodule(oldSHA: "", newSHA: ""))
    #expect(single(DiffFixture.file(status: .modified)) == .noChanges)
  }

  /// Phase 13 (C 15.10) — a rename-pure file (similarity 100, zero content hunks)
  /// emits exactly ONE file-header widget and ZERO `.line` (line-segment) chunks:
  /// the header shows `old → new`, there is nothing to diff in the body.
  @Test func renamePureZeroBodyChunks() {
    let renamed = FileChange(
      oldPath: "old/name.swift", newPath: "new/name.swift", status: .renamed,
      addedLines: 0, removedLines: 0, isBinary: false, isLargeFileCapped: false,
      hasLongLines: false, similarity: 100)
    // Default options ⇒ the file-header widget IS emitted (not disabled).
    let chunks = ChunkTreeBuilder.classify(file: renamed, hunks: [], expanded: [])
    let fileHeaders = chunks.filter { chunk in
      if case .widget(let widget) = chunk, case .fileHeader = widget.key { return true }
      return false
    }
    #expect(fileHeaders.count == 1)  // exactly one header widget
    #expect(segments(chunks).isEmpty)  // ZERO body (line-segment) chunks
    // The header model renders the rename arrow (`old → new`).
    #expect(FileHeaderWidget.Model.make(from: renamed).path == "old/name.swift → new/name.swift")
  }

  @Test func largeFileCapEmitsPlainFallbackLeaves() {
    let hunk = DiffFixture.hunk([
      DiffFixture.line(.context, old: 1, new: 1, "a"),
      DiffFixture.line(.addition, new: 2, "b"),
      DiffFixture.line(.deletion, old: 2, "c"),
    ])
    let chunks = ChunkTreeBuilder.classify(
      file: DiffFixture.file(capped: true), hunks: [hunk], expanded: [], options: headerless
    )
    let fallbacks = chunks.compactMap { chunk -> (Int, String)? in
      if case .widget(let widget) = chunk, case .plainFallback(let line, let text) = widget.payload {
        return (line, text)
      }
      return nil
    }
    #expect(fallbacks.count == 3)
    #expect(fallbacks[2].0 == 2)  // deletion keeps the old number
    #expect(fallbacks[2].1 == "c")
  }

  // MARK: - Determinism & comments

  @Test func deterministicBuildsAreStructurallyEqual() {
    let hunk = DiffFixture.hunk([
      DiffFixture.line(.context, old: 1, new: 1, "k"), DiffFixture.line(.addition, new: 2, "a"),
    ])
    let first = ChunkTreeBuilder.build(file: DiffFixture.file(), hunks: [hunk], mode: .unified)
    let second = ChunkTreeBuilder.build(file: DiffFixture.file(), hunks: [hunk], mode: .unified)
    #expect(first.inorderChunks() == second.inorderChunks())
  }

  @Test func commentThreadInsertedAfterAnchorRow() {
    let hunk = DiffFixture.hunk([
      DiffFixture.line(.context, old: 1, new: 1, "one"),
      DiffFixture.line(.context, old: 2, new: 2, "two"),
      DiffFixture.line(.context, old: 3, new: 3, "three"),
    ])
    let comment = ReviewComment(
      filePath: "a.swift", side: .new, startLine: 2, endLine: 2,
      anchorSnippet: "two", contextBefore: "", body: "note"
    )
    let tree = ChunkTreeBuilder.build(
      file: DiffFixture.file(), hunks: [hunk], mode: .unified, expanded: [], comments: [comment])
    let nodes = tree.inorderNodes()
    let commentIndex = nodes.firstIndex { $0.chunk.widget?.reuseKind == .commentThread }
    #expect(commentIndex != nil)
    // The node immediately before the comment ends at the anchored line (2).
    let before = nodes[commentIndex! - 1].chunk.lineSegment
    #expect(before?.windowedLines.last?.newLineNumber == 2)
    // The node after resumes at line 3.
    let after = nodes[commentIndex! + 1].chunk.lineSegment
    #expect(after?.windowedLines.first?.newLineNumber == 3)
  }

  // MARK: - Count oracle & deep fixture

  @Test func verifyHunkLineValuesOracle() {
    let hunks = [
      DiffFixture.hunk(
        [
          DiffFixture.line(.context, old: 1, new: 1), DiffFixture.line(.deletion, old: 2),
          DiffFixture.line(.addition, new: 2),
        ],
        oldStart: 1, newStart: 1
      ),
      DiffFixture.hunk(
        [DiffFixture.line(.context, old: 50, new: 50), DiffFixture.line(.addition, new: 51)],
        oldStart: 50, newStart: 50
      ),
    ]
    #expect(ChunkTreeBuilder.verifyHunkLineValues(hunks) == [])
  }

  @Test func deepInFileSingleLineReplaceFixture() {
    var lines: [DiffLine] = []
    for offset in 0..<32 {
      lines.append(DiffFixture.line(.deletion, old: 3720 + offset, "old\(offset)"))
    }
    lines.append(DiffFixture.line(.addition, new: 3720, "new"))
    let hunk = DiffFixture.hunk(lines, oldStart: 3720, newStart: 3720, header: "@@ -3720,32 +3720,1 @@")
    #expect(ChunkTreeBuilder.verifyHunkLineValues([hunk]) == [])
    let change = segments(
      ChunkTreeBuilder.classify(file: DiffFixture.file(), hunks: [hunk], expanded: [], options: headerless)
    ).first { $0.classification == .change }!
    #expect(change.window.count == 33)  // 32 deletions + 1 addition
    #expect(change.baseSummary(metrics: .production).unifiedCount == 33)
    #expect(change.baseSummary(metrics: .production).splitCount == 32)  // max(32, 1)
  }

  // MARK: - Estimate arithmetic

  @Test func estIncludesNoNewlineMetadataRows() {
    let hunk = DiffFixture.hunk([
      DiffFixture.line(.context, old: 1, new: 1, "one"),
      DiffFixture.line(.deletion, old: 2, "two", noNewline: true),
      DiffFixture.line(.addition, new: 2, "TWO", noNewline: true),
    ])
    let metadata = ChunkTreeBuilder.noNewlineMetadataCounts([hunk])
    #expect(metadata.split == 1)  // both sides share one row in split
    #expect(metadata.unified == 2)  // one per side in unified
    // Folded into the estimate (expandUnchanged avoids separators to isolate rows).
    let heights = ChunkTreeBuilder.estimatedHeights(
      file: DiffFixture.file(), hunks: [hunk], options: ChunkTreeBuilder.Options(expandUnchanged: true)
    )
    let expectedUnified: CGFloat = 44 + 5 * 20 + 8  // 3 base + 2 metadata rows
    let expectedSplit: CGFloat = 44 + 3 * 20 + 8  // 2 base + 1 metadata row
    #expect(heights.unified == expectedUnified)
    #expect(heights.split == expectedSplit)
  }

  /// pierre `computeEstimatedDiffHeights` case 1: a no-body file (identical /
  /// no-hunk / empty-hunk / rename-pure) estimates to the TOP REGION ONLY — it must
  /// NOT reserve a phantom `paddingBottom`, or its height (and the multi-file
  /// scrollbar offset for every file below it) drifts by `paddingBottom`.
  @Test func estZeroHunkFileSkipsPaddingBottom() {
    let metrics = ChunkLayoutMetrics.production
    // With the file header enabled, the top region is header + paddingTop.
    let topRegion = metrics.diffHeaderHeight + metrics.paddingTop
    #expect(metrics.paddingBottom > 0)  // guards the assertion below is non-trivial

    // (1) no-hunk file (identical / no changes).
    let noHunk = ChunkTreeBuilder.estimatedHeights(file: DiffFixture.file(), hunks: [])
    #expect(noHunk.unified == topRegion)
    #expect(noHunk.split == topRegion)
    #expect(noHunk.unified != topRegion + metrics.paddingBottom)  // paddingBottom NOT reserved

    // (2) an empty-line hunk collapses to the same no-body estimate.
    let emptyHunk = ChunkTreeBuilder.estimatedHeights(file: DiffFixture.file(), hunks: [DiffFixture.hunk([])])
    #expect(emptyHunk.unified == topRegion)
    #expect(emptyHunk.split == topRegion)

    // (3) rename-pure (similarity 100, zero content hunks) — same skip.
    let renamed = FileChange(
      oldPath: "old/name.swift", newPath: "new/name.swift", status: .renamed,
      addedLines: 0, removedLines: 0, isBinary: false, isLargeFileCapped: false,
      hasLongLines: false, similarity: 100)
    let renamePure = ChunkTreeBuilder.estimatedHeights(file: renamed, hunks: [])
    #expect(renamePure.unified == topRegion)
    #expect(renamePure.split == topRegion)

    // Positive control: a real one-line hunk DOES reserve paddingBottom (so the skip
    // above is a genuine case-1 carve-out, not paddingBottom being globally absent).
    let withBody = ChunkTreeBuilder.estimatedHeights(
      file: DiffFixture.file(), hunks: [DiffFixture.hunk([DiffFixture.line(.addition, new: 1, "a")])],
      options: ChunkTreeBuilder.Options(expandUnchanged: true))
    #expect(withBody.unified == topRegion + metrics.lineHeight + metrics.paddingBottom)
    #expect(withBody.unified > noHunk.unified + metrics.paddingBottom)
  }

  @Test func estExpandUnchangedRowsNoSeparators() {
    let hunk = DiffFixture.hunk(
      [
        DiffFixture.line(.context, old: 5, new: 5),
        DiffFixture.line(.addition, new: 6),
        DiffFixture.line(.context, old: 6, new: 7),
      ],
      oldStart: 5, newStart: 5
    )
    let expanded = ChunkTreeBuilder.estimatedHeights(
      file: DiffFixture.file(), hunks: [hunk], options: ChunkTreeBuilder.Options(expandUnchanged: true)
    )
    // topRegion + rows×lineHeight + paddingBottom, NO separators.
    let expectedNoSeparators: CGFloat = 44 + 3 * 20 + 8
    #expect(expanded.unified == expectedNoSeparators)
    #expect(expanded.split == expectedNoSeparators)
    // Collapsed (leading gap) adds exactly the first line-info separator (32 + 8).
    let collapsed = ChunkTreeBuilder.estimatedHeights(file: DiffFixture.file(), hunks: [hunk])
    let firstSeparator: CGFloat = 40
    #expect(collapsed.unified == expanded.unified + firstSeparator)
  }

  @Test func hunkSeparatorHeightReducedSet() {
    let metrics = ChunkLayoutMetrics(separatorHeight: 12, simpleSeparatorHeight: 4, spacing: 4)
    #expect(ChunkTreeBuilder.separatorHeight(.first, style: .lineInfo, metrics: metrics) == 16)  // 12 + 4
    #expect(ChunkTreeBuilder.separatorHeight(.middle, style: .lineInfo, metrics: metrics) == 20)  // 4 + 12 + 4
    #expect(ChunkTreeBuilder.separatorHeight(.trailing, style: .lineInfo, metrics: metrics) == 16)  // 4 + 12
    #expect(ChunkTreeBuilder.separatorHeight(.first, style: .simple, metrics: metrics) == 0)
    #expect(ChunkTreeBuilder.separatorHeight(.middle, style: .simple, metrics: metrics) == 4)
    #expect(ChunkTreeBuilder.separatorHeight(.trailing, style: .simple, metrics: metrics) == 0)
  }

  // MARK: - Injected-row accounting

  @Test func injectedRowCountAccounting() {
    let tree = ChunkTreeFixture.uniform(rows: 10)
    #expect(tree.rowCount(.unified) == 10)
    let segmentID = tree.inorderNodes().first!.id
    // Inject a widget "before line 5" → split after row 4, insert at index 4 (N−1).
    let (left, _) = tree.split(segmentID, atLocalRow: 4)
    let widget = Widget(
      key: .commentThread(anchorID: UUID()),
      estimatedHeight: 24,
      payload: .commentThread(anchorID: UUID())
    )
    tree.insert(.widget(widget), after: left)
    #expect(tree.rowCount(.unified) == 11)
    #expect(tree.seek(index: 4, mode: .unified)?.chunk.widget?.reuseKind == .commentThread)
    #expect(ChunkTreeInvariants.check(tree).isEmpty)
  }

  // MARK: - Row-model golden (I5)

  @Test func rowModelGolden() {
    let first = DiffFixture.hunk(
      [
        DiffFixture.line(.context, old: 10, new: 10, "ctx"),
        DiffFixture.line(.deletion, old: 11, "gone"),
        DiffFixture.line(.addition, new: 11, "added"),
        DiffFixture.line(.addition, new: 12, "added2"),
        DiffFixture.line(.context, old: 12, new: 13, "tail"),
      ],
      oldStart: 10, newStart: 10, header: "@@ -10,3 +10,4 @@"
    )
    let second = DiffFixture.hunk(
      [DiffFixture.line(.context, old: 60, new: 62, "c"), DiffFixture.line(.deletion, old: 61, "d", noNewline: true)],
      oldStart: 60, newStart: 62, header: "@@ -60,2 +62,1 @@"
    )
    let tree = ChunkTreeBuilder.build(file: DiffFixture.file(), hunks: [first, second], mode: .unified)
    GoldenText.assert(RowModelProjection.rowModel(tree, mode: .unified), "rowModelUnified")
    GoldenText.assert(RowModelProjection.rowModel(tree, mode: .split), "rowModelSplit")
  }
}
