import AppKit
import CoreText
import Foundation
import Testing

@testable import supacode

/// Phase 8 — split mode: aligned nullable-pair chunks, the O(log #hunks) dual-mode
/// re-seek (NO O(n) reproject), the no-wrap `HScrollSyncController` mirror, the
/// ~900pt inline breakpoint, per-mode `max`-height rows, and the 45° empty-side
/// hatch (C5). Types per TEST-STRATEGY §1.1; consumes I2 (`ChunkTreeFixture`
/// `seekCount` / `buildRowsCallCount` spies), I3 (`CoreTextHarness` /
/// `RecordingContext`), I5 (split projection golden). The 13th row
/// (`splitAlignmentAndHScrollLive`) is MANUAL / release-only.
@MainActor
struct DiffSplitModeTests {
  // MARK: - C 10.1 — aligned pairs: leftovers + dual-mode counts + stable IDs

  @Test func alignedPairLeftoversAndCounts() {
    let dels = [DiffFixture.line(.deletion, old: 10, "a"), DiffFixture.line(.deletion, old: 11, "b")]
    let add = DiffFixture.line(.addition, new: 20, "c")

    // del > add: pair by index, leftover deletion ⇒ `(del,nil)`.
    var seq = PairSequencer()
    let delHeavy = AlignedPairing.pairChange(deletions: dels, additions: [add], seq: &seq)
    #expect(delHeavy.pairs.count == 2)
    #expect(delHeavy.splitLineCount == 2)  // max(del,add)
    #expect(delHeavy.unifiedLineCount == 3)  // del + add (never folded in unified)
    #expect(delHeavy.pairs[0].left?.oldLineNumber == 10)
    #expect(delHeavy.pairs[0].right?.newLineNumber == 20)
    #expect(delHeavy.pairs[0].isContext)  // both sides present on the paired row
    #expect(delHeavy.pairs[1].isPureDeletion)  // `(del,nil)`
    #expect(delHeavy.pairs[1].right == nil)
    #expect(delHeavy.emptyCount(on: .new) == 1)  // one buffer on the additions column
    #expect(delHeavy.emptyCount(on: .old) == 0)

    // add > del: leftover addition ⇒ `(nil,add)`.
    var seq2 = PairSequencer()
    let addHeavy = AlignedPairing.pairChange(
      deletions: [dels[0]], additions: [add, DiffFixture.line(.addition, new: 21, "d")], seq: &seq2)
    #expect(addHeavy.splitLineCount == 2)
    #expect(addHeavy.unifiedLineCount == 3)
    #expect(addHeavy.pairs[1].isPureAddition)  // `(nil,add)`
    #expect(addHeavy.emptyCount(on: .old) == 1)

    // context: each line occupies BOTH sides ⇒ `(ctx,ctx)`.
    var seq3 = PairSequencer()
    let ctx = AlignedPairing.pairContext(
      [DiffFixture.line(.context, old: 1, new: 1), DiffFixture.line(.context, old: 2, new: 2)], seq: &seq3)
    #expect(ctx.splitLineCount == 2)
    #expect(ctx.unifiedLineCount == 2)
    let allContext = ctx.pairs.allSatisfy(\.isContext)
    #expect(allContext)

    // equal-count ⇒ all paired; unified == 2·count, split == count.
    var seq4 = PairSequencer()
    let equal = AlignedPairing.pairChange(
      deletions: dels, additions: [add, DiffFixture.line(.addition, new: 22, "e")], seq: &seq4)
    let allPaired = equal.pairs.allSatisfy { $0.left != nil && $0.right != nil }
    #expect(allPaired)
    #expect(equal.splitLineCount == 2)
    #expect(equal.unifiedLineCount == 4)

    // pairIDs unique + stable across a rebuild (scroll-anchor stability).
    var seqA = PairSequencer()
    var seqB = PairSequencer()
    let buildA = AlignedPairing.pairChange(deletions: dels, additions: [add], seq: &seqA)
    let buildB = AlignedPairing.pairChange(deletions: dels, additions: [add], seq: &seqB)
    #expect(buildA.pairs.map(\.pairID) == buildB.pairs.map(\.pairID))  // stable
    #expect(Set(buildA.pairs.map(\.pairID)).count == buildA.pairs.count)  // unique
  }

