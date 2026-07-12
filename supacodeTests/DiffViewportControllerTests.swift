import AppKit
import Testing

@testable import supacode

/// Phase 2 — the custom flipped-`documentView` viewport: seek-driven
/// virtualization, identity scroll-anchor survival, per-`reuseKind` recycling,
/// visible-range dedupe, the inert measure guard, and the tree↔viewport seam
/// (S1 / S1b / S1c). NSVIEW-HEADLESS: a real `NSScrollView`/`NSClipView` with no
/// window; live scrolling smoothness is Release-only manual QA (an autonomous run
/// cannot drive a live GUI).
@MainActor
struct DiffViewportControllerTests {
  // MARK: - Seam 1.1 — seek(y) == brute-force leaf; ChunkHit field aliases

  @Test func seekYReturnsChunkViewportMaterializesBothModes() {
    let tree = changeAndContextTree()
    for mode in [DiffViewMode.unified, .split] {
      let total = tree.totalHeight(mode)
      var sweepY: CGFloat = 0
      while sweepY < total {
        guard let hit = tree.seek(y: sweepY, mode: mode) else {
          Issue.record("nil seek at y=\(sweepY)")
          break
        }
        // Independent oracle: which leaf contains sweepY by summing summary heights.
        #expect(hit.id == bruteForceLeaf(tree, y: sweepY, mode: mode))
        #expect(hit.yOrigin <= sweepY)
        #expect(sweepY < hit.yOrigin + hit.rowHeight)
        // Field-alias reconciliation (S1b): the canonical `rowIndex` / `rowHeight`
        // and their `index` / `height` aliases resolve to the same stored value —
        // compile-forcing the seam so a spelling drift fails the build, not silently.
        #expect(hit.index == hit.rowIndex)
        #expect(hit.height == hit.rowHeight)
        sweepY += 7
      }
      let controller = ViewportTestSupport.controller()
      controller.apply(tree: tree, mode: mode, scrollPreserving: false)
      #expect(controller.totalUsedViewCount > 0)
    }
  }

  // MARK: - 2.5 anchor above re-lands same pixel

  @Test func anchorAbove() {
    let controller = ViewportTestSupport.controller()
    let old = ViewportTestSupport.contextLeaves(Array(1...200))
    controller.apply(tree: old, mode: .unified, scrollPreserving: false)
    controller.scroll(toY: 1000)  // line 51 (index 50) sits exactly at the top, offset 0
    #expect(controller.scrollView.contentView.bounds.origin.y == 1000)

    // Insert 10 leaves (200pt) ABOVE line 51 → it shifts down to y=1200.
    let new = ViewportTestSupport.contextLeaves(Array(900...909) + Array(1...200))
    controller.apply(tree: new, mode: .unified, scrollPreserving: true)
    #expect(abs(controller.scrollView.contentView.bounds.origin.y - 1200) < 0.5)
  }

  // MARK: - 2.6 anchor below — no jump

  @Test func anchorBelow() {
    let controller = ViewportTestSupport.controller()
    let old = ViewportTestSupport.contextLeaves(Array(1...200))
    controller.apply(tree: old, mode: .unified, scrollPreserving: false)
    controller.scroll(toY: 1000)
    let oldTotal = old.totalHeight(.unified)

    let new = ViewportTestSupport.contextLeaves(Array(1...200) + Array(900...909))
    controller.apply(tree: new, mode: .unified, scrollPreserving: true)
    #expect(abs(controller.scrollView.contentView.bounds.origin.y - 1000) < 0.5)  // unchanged
    #expect(new.totalHeight(.unified) == oldTotal + 200)  // scrollbar grows, anchor still
  }

  // MARK: - 2.7 collapsed anchor → nearest surviving, not top

  @Test func anchorCollapsedFallsBackToNearest() {
    let controller = ViewportTestSupport.controller()
    let old = ViewportTestSupport.contextLeaves(Array(1...200))
    controller.apply(tree: old, mode: .unified, scrollPreserving: false)
    controller.scroll(toY: 1000)  // anchor = line 51

    // Remove line 51's leaf entirely; the anchor identity no longer materializes.
    let new = ViewportTestSupport.contextLeaves(Array(1...50) + Array(52...200))
    controller.apply(tree: new, mode: .unified, scrollPreserving: true)
    let originY = controller.scrollView.contentView.bounds.origin.y
    #expect(originY != 0)  // NOT a hard reset to the top
    #expect(abs(originY - 980) < 0.5)  // nearest surviving = line 50 at y=980
  }