  // MARK: - C 10.2 · E 4.1 — mode toggle is O(log #hunks), NOT an O(n) reproject

  @Test func modeToggleSeekCountBounded() {
    let hunkCount = 5000
    let tree = Self.bigHunkTree(hunkCount: hunkCount)
    let controller = ViewportTestSupport.controller()
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)

    // Land the viewport top on a CONTEXT row so the preserved-line assertion is
    // exact (a context row's `(chunkID, localRow)` maps to the same line in both
    // modes; a change row does not). These seeks are BEFORE the snapshot.
    var probe = tree.seek(y: tree.totalHeight(.unified) / 2, mode: .unified)
    while let current = probe, !Self.isContextRow(current, mode: .unified) {
      probe = tree.successor(of: current, mode: .unified)
    }
    guard let contextTop = probe else {
      Issue.record("no context row found")
      return
    }
    controller.scroll(toY: contextTop.yOrigin)
    let beforeHit = tree.seek(y: controller.visibleRect.minY, mode: .unified)

    // Snapshot the spies AROUND the toggle only.
    let seekBefore = tree.diagnostics.seekCount
    let buildBefore = tree.diagnostics.buildRowsCallCount
    controller.toggleMode(to: .split)
    let seekDelta = tree.diagnostics.seekCount - seekBefore

    // (1) NO builder call across the toggle (`buildRowsCallCount == 0` delta).
    #expect(tree.diagnostics.buildRowsCallCount == buildBefore)
    // (2) The re-seek is O(log #hunks) + O(viewport), NEVER ≈ totalRows.
    let logBound = 2 * Int(ceil(log2(Double(hunkCount))))
    let windowRows = controller.totalUsedViewCount
    #expect(seekDelta <= logBound + windowRows + 16, "seekDelta \(seekDelta) exceeded log+viewport bound")
    #expect(seekDelta < tree.rowCount(.split) / 4, "seekDelta \(seekDelta) looks O(n)")

    // (3) The anchored top line re-landed after the toggle (same chunk row → same
    // context line number).
    let afterHit = tree.seek(y: controller.visibleRect.minY, mode: .split)
    #expect(afterHit?.id == beforeHit?.id)
    #expect(afterHit?.localRow == beforeHit?.localRow)
    if let before = beforeHit, let after = afterHit,
      let beforeSeg = before.chunk.lineSegment, let afterSeg = after.chunk.lineSegment
    {
      #expect(
        beforeSeg.renderedRows(.unified)[before.localRow].newNumber
          == afterSeg.renderedRows(.split)[after.localRow].newNumber)
    }
  }

  // MARK: - C 10.3 — h-scroll sync mirrors scrollLeft and drops the echo

  @Test func hScrollSyncMirrorsAndDropsEcho() {
    var applied: [(column: HScrollSyncController.Column, offset: CGFloat)] = []
    var injectEcho = false
    var controllerRef: HScrollSyncController?
    let controller = HScrollSyncController(apply: { column, offset in
      applied.append((column, offset))
      if injectEcho {
        // The mirrored `apply` synchronously re-fires `columnDidScroll` (an NSView
        // bounds-change posts synchronously) — the guard must absorb it.
        controllerRef?.columnDidScroll(column, to: offset)
      }
    })
    controllerRef = controller

    // `columnDidScroll(.left, 120)` ⇒ `apply(.right, 120)` EXACTLY once.
    controller.columnDidScroll(.left, to: 120)
    #expect(applied.count == 1)
    #expect(applied[0].column == .right)
    #expect(applied[0].offset == 120)
    #expect(controller.hScrollOffset == 120)

    // No-op when the offset is unchanged.
    controller.columnDidScroll(.right, to: 120)
    #expect(applied.count == 1)

    // An injected echo is dropped: the mirror fires once, the re-entrant echo does not.
    injectEcho = true
    controller.columnDidScroll(.right, to: 200)
    #expect(controller.hScrollOffset == 200)
    #expect(applied.count == 2)  // the .left mirror only; the echo was dropped
    #expect(applied[1].column == .left)
    #expect(applied[1].offset == 200)
  }

  // MARK: - C 10.4 — ~900pt inline breakpoint (view-only) + presentation selection

  @Test func effectiveModeInlineBreakpoint() {
    #expect(SplitColumnLayout.inlineBreakpoint == 900)
    // Split coerces to inline (unified) BELOW 900pt — view-only, stored flag intact.
    #expect(SplitColumnLayout.effectiveMode(stored: .split, availableWidth: 500) == .unified)
    #expect(SplitColumnLayout.effectiveMode(stored: .split, availableWidth: 899) == .unified)
    // Stays split at ≥ 900pt (widening restores it).
    #expect(SplitColumnLayout.effectiveMode(stored: .split, availableWidth: 900) == .split)
    #expect(SplitColumnLayout.effectiveMode(stored: .split, availableWidth: 1400) == .split)
    // Unified is NEVER coerced.
    #expect(SplitColumnLayout.effectiveMode(stored: .unified, availableWidth: 300) == .unified)
    #expect(SplitColumnLayout.effectiveMode(stored: .unified, availableWidth: 1400) == .unified)
    // presentation: wrap ⇒ our single-row divergence; no-wrap ⇒ pierre two columns.
    #expect(SplitColumnLayout.presentation(wrap: true) == .wrapSingleRow)
    #expect(SplitColumnLayout.presentation(wrap: false) == .noWrapTwoColumns)
  }

  // MARK: - C 10.5 — row height is max(left,right); heights measured per mode

  @Test func rowHeightIsMaxOfSides() {
    #expect(SplitColumnLayout.rowHeight(leftHeight: 20, rightHeight: 40) == 40)
    #expect(SplitColumnLayout.rowHeight(leftHeight: 60, rightHeight: 20) == 60)
    #expect(SplitColumnLayout.rowHeight(leftHeight: 20, rightHeight: 20) == 20)
    // A nil side reports the bare line height — a wrapped counterpart still wins.
    #expect(SplitColumnLayout.rowHeight(leftHeight: 20, rightHeight: 80) == 80)

    // Heights are MODE-KEYED: a change leaf's split est (max(del,add)·h) is distinct
    // from its unified est (del+add)·h — never reuse unified heights in split.
    let dels = (0..<4).map { DiffFixture.line(.deletion, old: 1 + $0, "d\($0)") }
    let adds = (0..<2).map { DiffFixture.line(.addition, new: 1 + $0, "a\($0)") }
    let segment = LineSegment(
      hunkID: HunkID(fileID: "f", index: 0), lines: dels + adds, window: 0..<6, classification: .change)
    let summary = segment.baseSummary(metrics: .production)
    #expect(summary.unifiedCount == 6)  // 4 del + 2 add
    #expect(summary.splitCount == 4)  // max(4,2)
    #expect(summary.splitEstHeight != summary.unifiedEstHeight)  // per-mode, not reused

    var seq = PairSequencer()
    let chunk = segment.alignedPairChunk(seq: &seq)
    #expect(chunk.splitLineCount == 4)
    #expect(chunk.unifiedLineCount == 6)
  }

  // MARK: - C 10.6 (C5) — 45° empty-side hatch strokes stripes, captured as tokens

  @Test func emptySideHatchDrawsStripes() {
    let rect = CGRect(x: 0, y: 0, width: 200, height: 20)
    let recorder = RecordingContext()
    EmptySideHatch.draw(in: rect, tint: .quaternaryLabelColor, into: recorder)
    let fills = recorder.filledRects
    #expect(fills.count > 1)  // NON-FLAT: base wash + many stripe fills

    // The FIRST fill is the full-rect base wash; the rest are the 45° stripes in a
    // distinct (stronger) color token.
    #expect(fills[0].rect == rect)
    let baseColor = fills[0].color
    let stripeColor = fills[1].color
    #expect(baseColor != stripeColor)
    for entry in fills[1...] {
      #expect(entry.color == stripeColor)  // one stripe color token throughout
      // Every stripe rect is clipped INSIDE the pane (no spill onto the gutter/divider).
      #expect(entry.rect.minX >= rect.minX - 0.001)
      #expect(entry.rect.maxX <= rect.maxX + 0.001)
      #expect(entry.rect.minY >= rect.minY - 0.001)
      #expect(entry.rect.maxY <= rect.maxY + 0.001)
    }

    // Pitch == pierre √2 spacing (`stripeWidth·2·√2`); consecutive stripe origins
    // differ by exactly that.
    #expect(abs(EmptySideHatch.pitch - EmptySideHatch.stripeWidth * 2 * 1.414) < 1e-9)
    let origins = EmptySideHatch.stripeOriginXs(in: rect)
    #expect(origins.count >= 2)
    for index in 1..<origins.count {
      #expect(abs((origins[index] - origins[index - 1]) - EmptySideHatch.pitch) < 1e-9)
    }
  }

  // MARK: - C 10.7 — no-newline markers survive as extra one-sided split rows

  @Test func noNewlineMarkerPreservedInSplit() {
    // A change block whose last deletion AND addition both lack a trailing newline.
    let dels = [DiffFixture.line(.deletion, old: 1, "old", noNewline: true)]
    let adds = [DiffFixture.line(.addition, new: 1, "new", noNewline: true)]
    let segment = LineSegment(
      hunkID: HunkID(fileID: "f", index: 0), lines: dels + adds, window: 0..<2, classification: .change)

    let (unifiedNoNL, splitNoNL) = segment.noNewlineCounts()
    #expect(unifiedNoNL == 2)  // one marker per flagged SIDE
    #expect(splitNoNL == 1)  // a single shared marker row for the aligned pair

    let summary = segment.baseSummary(metrics: .production)
    #expect(summary.unifiedCount == 4)  // 1 del + 1 add + 2 markers
    #expect(summary.splitCount == 2)  // 1 pair + 1 shared marker
    // Counts don't drift: rendered rows == baseSummary count in EACH mode.
    #expect(segment.renderedRows(.unified).count == summary.unifiedCount)
    #expect(segment.renderedRows(.split).count == summary.splitCount)

    let splitRows = segment.renderedRows(.split)
    #expect(splitRows[0].isMarker == false)
    #expect(splitRows[1].isMarker == true)  // the preserved no-newline marker row
  }

  // MARK: - A §8 (I5) — split add/del column projection golden

  @Test func splitProjectionGolden() {
    let hunks = [
      DiffFixture.hunk(
        [
          DiffFixture.line(.context, old: 1, new: 1, "ctx"),
          DiffFixture.line(.deletion, old: 2, "removed"),
          DiffFixture.line(.deletion, old: 3, "removed2"),
          DiffFixture.line(.addition, new: 2, "added"),
          DiffFixture.line(.context, old: 4, new: 3, "ctx2"),
        ], oldStart: 1, newStart: 1, header: "@@ -1,4 +1,3 @@")
    ]
    let tree = ChunkTreeFixture.files(
      [.init(file: DiffFixture.file(), hunks: hunks)],
      options: ChunkTreeBuilder.Options(disableFileHeader: true))
    GoldenText.assert(RowModelProjection.splitColumnModel(tree), "splitProjectionGolden")
  }

  // MARK: - A §8 — ONE buffer of the surplus on the SHORTER side, both directions

  @Test func splitBufferOnShorterSide() {
    // del-heavy: 3 del, 1 add ⇒ 2 buffers on the additions (new) column.
    var seq = PairSequencer()
    let delHeavy = AlignedPairing.pairChange(
      deletions: (0..<3).map { DiffFixture.line(.deletion, old: 1 + $0, "d") },
      additions: [DiffFixture.line(.addition, new: 1, "a")], seq: &seq)
    #expect(delHeavy.emptyCount(on: .new) == 2)  // == change-block surplus (3 − 1)
    #expect(delHeavy.emptyCount(on: .old) == 0)

    // add-heavy (the other direction): 1 del, 3 add ⇒ 2 buffers on the deletions side.
    var seq2 = PairSequencer()
    let addHeavy = AlignedPairing.pairChange(
      deletions: [DiffFixture.line(.deletion, old: 1, "d")],
      additions: (0..<3).map { DiffFixture.line(.addition, new: 1 + $0, "a") }, seq: &seq2)
    #expect(addHeavy.emptyCount(on: .old) == 2)
    #expect(addHeavy.emptyCount(on: .new) == 0)

    // pure-delete collapses to ONE column — the new side has no content at all.
    var seq3 = PairSequencer()
    let pureDelete = AlignedPairing.pairChange(
      deletions: (0..<3).map { DiffFixture.line(.deletion, old: 1 + $0, "d") }, additions: [], seq: &seq3)
    #expect(pureDelete.hasContent(on: .new) == false)
    #expect(pureDelete.hasContent(on: .old) == true)
    #expect(pureDelete.emptyCount(on: .new) == 3)

    // pure-add collapses the other way.
    var seq4 = PairSequencer()
    let pureAdd = AlignedPairing.pairChange(
      deletions: [], additions: (0..<2).map { DiffFixture.line(.addition, new: 1 + $0, "a") }, seq: &seq4)
    #expect(pureAdd.hasContent(on: .old) == false)
    #expect(pureAdd.emptyCount(on: .old) == 2)

    // Each buffer cell renders the 45° hatch (extends C 10.6): not a flat fill.
    let recorder = RecordingContext()
    EmptySideHatch.draw(in: CGRect(x: 0, y: 0, width: 100, height: 20), into: recorder)
    #expect(recorder.filledRects.count > 1)
  }

  // MARK: - B §16 — injected split row keeps the additions column row-aligned

  @Test func injectedRowSplitBufferAlignment() {
    // A change block: deletion 5 pairs with addition 7; deletion 6 is unpaired, so
    // the additions column shows a buffer row-aligned with it (the pierre
    // `[data-content-buffer]` spacer analog — our nil-side hatch pane).
    let hunks = [
      DiffFixture.hunk(
        [
          DiffFixture.line(.deletion, old: 5, "del-a"),
          DiffFixture.line(.deletion, old: 6, "del-b"),
          DiffFixture.line(.addition, new: 7, "add"),
        ], oldStart: 5, newStart: 7, header: "@@ -5,2 +7,1 @@")
    ]
    let tree = ChunkTreeFixture.files(
      [.init(file: DiffFixture.file(), hunks: hunks)],
      options: ChunkTreeBuilder.Options(disableFileHeader: true))
    let controller = ViewportTestSupport.controller()
    controller.apply(tree: tree, mode: .split, scrollPreserving: false)

    // The change leaf projects `splitLineCount == max(2,1) == 2` aligned rows.
    let changeLeaf = tree.inorderNodes().compactMap { $0.chunk.lineSegment }.first { $0.classification == .change }
    #expect(changeLeaf?.baseSummary(metrics: .production).splitCount == 2)
    let splitRows = changeLeaf?.renderedRows(.split) ?? []
    #expect(splitRows.count == 2)
    // Row 0: paired (del 5 ↔ add 7) — both columns carry content.
    #expect(splitRows[0].oldNumber == 5)
    #expect(splitRows[0].newNumber == 7)
    // Row 1: unpaired deletion 6 ⇒ the additions column is a buffer (nil new side),
    // keeping the columns row-aligned rather than collapsing.
    #expect(splitRows[1].oldNumber == 6)
    #expect(splitRows[1].newNumber == nil)

    // Injecting a comment widget on the paired addition adds ONE full-width wrapper
    // row (not one per column); the buffer alignment survives.
    let before = tree.rowCount(.split)
    let anchor = UUID()
    let inserted = controller.insertCommentWidget(
      side: .new, startLine: 7, endLine: 7, anchorID: anchor, estimatedHeight: 40)
    #expect(inserted != nil)
    #expect(tree.rowCount(.split) == before + 1)  // +1 wrapper, columns still aligned
    #expect(tree.widgetNode(for: .commentThread(anchorID: anchor))?.chunk.widget != nil)
  }

  // MARK: - B §15 — a both-sides annotation stays SEPARATE in split (1 slot each)

  @Test func widgetSplitColumnAlignment() {
    let hunks = [
      DiffFixture.hunk(
        [
          DiffFixture.line(.context, old: 1, new: 1, "a"),
          DiffFixture.line(.context, old: 2, new: 2, "b"),
          DiffFixture.line(.context, old: 3, new: 3, "c"),
        ], header: "@@ -1,3 +1,3 @@")
    ]
    let tree = ChunkTreeFixture.files(
      [.init(file: DiffFixture.file(), hunks: hunks)],
      options: ChunkTreeBuilder.Options(disableFileHeader: true))
    let controller = ViewportTestSupport.controller()
    controller.apply(tree: tree, mode: .split, scrollPreserving: false)
    let before = tree.rowCount(.split)

    // A both-sides-same-line annotation (comment on line 2) injects ONE full-width
    // wrapper slot; it must NOT collapse the split columns.
    let anchor = UUID()
    let inserted = controller.insertCommentWidget(
      side: .new, startLine: 2, endLine: 2, anchorID: anchor, estimatedHeight: 40)
    #expect(inserted != nil)
    #expect(tree.rowCount(.split) == before + 1)  // exactly one wrapper, not per-column
    #expect(tree.widgetNode(for: .commentThread(anchorID: anchor))?.chunk.widget != nil)

    // Columns stay aligned: the surrounding context rows still project BOTH sides.
    var bothSided = 0
    for node in tree.inorderNodes() {
      guard let segment = node.chunk.lineSegment, segment.classification == .context else { continue }
      for row in segment.renderedRows(.split) where row.oldNumber != nil && row.newNumber != nil { bothSided += 1 }
    }
    #expect(bothSided == 3)  // all three context lines keep 1 slot on each side
  }

  // MARK: - A §15 · B §9 — a side-pinned endpoint selects the requested column

  @Test func revealSplitSideSelectsColumn() {
    let hunks = [
      DiffFixture.hunk(
        [
          DiffFixture.line(.context, old: 4, new: 6, "ctx"),
          DiffFixture.line(.deletion, old: 5, "removed"),
          DiffFixture.line(.addition, new: 7, "added"),
          DiffFixture.line(.context, old: 6, new: 8, "ctx2"),
        ], oldStart: 4, newStart: 6, header: "@@ -4,3 +6,3 @@")
    ]
    let tree = ChunkTreeFixture.files(
      [.init(file: DiffFixture.file(), hunks: hunks)],
      options: ChunkTreeBuilder.Options(disableFileHeader: true))
    let controller = ViewportTestSupport.controller()
    controller.apply(tree: tree, mode: .split, scrollPreserving: false)

    guard let delLoc = controller.lineLocation(line: 5, side: .old),
      let rowHit = tree.seek(index: delLoc.rowIndex, mode: .split)
    else {
      Issue.record("no aligned change row")
      return
    }
    let midY = rowHit.yOrigin + rowHit.rowHeight / 2
    let width = controller.documentView.bounds.width
    let gutterW = controller.gutterWidth
    let bands = DiffHitTest.bands(mode: .split, width: width, gutterW: gutterW)

    // OLD side x-band → the deletions column resolves old line 5.
    let oldBand = bands.first { $0.column == .content(.old) }!
    let oldHit = controller.hitTest(CGPoint(x: oldBand.range.lowerBound + 1, y: midY))
    #expect(oldHit?.side == .old)
    #expect(oldHit?.lineNumber == 5)
    #expect(oldHit?.column == .content(.old))

    // NEW side x-band → the additions column resolves new line 7.
    let newBand = bands.first { $0.column == .content(.new) }!
    let newHit = controller.hitTest(CGPoint(x: newBand.range.lowerBound + 1, y: midY))
    #expect(newHit?.side == .new)
    #expect(newHit?.lineNumber == 7)
    #expect(newHit?.column == .content(.new))

    // A side-PINNED endpoint (a range-drag pinned to a side, `requireNumberColumn:
    // false`) resolves against the requested side even over the OTHER column's band.
    let pinnedOld = controller.hitTest(CGPoint(x: newBand.range.lowerBound + 1, y: midY), side: .old)
    #expect(pinnedOld?.side == .old)
    #expect(pinnedOld?.lineNumber == 5)
  }

  // MARK: - D GHT — split-midline hit over a wide char clamps to the cluster edge

  @Test func hitTestSplitMidlineOverWideChar() {
    // "a👍b": the 👍 is an astral surrogate pair occupying UTF-16 [1,3); index 2 is
    // an interior surrogate that a hit must NEVER resolve to.
    let content = UnicodeFixtures.emojiThumb as NSString
    let ctLine = CoreTextHarness.ctLine(content)

    // The composed-sequence boundaries — the only valid resolved indices.
    var boundaries: Set<Int> = [content.length]
    var cursor = 0
    while cursor < content.length {
      boundaries.insert(cursor)
      cursor = NSMaxRange(content.rangeOfComposedCharacterSequence(at: cursor))
    }

    // The split NEW-pane content band is where a right-column midline hit lands; the
    // band offset cancels into CTLine (content-relative) space.
    let bands = DiffHitTest.bands(mode: .split, width: 800, gutterW: 48)
    let contentBand = bands.first { $0.column == .content(.new) }!
    let contentStartX = contentBand.range.lowerBound

    let lineWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
    var sawEmojiEdge = false
    var sweepX: CGFloat = 0
    while sweepX <= lineWidth {
      // A document-space x inside the split content band → content-relative x.
      let contentX = (contentStartX + sweepX) - contentStartX
      let index = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: contentX, y: 0))
      #expect(boundaries.contains(index), "x=\(sweepX) resolved \(index), not a cluster boundary")
      #expect(index != 2, "resolved an interior surrogate index over the emoji")
      if index == 1 || index == 3 { sawEmojiEdge = true }
      sweepX += 1
    }
    #expect(sawEmojiEdge)  // the sweep actually crossed the emoji cluster
  }

  // MARK: - Fixtures

  /// A ≥5000-hunk tree (for the toggle seek-bound assertion): each hunk is a small
  /// change block flanked by context, spaced so inter-hunk gaps collapse to
  /// expanders. Built through the REAL builder via `ChunkTreeFixture.files`.
  private static func bigHunkTree(hunkCount: Int) -> ChunkTree {
    var hunks: [DiffHunk] = []
    hunks.reserveCapacity(hunkCount)
    var start = 1
    for index in 0..<hunkCount {
      let lines = [
        DiffFixture.line(.context, old: start, new: start, "c0"),
        DiffFixture.line(.context, old: start + 1, new: start + 1, "c1"),
        DiffFixture.line(.deletion, old: start + 2, "old\(index)"),
        DiffFixture.line(.addition, new: start + 2, "new\(index)"),
        DiffFixture.line(.context, old: start + 3, new: start + 3, "c3"),
      ]
      hunks.append(
        DiffFixture.hunk(lines, oldStart: start, newStart: start, header: "@@ hunk \(index) @@"))
      start += 20  // a 15-line gap between hunks → a collapsed expander
    }
    return ChunkTreeFixture.files([.init(file: DiffFixture.file(), hunks: hunks)])
  }

  /// Whether a hit resolves to a plain context code row (mode-independent line).
  private static func isContextRow(_ hit: ChunkHit, mode: DiffViewMode) -> Bool {
    guard let segment = hit.chunk.lineSegment, segment.classification == .context else { return false }
    let rows = segment.renderedRows(mode)
    guard rows.indices.contains(hit.localRow) else { return false }
    return rows[hit.localRow].origin == .context && !rows[hit.localRow].isMarker
  }
}