  // MARK: - Seam 1.2/1.3 growth arm — anchor survives split→unified growth

  @Test func anchorSurvivesSplitToUnifiedGrowth() {
    let controller = ViewportTestSupport.controller()
    let tree = changeThenContextTree()  // change: split 5 rows / unified 10 rows, then context
    controller.apply(tree: tree, mode: .split, scrollPreserving: false)
    controller.scroll(toY: 200)  // in split, context line 105 sits at the top (offset 0)

    controller.apply(tree: tree, mode: .unified, scrollPreserving: true)
    // In unified the change grew by 5 rows (100pt): line 105 is now at y=300 and
    // its identity survived the mode toggle, re-landing at the same top pixel.
    #expect(controller.windowMap[.line(lineNumber: 105, side: .new)] == 300)
    #expect(abs(controller.scrollView.contentView.bounds.origin.y - 300) < 0.5)
  }

  // MARK: - Note A guard — the restore reads a bounded window map, not a line→y index

  @Test func anchorWindowMapIsBounded() {
    func windowCountAtMiddle(lines: Int) -> Int {
      let controller = ViewportTestSupport.controller()
      let tree = ViewportTestSupport.contextLeaves(Array(1...lines))
      controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
      controller.scroll(toY: tree.totalHeight(.unified) / 2)
      return controller.windowMap.count
    }
    let small = windowCountAtMiddle(lines: 2000)
    let big = windowCountAtMiddle(lines: 4000)
    #expect(small == big)  // window size, independent of tree size
    #expect(small < 200)  // ≈ visible rows + overscan, NOT the 2000 / 4000 total
  }

  // MARK: - 2.8 restore clamps at the tail (pure geometry)

  @Test func restoreClampsAtTail() {
    // Past the tail → clamp to docHeight − clipHeight.
    #expect(ScrollAnchor.clampedTargetY(anchorY: 5000, pixelOffset: 0, documentHeight: 5200, clipHeight: 600) == 4600)
    // Above the top → clamp to 0.
    #expect(ScrollAnchor.clampedTargetY(anchorY: 100, pixelOffset: 300, documentHeight: 5200, clipHeight: 600) == 0)
    // In range → exact.
    #expect(ScrollAnchor.clampedTargetY(anchorY: 1000, pixelOffset: 0, documentHeight: 5200, clipHeight: 600) == 1000)
    // Document shorter than the clip → 0.
    #expect(ScrollAnchor.clampedTargetY(anchorY: 50, pixelOffset: 0, documentHeight: 400, clipHeight: 600) == 0)
  }

  // MARK: - scroll clamps when content shrinks below the current offset

  @Test func scrollClampsOnContentShrink() {
    let controller = ViewportTestSupport.controller()
    let big = ViewportTestSupport.contextLeaves(Array(1...1000))  // total 20000
    controller.apply(tree: big, mode: .unified, scrollPreserving: false)
    controller.scroll(toY: 19000)  // near the tail

    let small = ViewportTestSupport.contextLeaves(Array(1...5))  // total 100 < clip height
    controller.apply(tree: small, mode: .unified, scrollPreserving: false)
    let originY = controller.scrollView.contentView.bounds.origin.y
    let clipHeight = controller.scrollView.contentView.bounds.height
    #expect(originY <= max(0, small.totalHeight(.unified) - clipHeight) + 0.5)
    #expect(originY == 0)  // document shorter than the clip → parked at the top
  }

  // MARK: - 2.9 live view count bounded by the window, independent of tree size

  @Test func recyclePoolViewCountBoundedByWindow() {
    func usedAtMiddle(count: Int) -> Int {
      let controller = ViewportTestSupport.controller()
      let tree = ViewportTestSupport.widgets(count: count)
      controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
      controller.scroll(toY: tree.totalHeight(.unified) / 2)
      return controller.totalUsedViewCount
    }
    let small = usedAtMiddle(count: 3000)
    let big = usedAtMiddle(count: 6000)
    #expect(small == big)  // independent of the 3000 / 6000 total
    #expect(small > 0)
    #expect(small < 200)  // ≈ viewport + overscan, not the whole tree
  }

  // MARK: - 2.10 pools are homogeneous per reuseKind

  @Test func recycleDequeuesByReuseKind() {
    let controller = ViewportTestSupport.controller()
    controller.apply(tree: interleavedLinesAndWidgets(), mode: .unified, scrollPreserving: false)

    let lineViews = controller.pools[.line]?.used.values.map { $0 } ?? []
    let widgetViews = controller.pools[.widget(.expander)]?.used.values.map { $0 } ?? []
    #expect(!lineViews.isEmpty)
    #expect(!widgetViews.isEmpty)
    for view in lineViews { #expect(view is LineRowView) }
    for view in widgetViews { #expect(view is WidgetHostChunkView) }
    // Scroll away and back: a line chunk re-materializes with a LineRowView from
    // the line pool — a header pool never yields a line, and vice-versa.
    controller.scroll(toY: 10000)
    controller.scroll(toY: 0)
    let lineViewsAfter = controller.pools[.line]?.used.values.map { $0 } ?? []
    for view in lineViewsAfter { #expect(view is LineRowView) }
  }

  // MARK: - 2.11 one-jump fling recycles everything, no leak

  @Test func recyclePoolNoLeakOnFastFling() {
    let controller = ViewportTestSupport.controller()
    let tree = ViewportTestSupport.widgets(count: 5000)  // total 100000
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
    let topKeys = Set(controller.pools[.widget(.expander)]?.used.keys.map { $0 } ?? [])
    #expect(!topKeys.isEmpty)

    controller.scroll(toY: 90000)  // one jump far past the overscan
    let afterKeys = Set(controller.pools[.widget(.expander)]?.used.keys.map { $0 } ?? [])
    #expect(topKeys.isDisjoint(with: afterKeys))  // every top view recycled
    #expect(controller.totalUsedViewCount > 0)  // new window materialized, no crash
  }

  // MARK: - 2.12 visible-range callback dedupes

  @Test func fireVisibleRangeDedupes() {
    let controller = ViewportTestSupport.controller()
    var fires = 0
    controller.onVisibleRangeChanged = { _ in fires += 1 }
    let tree = ViewportTestSupport.contextLeaves(Array(1...500))
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
    #expect(fires == 1)  // 0..<0 → the initial range
    controller.layoutVisibleChunks()  // same position → no fire
    #expect(fires == 1)
    controller.scroll(toY: 2000)  // range changes → fires
    #expect(fires == 2)
  }

  // MARK: - 2.13 measure guard is present but inert (fixed heights)

  @Test func measureGuardScaffoldInert() {
    let controller = ViewportTestSupport.controller()
    let tree = ViewportTestSupport.contextLeaves(Array(1...500))
    let before = tree.totalHeight(.unified)
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
    controller.scroll(toY: 2000)
    controller.scroll(toY: 5000)
    controller.layoutVisibleChunks()
    #expect(controller.measurePass == 0)  // epsilon / 5-pass guard never fired
    #expect(tree.totalHeight(.unified) == before)  // no measured delta written back
  }

  // MARK: - Seam 1.4 — WidgetKey resolves the right MODEL after a pool recycle

  @Test func widgetKeyResolvesModelAfterRecycle() {
    let controller = ViewportTestSupport.controller()
    let idA = UUID()
    let idB = UUID()
    let tree = ChunkTree(metrics: .production)
    var after: ChunkID? = tree.insert(ViewportTestSupport.commentWidget(id: idA), after: nil)
    let aID = after!
    for line in 1...300 { after = tree.insert(contextLeaf(line), after: after) }
    let bID = tree.insert(ViewportTestSupport.commentWidget(id: idB), after: after)
    after = bID
    for line in 301...400 { after = tree.insert(contextLeaf(line), after: after) }

    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)  // top: A visible
    let viewA = controller.pools[.widget(.commentThread)]?.getView(forKey: aID)
    #expect((viewA as? WidgetHostChunkView)?.mountedKey == .commentThread(anchorID: idA))

    controller.scroll(toY: 3000)  // neither A nor B visible → A recycled off
    #expect(controller.pools[.widget(.commentThread)]?.getView(forKey: aID) == nil)

    controller.scroll(toY: 6120)  // B materializes, dequeuing A's freed pool view
    let viewB = controller.pools[.widget(.commentThread)]?.getView(forKey: bID)
    #expect(viewB === viewA)  // SAME recycled instance (ChunkID keys the view)
    // …resolved to B's MODEL via WidgetKey, never A's stale model.
    #expect((viewB as? WidgetHostChunkView)?.mountedKey == .commentThread(anchorID: idB))
  }

  // MARK: - Differential oracle — windowed seek == full-render slice, both modes

  @Test func windowedRenderEqualsFullSlice() {
    let tree = changeAndContextTree()
    for mode in [DiffViewMode.unified, .split] {
      let rows = fullRows(tree, mode: mode)
      let rect = CGRect(x: 0, y: 25, width: 800, height: 90)
      let intersecting = rows.filter { $0.yOrigin < rect.maxY && $0.yOrigin + $0.height > rect.minY }
      let range = tree.indexRange(in: rect, mode: mode)
      #expect(range.lowerBound == intersecting.first?.index)
      #expect(range.upperBound == (intersecting.last?.index).map { $0 + 1 })
    }
  }

  // MARK: - Off-screen file reserves its estimate pre-typeset (B §19)

  @Test func estimatedPlaceholderHeightFormula() {
    let metrics = ChunkLayoutMetrics.production
    let file = DiffFixture.file()
    let hunk = DiffFixture.hunk((1...30).map { DiffFixture.line(.context, old: $0, new: $0, "l\($0)") })
    let tree = ChunkTreeFixture.files(
      [.init(file: file, hunks: [hunk])],
      options: ChunkTreeBuilder.Options(expandUnchanged: true)
    )
    // Reserved = fileHeader (diffHeaderHeight) + hunkHeader (separatorHeight) +
    // rows × lineHeight — the off-screen estimate that keeps scrollbar / anchor
    // correct before the file is ever typeset.
    let expected = metrics.diffHeaderHeight + metrics.separatorHeight + 30 * metrics.lineHeight
    #expect(tree.totalHeight(.unified) == expected)

    let controller = ViewportTestSupport.controller()
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
    controller.scroll(toY: tree.totalHeight(.unified))  // materialize the whole file
    #expect(tree.totalHeight(.unified) == expected)  // reservation unchanged post-materialize
  }

  // MARK: - frame(forChunk:) geometry API (Phase 6 gutter / Phase 10 spy)

  @Test func frameForChunkReturnsGeometry() {
    let controller = ViewportTestSupport.controller()
    let tree = ViewportTestSupport.contextLeaves(Array(1...100))
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
    let ids = tree.inorderNodes().map(\.id)
    let frame = controller.frame(forChunk: ids[10])
    #expect(frame?.minY == 200)  // leaf 10 at y = 200
    #expect(frame?.height == 20)  // one-line leaf
    #expect(controller.frame(forChunk: ChunkID(raw: 999_999)) == nil)
  }

  // MARK: - 1M-row scroll stays bounded (automated proxy for the MANUAL smoke)

  @Test func millionRowTreeScrollsWithBoundedViewCount() {
    let controller = ViewportTestSupport.controller()
    let tree = ChunkTreeFixture.uniform(rows: 1_000_000)
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
    let total = tree.totalHeight(.unified)
    for step in 0...20 {
      controller.scroll(toY: total * CGFloat(step) / 20)
      #expect(controller.totalUsedViewCount > 0)
      #expect(controller.totalUsedViewCount < 10)  // bounded, independent of 1M rows
    }
  }

  // MARK: - B §15 — a comment widget anchors to (lineNumber, side); below in
  //          unified, spanning both columns in split

  @Test func widgetAnchorsToOwnerLineSide() {
    for mode in [DiffViewMode.unified, .split] {
      let controller = ViewportTestSupport.controller()
      controller.apply(tree: ViewportTestSupport.contextLeaves(Array(1...10)), mode: mode, scrollPreserving: false)
      let ownerBottom = controller.lineRect(line: 5, side: .new)?.maxY
      let nextID = controller.lineLocation(line: 6, side: .new)?.chunkID
      let nextBefore = nextID.flatMap { controller.frame(forChunk: $0)?.minY }

      let anchorID = UUID()
      let widgetID = controller.insertCommentWidget(
        side: .new, startLine: 5, endLine: 5, anchorID: anchorID, estimatedHeight: 60)
      #expect(widgetID != nil)

      // Anchored BELOW the owner line: the widget's top == the owner line's bottom.
      #expect(controller.frame(forChunk: widgetID!)?.minY == ownerBottom)
      // Line 6 is pushed down by the widget; the owner line (5) is unaffected.
      let nextAfter = nextID.flatMap { controller.frame(forChunk: $0)?.minY }
      #expect(nextAfter == (nextBefore ?? 0) + 60)

      // Spans BOTH columns: a widget is ONE full-width row in either mode (in split
      // it crosses the mid divider covering the old AND new panes, not two rows).
      #expect(controller.tree.widgetNode(for: .commentThread(anchorID: anchorID))?.summary.count(mode) == 1)
      #expect(controller.frame(forChunk: widgetID!)?.width == controller.documentView.bounds.width)
      let placed = controller.pools[.widget(.commentThread)]?.getView(forKey: widgetID!)
      #expect(placed?.frame.minX == 0)
      #expect(placed?.frame.width == controller.documentView.bounds.width)
    }
  }

  // MARK: - B §15 — both-sides-same-line: 1 element / 2 slots unified vs separate
  //          cells in split

  @Test func unifiedCollapseSplitSeparateAnnotation() {
    // A context line carrying BOTH an old and a new number (old == new == 4) — the
    // "both-sides-same-line" case a comment can anchor to from either side.
    let controller = ViewportTestSupport.controller()
    let rowYForLine4 = CGFloat(4 - 1) * 20 + 10

    // UNIFIED: one rendered row holds both number slots. The old and new gutter
    // bands are adjacent within the SAME content row (one element, two slots): both
    // hits resolve to line 4 on the SAME chunk.
    controller.apply(tree: ViewportTestSupport.contextLeaves(Array(1...8)), mode: .unified, scrollPreserving: false)
    let uWidth = controller.documentView.bounds.width
    let uBands = DiffHitTest.bands(mode: .unified, width: uWidth, gutterW: controller.gutterWidth)
    let uOld = uBands.first { $0.column == .gutter(.old) }!.range
    let uNew = uBands.first { $0.column == .gutter(.new) }!.range
    let uOldHit = controller.hitTest(CGPoint(x: uOld.lowerBound + 1, y: rowYForLine4))
    let uNewHit = controller.hitTest(CGPoint(x: uNew.lowerBound + 1, y: rowYForLine4))
    #expect(uOldHit?.lineNumber == 4)  // old slot
    #expect(uNewHit?.lineNumber == 4)  // new slot
    #expect(uOldHit?.chunkID == uNewHit?.chunkID)  // one element (same row/leaf)

    // SPLIT: the same line is projected into two SEPARATE panes divided at mid — the
    // old-side gutter lives entirely in the left pane, the new-side gutter entirely
    // in the right (separate cells, one slot each side).
    controller.apply(tree: ViewportTestSupport.contextLeaves(Array(1...8)), mode: .split, scrollPreserving: false)
    let sWidth = controller.documentView.bounds.width
    let mid = (sWidth / 2).rounded()
    let sBands = DiffHitTest.bands(mode: .split, width: sWidth, gutterW: controller.gutterWidth)
    let sOld = sBands.first { $0.column == .gutter(.old) }!.range
    let sNew = sBands.first { $0.column == .gutter(.new) }!.range
    #expect(sOld.upperBound <= mid)  // old number cell entirely in the left pane
    #expect(sNew.lowerBound >= mid)  // new number cell entirely in the right pane
    #expect(controller.hitTest(CGPoint(x: sOld.lowerBound + 1, y: rowYForLine4))?.side == .old)
    #expect(controller.hitTest(CGPoint(x: sNew.lowerBound + 1, y: rowYForLine4))?.side == .new)
  }

  // MARK: - B §15/§17, A §11/§12 — the file-scoped widget renders once, above the
  //          leading separator, only in the top chunk (no dup)

  @Test func fileLevelWidgetAboveFirstHunk() {
    let hunk1 = DiffFixture.hunk(
      [DiffFixture.line(.context, old: 1, new: 1, "a"), DiffFixture.line(.addition, new: 2, "b")],
      oldStart: 1, newStart: 1)
    let hunk2 = DiffFixture.hunk(
      [DiffFixture.line(.context, old: 40, new: 41, "c"), DiffFixture.line(.addition, new: 42, "d")],
      oldStart: 40, newStart: 41)
    let chunks = ChunkTreeBuilder.classify(file: DiffFixture.file(), hunks: [hunk1, hunk2], expanded: [])

    // The file-scoped widget (file header) is the FIRST chunk, above the leading
    // separator (the first hunk-header widget).
    let fileHeaderIndex = chunks.firstIndex { $0.widget?.reuseKind == .fileHeader }
    let firstSeparator = chunks.firstIndex { $0.widget?.reuseKind == .hunkHeader }
    #expect(fileHeaderIndex == 0)
    #expect(firstSeparator != nil)
    #expect(fileHeaderIndex! < firstSeparator!)  // above the leading separator
    // Only in the top chunk — exactly one file-scoped widget across the whole file
    // (no per-hunk / per-window duplication), one separator per hunk.
    #expect(chunks.filter { $0.widget?.reuseKind == .fileHeader }.count == 1)
    #expect(chunks.filter { $0.widget?.reuseKind == .hunkHeader }.count == 2)
  }

  // MARK: - B §15, A §7 — the owner line re-indexed by an expand ⇒ the widget follows

  @Test func widgetFollowsExpandedLineReIndex() {
    let tree = ChunkTree(metrics: .production)
    var after: ChunkID?
    var ownerID: ChunkID!
    for line in 10...20 {
      let id = tree.insert(contextLeaf(line), after: after)
      if line == 15 { ownerID = id }
      after = id
    }
    // A comment widget anchored immediately below the owner line (15).
    let anchorID = UUID()
    let widget = Widget(
      key: .commentThread(anchorID: anchorID), estimatedHeight: 50, payload: .commentThread(anchorID: anchorID))
    let widgetID = tree.insert(.widget(widget), after: ownerID)

    let ownerRowBefore = tree.rowIndex(for: (chunk: ownerID, localRow: 0), mode: .unified)!
    #expect(tree.seek(index: ownerRowBefore + 1, mode: .unified)?.id == widgetID)  // widget right below owner

    // "Expand" nine hidden context lines ABOVE the owner (prepend 1…9) — the owner
    // line's rendered-row index shifts down by nine.
    for line in stride(from: 9, through: 1, by: -1) {
      _ = tree.insert(contextLeaf(line), after: nil)  // nil prepends as the new first row
    }
    let ownerRowAfter = tree.rowIndex(for: (chunk: ownerID, localRow: 0), mode: .unified)!
    #expect(ownerRowAfter == ownerRowBefore + 9)  // re-indexed by the expand
    // The widget FOLLOWS its owner by identity (in-order position), not a fixed
    // absolute row index — still the owner line's immediate successor.
    #expect(tree.seek(index: ownerRowAfter + 1, mode: .unified)?.id == widgetID)
  }

  // MARK: - A §5/§7 — an off-screen file-level annotation is not reserved until measured

  @Test func fileLevelAnnotationNotReservedUntilMeasured() {
    let controller = ViewportTestSupport.controller()
    let tree = ChunkTree(metrics: .production)
    let lineHeight = ChunkLayoutMetrics.production.lineHeight
    // A file-level annotation (comment widget) with a ZERO estimate above a large
    // source region: pierre reserves NO height until it is measured (offscreen
    // scrollbar correctness). CM6's "estimate required" is the per-widget default;
    // an unknown-height file-level annotation starts at 0 and reserves on measure.
    let anchorID = UUID()
    let widgetID = tree.insert(WidgetTreeFixture.commentWidget(id: anchorID, estimatedHeight: 0), after: nil)
    var after: ChunkID? = widgetID
    for line in 1...400 { after = tree.insert(WidgetTreeFixture.contextLeaf(line), after: after) }
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)

    // Not reserved: total height is exactly the 400 source rows and no measured
    // height is recorded yet (`getLinePosition`-undefined analog).
    #expect(tree.totalHeight(.unified) == 400 * lineHeight)
    #expect(controller.measuredHeight(forWidget: .commentThread(anchorID: anchorID)) == nil)

    // Once measured (the LayoutCoalescer write-back), it reserves its height and the
    // scrollbar (document height) grows to match.
    controller.setMeasuredHeight(
      .commentThread(anchorID: anchorID), width: controller.documentView.bounds.width, height: 120)
    controller.restoreScrollAnchor(controller.captureScrollAnchor())
    #expect(tree.totalHeight(.unified) == 400 * lineHeight + 120)
    #expect(abs(controller.documentView.frame.height - tree.totalHeight(.unified)) < 0.5)
  }

  // MARK: - F#7 — the line-number gutter adapts to the digit count

  @Test func gutterWidensForSixDigitLineNumbers() {
    let narrow = ViewportTestSupport.controller()
    narrow.apply(tree: ViewportTestSupport.contextLeaves([99]), mode: .unified, scrollPreserving: false)
    let narrowGutter = narrow.gutterWidth

    let wide = ViewportTestSupport.controller()
    wide.apply(tree: ViewportTestSupport.contextLeaves([999_999]), mode: .unified, scrollPreserving: false)
    let wideGutter = wide.gutterWidth

    // A 6-digit max line number reserves a STRICTLY wider gutter than a 2-digit one —
    // this fails if the apply path never calls `withGutter(forMaxLineNumber:)` (the
    // hardcoded ~5-digit default would size both files identically).
    #expect(wideGutter > narrowGutter)

    // And the wide gutter is wide enough that the number is not clipped: the number
    // rect (`gutterWidth - 4`, LineRowView.drawNumber) clears the "999999" glyph run
    // at the resolved monospaced char width.
    let charWidth = DiffMetrics.resolve().charWidth
    #expect(wideGutter - 4 >= charWidth * 6)
  }

  // MARK: - F#14 — the widget height coalescer is display-link-driven and applies

  @Test func widgetCoalescerIsDisplayLinkDriven() {
    let controller = ViewportTestSupport.controller()
    // The production coalescer must own a live `NSView.displayLink` — without it an
    // enqueued height never ticks and a variable-height widget (the Camp A inline
    // comment composer) never reflows. Fails if the coalescer is built with a nil
    // `displayLinkView`.
    #expect(controller.widgetCoalescerForTesting.isDisplayLinkInstalled)
  }

  @Test func widgetCoalescerAppliesEnqueuedHeight() {
    let controller = ViewportTestSupport.controller()
    let anchorID = UUID()
    let tree = ChunkTree(metrics: .production)
    _ = tree.insert(ViewportTestSupport.commentWidget(id: anchorID, height: 100), after: nil)
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
    let widgetKey = WidgetKey.commentThread(anchorID: anchorID)

    // Never measured through the host path yet (apply's own frame write-back does not
    // record a coalescer width).
    #expect(controller.measuredHeight(forWidget: widgetKey) == nil)

    // Enqueue a taller height through the SAME coalescer the widget host feeds, then
    // drive one pass (headless: no live link fires off-window, so tick directly).
    controller.widgetCoalescerForTesting.enqueueMeasuredHeight(key: widgetKey, width: 400, height: 160)
    controller.widgetCoalescerForTesting.tick()

    let measured = controller.measuredHeight(forWidget: widgetKey)
    #expect(measured?.width == 400)
    #expect(measured.map { abs($0.height - 160) < 0.5 } == true)
  }

  // MARK: - Fixtures & oracles

  private func contextLeaf(_ line: Int) -> Chunk {
    .lineSegment(
      LineSegment(
        hunkID: HunkID(fileID: "f", index: 0),
        lines: [
          DiffLine(origin: .context, oldLineNumber: line, newLineNumber: line, content: "c", noNewlineAtEof: false)
        ],
        window: 0..<1,
        classification: .context
      )
    )
  }

  // MARK: - `lineRect(rowIndex:)` — the O(log n) geometry the gutter hover uses

  /// `lineRect(rowIndex:)` (added for the gutter hover fix) is a pure O(log n)
  /// `seek(index:)`: for EVERY rendered row its rect must equal the seek geometry, and
  /// for a row carrying a git line it must equal the reverse `lineRect(line:side:)` — so
  /// the fast index path the hover uses can never disagree with the slow line path.
  @Test func lineRectByRowIndexMatchesSeekAndLinePath() {
    for mode in [DiffViewMode.unified, .split] {
      let controller = ViewportTestSupport.controller()
      let tree = changeAndContextTree()
      controller.apply(tree: tree, mode: mode, scrollPreserving: false)
      let width = controller.documentView.bounds.width

      for row in 0..<tree.rowCount(mode) {
        guard let hit = tree.seek(index: row, mode: mode) else {
          Issue.record("nil seek at row \(row) in \(mode)")
          continue
        }
        let byIndex = controller.lineRect(rowIndex: row)
        #expect(byIndex == CGRect(x: 0, y: hit.yOrigin, width: width, height: hit.rowHeight))

        // For a row that carries a git line, the reverse line→rect path must agree.
        let rendered = hit.chunk.renderedRows(mode)
        guard hit.localRow >= 0, hit.localRow < rendered.count else { continue }
        let numbers = rendered[hit.localRow]
        if let old = numbers.oldNumber {
          #expect(controller.lineRect(line: old, side: .old) == byIndex)
        }
        if let new = numbers.newNumber {
          #expect(controller.lineRect(line: new, side: .new) == byIndex)
        }
      }

      // Out-of-range indices resolve to nil, never a crash.
      #expect(controller.lineRect(rowIndex: -1) == nil)
      #expect(controller.lineRect(rowIndex: tree.rowCount(mode)) == nil)
    }
  }

  /// A multi-leaf tree whose split / unified layouts diverge (change hunk).
  private func changeAndContextTree() -> ChunkTree {
    let file = DiffFixture.file()
    let lines =
      [DiffFixture.line(.context, old: 1, new: 1, "a"), DiffFixture.line(.context, old: 2, new: 2, "b")]
      + [DiffFixture.line(.deletion, old: 3, "x"), DiffFixture.line(.deletion, old: 4, "y")]
      + [
        DiffFixture.line(.addition, new: 3, "p"), DiffFixture.line(.addition, new: 4, "q"),
        DiffFixture.line(.addition, new: 5, "r"),
      ]
      + [DiffFixture.line(.context, old: 5, new: 6, "c"), DiffFixture.line(.context, old: 6, new: 7, "d")]
    return ChunkTreeFixture.files([.init(file: file, hunks: [DiffFixture.hunk(lines)])])
  }

  /// A change leaf (5 del + 5 add → split 5 rows, unified 10 rows) then 50
  /// single-line context leaves numbered 100…149.
  private func changeThenContextTree() -> ChunkTree {
    let tree = ChunkTree(metrics: .production)
    let changeLines =
      (0..<5).map {
        DiffLine(origin: .deletion, oldLineNumber: $0 + 1, newLineNumber: nil, content: "d\($0)", noNewlineAtEof: false)
      }
      + (0..<5).map {
        DiffLine(
          origin: .addition, oldLineNumber: nil, newLineNumber: 200 + $0, content: "a\($0)", noNewlineAtEof: false)
      }
    let change = LineSegment(
      hunkID: HunkID(fileID: "f", index: 0), lines: changeLines, window: 0..<10, classification: .change)
    var after: ChunkID? = tree.insert(.lineSegment(change), after: nil)
    for line in 100..<150 { after = tree.insert(contextLeaf(line), after: after) }
    return tree
  }

  private func interleavedLinesAndWidgets() -> ChunkTree {
    let tree = ChunkTree(metrics: .production)
    var after: ChunkID?
    for index in 0..<40 {
      after = tree.insert(contextLeaf(index + 1), after: after)
      let widget = Widget(
        key: .expander(GapKey(hunkIndex: index)),
        estimatedHeight: 28,
        payload: .expander(anchor: index, range: index..<(index + 1), hidden: 1)
      )
      after = tree.insert(.widget(widget), after: after)
    }
    return tree
  }

  /// The independent leaf oracle: the leaf whose `[top, top+height)` contains `yOffset`.
  private func bruteForceLeaf(_ tree: ChunkTree, y yOffset: CGFloat, mode: DiffViewMode) -> ChunkID {
    var top: CGFloat = 0
    var last: ChunkID?
    for node in tree.inorderNodes() {
      let height = node.summary.height(mode)
      last = node.id
      if yOffset < top + height { return node.id }
      top += height
    }
    return last!  // clamp past the end
  }

  /// One rendered row's geometry — the full-render slice the windowed seek is
  /// diffed against (a named struct so the oracle avoids a 3-member tuple).
  private struct RowGeometry {
    let index: Int
    let yOrigin: CGFloat
    let height: CGFloat
  }

  private func fullRows(_ tree: ChunkTree, mode: DiffViewMode) -> [RowGeometry] {
    var out: [RowGeometry] = []
    var hit = tree.seek(index: 0, mode: mode)
    while let current = hit {
      out.append(RowGeometry(index: current.rowIndex, yOrigin: current.yOrigin, height: current.rowHeight))
      hit = tree.successor(of: current, mode: mode)
    }
    return out
  }
}
