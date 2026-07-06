import AppKit
import Testing

@testable import supacode

/// Phase 12 — the synthesized accessibility tree (`DiffAXProvider` /
/// `DiffLineAXElement` / `DiffAXRotors`). NSVIEW-HEADLESS: a real flipped
/// `documentView` + real `ChunkTree`, no window / run loop. Proves one element per
/// **materialized** row (bounded by collapse), decoupled from the recycle pool, with
/// valid **offscreen** frames, the three rotors, the huge-file loading hatch, and
/// the VO⇄keyboard focus mirror routed through the shared P10 `reveal`.
@MainActor
struct DiffAXProviderTests {
  // MARK: - Fixtures

  private func documentView(width: CGFloat = 900, height: CGFloat = 40_000) -> NSView {
    let view = DiffViewportView()
    view.frame = NSRect(x: 0, y: 0, width: width, height: height)
    return view
  }

  private func line(_ origin: DiffLineOrigin, old: Int?, new: Int?, _ content: String) -> DiffLine {
    DiffLine(origin: origin, oldLineNumber: old, newLineNumber: new, content: content, noNewlineAtEof: false)
  }

  /// fileHeader (row 0) + 3 context (rows 1–3) + a change block (5 del + 5 add).
  /// Unified: 14 rows; split: 9 rows (the change block collapses 10 → 5 pairs).
  private func changeTree() -> ChunkTree {
    let tree = ChunkTree(metrics: .production)
    var after: ChunkID? = tree.insert(
      .widget(Widget(key: .fileHeader(fileID: "f"), estimatedHeight: 44, payload: .fileHeader(fileID: "f"))),
      after: nil)
    let context = (1...3).map { line(.context, old: $0, new: $0, "c\($0)") }
    after = tree.insert(
      .lineSegment(
        LineSegment(hunkID: HunkID(fileID: "f", index: 0), lines: context, window: 0..<3, classification: .context)),
      after: after)
    let change =
      (0..<5).map { line(.deletion, old: $0 + 4, new: nil, "d") }
      + (0..<5).map { line(.addition, old: nil, new: $0 + 4, "a") }
    _ = tree.insert(
      .lineSegment(
        LineSegment(hunkID: HunkID(fileID: "f", index: 0), lines: change, window: 0..<10, classification: .change)),
      after: after)
    return tree
  }

  private func provider(
    tree: ChunkTree,
    mode: DiffViewMode = .unified,
    documentView doc: NSView,
    reveal: @escaping (Int) -> Void = { _ in },
    setKeyboardFocus: @escaping (Int) -> Void = { _ in },
    addComment: @escaping (DiffSide, Int) -> Void = { _, _ in },
    expand: @escaping (GapKey) -> Void = { _ in },
    liveWidgetView: @escaping (ChunkID) -> NSView? = { _ in nil },
    comments: @escaping (UUID) -> [ReviewComment] = { _ in [] },
    fileHeader: @escaping (FileID) -> FileHeaderWidget.Model? = { _ in nil },
    post: @escaping (Any, NSAccessibility.Notification) -> Void = {
      NSAccessibility.post(element: $0, notification: $1)
    }
  ) -> DiffAXProvider {
    DiffAXProvider(
      documentView: doc,
      snapshot: { DiffAXSnapshot(tree: tree, mode: mode, comments: comments, fileHeader: fileHeader) },
      reveal: reveal,
      setKeyboardFocus: setKeyboardFocus,
      addComment: addComment,
      expand: expand,
      liveWidgetView: liveWidgetView,
      post: post)
  }

  // MARK: - axChildCountEqualsMaterializedRows

  @Test func axChildCountEqualsMaterializedRowsInBothModes() {
    let tree = changeTree()
    let holder = ModeHolder()
    let doc = documentView()
    let sut = DiffAXProvider(
      documentView: doc,
      snapshot: { DiffAXSnapshot(tree: tree, mode: holder.mode) },
      reveal: { _ in }, setKeyboardFocus: { _ in }, addComment: { _, _ in }, expand: { _ in })

    holder.mode = .unified
    sut.reload()
    #expect(tree.rowCount(.unified) == 14)
    #expect(sut.eagerElementCount == 14)
    #expect(doc.accessibilityChildren()?.count == 14)  // materialized-row count, not visible/recycled

    holder.mode = .split
    sut.reload()
    #expect(tree.rowCount(.split) == 9)
    #expect(sut.eagerElementCount == 9)
    #expect(doc.accessibilityChildren()?.count == 9)
  }

  // MARK: - offscreenAXFrameFromTree

  @Test func offscreenAXFrameFromTree() {
    let tree = ChunkTreeFixture.uniform(rows: 6_000)
    let doc = documentView()
    let sut = provider(tree: tree, documentView: doc)
    sut.reload()

    let element = sut.element(5_000)
    #expect(element != nil)
    let frame = element!.accessibilityFrameInParentSpace
    // Finite, non-empty, and identical to the pure tree seek — independent of any
    // live view, so VoiceOver reaches a line 5000 rows offscreen.
    #expect(!frame.isEmpty)
    #expect(frame.width == 900)
    #expect(frame == tree.rowFrameInDocument(5_000, mode: .unified, width: 900))
    #expect(frame.minY > 0)
  }

  // MARK: - decoupledFromRecycleIdentity

  @Test func decoupledFromRecycleIdentity() {
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: 600)
    let tree = ViewportTestSupport.contextLeaves(Array(1...500))  // 10000pt tall
    let sut = DiffAXProvider(
      documentView: controller.documentView,
      snapshot: { DiffAXSnapshot(tree: controller.tree, mode: controller.currentMode) },
      reveal: { controller.reveal(row: $0) }, setKeyboardFocus: { _ in }, addComment: { _, _ in }, expand: { _ in })
    controller.axProvider = sut
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)  // triggers reload

    let before = sut.element(10)
    #expect(before?.rowIndex == 10)
    // Fling far past the overscan so row 10's view is recycled off — no reload fires.
    controller.scroll(toY: 9_000)
    let after = sut.element(10)
    #expect(before === after)  // AX identity keyed by rowIndex, not a LineRowView
  }

  // MARK: - lineRowViewOptsOutOfAX

  @Test func recycledRowViewsOptOutOfAX() {
    #expect(LineRowView().isAccessibilityElement() == false)  // S2 guarantee #1
    #expect(DiffWidgetPlaceholderView().isAccessibilityElement() == false)
    #expect(WidgetHostChunkView().isAccessibilityElement() == false)
    // Survives a recycle unmount.
    let view = LineRowView()
    view.prepareForReuse()
    #expect(view.isAccessibilityElement() == false)
  }

  // MARK: - rotorMembership

  @Test func rotorMembershipIsTreeDerived() {
    let tree = ChunkTree(metrics: .production)
    func fileHeader(_ id: String) -> Chunk {
      .widget(Widget(key: .fileHeader(fileID: id), estimatedHeight: 44, payload: .fileHeader(fileID: id)))
    }
    func changeSeg(_ id: String) -> Chunk {
      let lines =
        (0..<3).map { line(.deletion, old: $0 + 1, new: nil, "d") }
        + (0..<3).map { line(.addition, old: nil, new: $0 + 1, "a") }
      return .lineSegment(
        LineSegment(hunkID: HunkID(fileID: id, index: 0), lines: lines, window: 0..<6, classification: .change))
    }
    func commentW(_ id: UUID) -> Chunk {
      .widget(Widget(key: .commentThread(anchorID: id), estimatedHeight: 100, payload: .commentThread(anchorID: id)))
    }

    var after: ChunkID? = tree.insert(fileHeader("f1"), after: nil)  // row 0
    after = tree.insert(changeSeg("f1"), after: after)  // rows 1–6
    after = tree.insert(commentW(UUID()), after: after)  // row 7
    after = tree.insert(fileHeader("f2"), after: after)  // row 8
    after = tree.insert(changeSeg("f2"), after: after)  // rows 9–14
    after = tree.insert(commentW(UUID()), after: after)  // row 15
    _ = tree.insert(commentW(UUID()), after: after)  // row 16 (orphan group)

    let doc = documentView()
    let sut = provider(tree: tree, documentView: doc)
    sut.reload()

    // Changes = first row of every contiguous `.change` run, in order.
    #expect(sut.rotorRows(for: .changes) == [1, 9])
    // Files = each file-header widget.
    #expect(sut.rotorRows(for: .files).count == 2)
    // Comments = every comment thread widget, incl. the orphan.
    #expect(sut.rotorRows(for: .comments) == [7, 15, 16])

    // Membership stepping (nil current → first/last; ends return nil, no wrap).
    #expect(DiffAXRotorMembership.step([1, 9], from: nil, direction: .next) == 1)
    #expect(DiffAXRotorMembership.step([1, 9], from: 1, direction: .next) == 9)
    #expect(DiffAXRotorMembership.step([1, 9], from: 9, direction: .next) == nil)
    #expect(DiffAXRotorMembership.step([1, 9], from: nil, direction: .previous) == 9)
    #expect(DiffAXRotorMembership.step([1, 9], from: 9, direction: .previous) == 1)

    // The Changes rotor delegate resolves the first change row's element.
    let rotors = DiffAXRotors(provider: sut)
    let changesRotor = rotors.make().first { $0.label == DiffAXRotorKind.changes.rawValue }
    let params = NSAccessibilityCustomRotor.SearchParameters()
    params.searchDirection = .next
    let result = rotors.rotor(changesRotor!, resultFor: params)
    #expect((result?.targetElement as? DiffLineAXElement)?.rowIndex == 1)
  }

  // MARK: - expanderPerformPressGrowsRowCount

  @Test func expanderPerformPressGrowsRowCount() {
    let controller = ViewportTestSupport.controller()
    let tree = ViewportTestSupport.widgets(count: 1)  // one expander, GapKey(hunkIndex: 0)
    var expandedGap: GapKey?
    let sut = DiffAXProvider(
      documentView: controller.documentView,
      snapshot: { DiffAXSnapshot(tree: controller.tree, mode: controller.currentMode) },
      reveal: { controller.reveal(row: $0) },
      setKeyboardFocus: { _ in },
      addComment: { _, _ in },
      expand: { gap in
        expandedGap = gap
        let revealed = (1...14).map { self.line(.context, old: $0, new: $0, "ctx\($0)") }
        let region = ExpansionState.full.resolve(gap: gap.hunkIndex, rangeSize: 14)
        controller.applyExpansion(gap: gap, region: region, revealedLines: revealed)  // Phase-7 splice → reload()
      })
    controller.axProvider = sut
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)

    let before = controller.tree.rowCount(.unified)
    #expect(before == 1)
    let pressed = sut.element(0)?.accessibilityPerformPress() ?? false
    #expect(pressed == true)
    #expect(expandedGap == GapKey(hunkIndex: 0))
    let after = controller.tree.rowCount(.unified)
    #expect(after == 14)  // revealed lines materialized
    #expect(sut.eagerElementCount == 14)  // reload() rebuilt the element set post-grow
  }

  // MARK: - elementLoadingWindowingAboveThreshold

  @Test func elementLoadingWindowingAboveThreshold() {
    // A pathological fully-changed file: 20_001 additions ⇒ above the 20k threshold.
    let lines = (0..<20_001).map { line(.addition, old: nil, new: $0 + 1, "add \($0)") }
    let tree = ChunkTree(metrics: .production)
    let segment = LineSegment(
      hunkID: HunkID(fileID: "big", index: 0), lines: lines, window: 0..<20_001, classification: .change)
    _ = tree.insert(.lineSegment(segment), after: nil)
    #expect(tree.rowCount(.unified) > DiffAXProvider.hugeFileRowThreshold)

    let doc = documentView()
    let sut = provider(tree: tree, documentView: doc)
    sut.reload()
    // No eager element per row — the hatch is active.
    #expect(sut.eagerElementCount == 0)
    #expect((doc.accessibilityChildren()?.count ?? 0) == 0)

    // A rotor returns an `itemLoadingToken` result (no eager element to target).
    let rotors = DiffAXRotors(provider: sut)
    let changesRotor = rotors.make().first { $0.label == DiffAXRotorKind.changes.rawValue }
    let params = NSAccessibilityCustomRotor.SearchParameters()
    params.searchDirection = .next
    let result = rotors.rotor(changesRotor!, resultFor: params)
    #expect(result?.targetElement == nil)
    #expect(result?.itemLoadingToken != nil)

    // Realizing the token materializes EXACTLY one element.
    let realized = sut.accessibilityElement(withToken: result!.itemLoadingToken!)
    #expect((realized as? DiffLineAXElement)?.rowIndex == 0)
    #expect(sut.windowedRealizedCount == 1)
    // Re-realizing the same row reuses it (still one); a new row grows the window.
    _ = sut.accessibilityElement(withToken: DiffAXRowToken(rowIndex: 0))
    #expect(sut.windowedRealizedCount == 1)
    _ = sut.accessibilityElement(withToken: DiffAXRowToken(rowIndex: 100))
    #expect(sut.windowedRealizedCount == 2)
  }

  // MARK: - voToKeyboardFocusRoundTrip

  @Test func voToKeyboardFocusRoundTrip() {
    let controller = ViewportTestSupport.controller()
    let tree = ViewportTestSupport.contextLeaves(Array(1...20))
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
    let nav = DiffKeyboardNav(controller: controller, tree: tree, send: { _ in })
    let posts = PostSpy()
    var revealed: [Int] = []

    var providerBox: DiffAXProvider?
    let sut = DiffAXProvider(
      documentView: controller.documentView,
      snapshot: { DiffAXSnapshot(tree: tree, mode: .unified) },
      reveal: { revealed.append($0) },
      // The owner wiring: a keyboard-focus change notifies the provider, so the
      // suppressFocusPost guard is what breaks the loop during the VO mirror.
      setKeyboardFocus: { row in
        nav.syncFocusedRow(row)
        providerBox?.keyboardDidFocus(row)
      },
      addComment: { _, _ in }, expand: { _ in },
      post: { posts.record($0, $1) })
    providerBox = sut
    sut.reload()
    posts.reset()  // drop the reload's .layoutChanged

    // VO moved its cursor onto row 6 → keyboard cursor mirrors, reveal fires, and
    // the mirror does NOT re-post (suppressFocusPost).
    sut.element(6)?.setAccessibilityFocused(true)
    #expect(nav.focusedRowIndex == 6)
    #expect(revealed.last == 6)
    #expect(posts.focusPosts == 0)  // no feedback loop

    // A genuine keyboard-originated focus (not suppressed) posts to VO.
    revealed.removeAll()
    sut.keyboardDidFocus(6)
    #expect(revealed.last == 6)
    #expect(posts.focusPosts == 1)
  }

  // MARK: - keyboardAndVoiceOverBothRouteThroughReveal (SEAM S2, a11y↔nav)

  @Test func keyboardAndVoiceOverBothRouteThroughReveal() {
    let controller = ViewportTestSupport.controller()
    let tree = ViewportTestSupport.contextLeaves(Array(1...50))
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
    let spy = RevealSpy(base: controller)
    let posts = PostSpy()

    var providerBox: DiffAXProvider?
    let nav = DiffKeyboardNav(controller: spy, tree: tree, send: { _ in })
    let sut = DiffAXProvider(
      documentView: controller.documentView,
      snapshot: { DiffAXSnapshot(tree: tree, mode: .unified) },
      reveal: { spy.reveal(row: $0, align: .nearest) },  // VO path uses the SAME P10 reveal
      setKeyboardFocus: { row in
        nav.syncFocusedRow(row)
        providerBox?.keyboardDidFocus(row)
      },
      addComment: { _, _ in }, expand: { _ in },
      post: { posts.record($0, $1) })
    providerBox = sut
    nav.onFocusRow = { providerBox?.keyboardDidFocus($0) }  // keyboard → VO mirror
    controller.axProvider = sut
    sut.reload()

    // Keyboard `j` nav lands row 8 THROUGH the shared reveal and posts to VO.
    posts.reset()
    for _ in 0..<8 { nav.perform(.lineDown) }
    #expect(nav.focusedRowIndex == 8)
    #expect(spy.revealed.contains(8))
    #expect(posts.focusPosts >= 1)

    // VO focus lands row 20 through the SAME reveal, WITHOUT re-posting (loop guard).
    spy.reset()
    posts.reset()
    sut.element(20)?.setAccessibilityFocused(true)
    #expect(nav.focusedRowIndex == 20)
    #expect(spy.revealed.contains(20))
    #expect(posts.focusPosts == 0)
  }

  // MARK: - modeToggleTriggersReload

  @Test func modeToggleTriggersReload() {
    let controller = ViewportTestSupport.controller()
    let tree = changeTree()
    let sut = DiffAXProvider(
      documentView: controller.documentView,
      snapshot: { DiffAXSnapshot(tree: controller.tree, mode: controller.currentMode) },
      reveal: { controller.reveal(row: $0) }, setKeyboardFocus: { _ in }, addComment: { _, _ in }, expand: { _ in })
    controller.axProvider = sut
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
    #expect(sut.eagerElementCount == 14)
    #expect(controller.documentView.accessibilityChildren()?.count == 14)

    controller.toggleMode(to: .split)  // must fire reload()
    #expect(sut.eagerElementCount == 9)
    #expect(controller.documentView.accessibilityChildren()?.count == 9)
    // A split change row names BOTH sides (the toggle changed per-row labels).
    #expect(sut.label(4).contains("old,"))
    #expect(sut.label(4).contains("new,"))
  }

  // MARK: - commentWidgetA11yMerge (live hosting view onscreen / synthesized offscreen)

  @Test func commentRotorMergesLiveWidgetOrSynthesizedFallback() {
    let tree = ChunkTree(metrics: .production)
    let anchorID = UUID()
    let header = tree.insert(
      .widget(Widget(key: .fileHeader(fileID: "f"), estimatedHeight: 44, payload: .fileHeader(fileID: "f"))), after: nil
    )
    let commentChunkID = tree.insert(
      .widget(
        Widget(
          key: .commentThread(anchorID: anchorID), estimatedHeight: 100, payload: .commentThread(anchorID: anchorID))),
      after: header)

    let fakeHostingView = NSView()  // stands in for the a11y-native CommentThreadWidget host

    // Onscreen: the rotor targets the live hosting view (rich content), NOT the
    // synthesized element.
    let docA = documentView()
    let onscreen = provider(
      tree: tree, documentView: docA,
      liveWidgetView: { $0 == commentChunkID ? fakeHostingView : nil })
    onscreen.reload()
    let rotorsA = DiffAXRotors(provider: onscreen)
    let commentsRotorA = rotorsA.make().first { $0.label == DiffAXRotorKind.comments.rawValue }
    let paramsA = NSAccessibilityCustomRotor.SearchParameters()
    paramsA.searchDirection = .next
    let resultA = rotorsA.rotor(commentsRotorA!, resultFor: paramsA)
    #expect((resultA?.targetElement as? NSView) === fakeHostingView)
    #expect((resultA?.targetElement as? DiffLineAXElement) == nil)

    // Offscreen: no live host → the synthesized fallback element carries the label.
    let docB = documentView()
    let offscreen = provider(tree: tree, documentView: docB, liveWidgetView: { _ in nil })
    offscreen.reload()
    let rotorsB = DiffAXRotors(provider: offscreen)
    let commentsRotorB = rotorsB.make().first { $0.label == DiffAXRotorKind.comments.rawValue }
    let paramsB = NSAccessibilityCustomRotor.SearchParameters()
    paramsB.searchDirection = .next
    let resultB = rotorsB.rotor(commentsRotorB!, resultFor: paramsB)
    #expect((resultB?.targetElement as? DiffLineAXElement)?.rowIndex == 1)  // synthesized fallback, exactly one
  }

  // MARK: - orphaned comment label keeps the prefix and reads via the widget path

  @Test func orphanedCommentLabelKeepsPrefix() {
    let tree = ChunkTree(metrics: .production)
    let anchorID = UUID()
    _ = tree.insert(
      .widget(
        Widget(
          key: .commentThread(anchorID: anchorID), estimatedHeight: 100, payload: .commentThread(anchorID: anchorID))),
      after: nil)
    let doc = documentView()
    let orphan = ReviewComment(
      filePath: "f", side: .new, startLine: 9, endLine: 9, anchorSnippet: "", contextBefore: "", body: "gone",
      orphaned: true)
    let sut = provider(tree: tree, documentView: doc, comments: { $0 == anchorID ? [orphan] : [] })
    sut.reload()
    #expect(sut.label(0) == "Orphaned — original line no longer present. Comment on new line 9: gone")
  }
}

// MARK: - Test doubles

/// A mutable mode source so a single provider re-reads mode across a toggle.
@MainActor final class ModeHolder {
  var mode: DiffViewMode = .unified
}

/// Counts the accessibility notifications the provider posts, by kind.
@MainActor final class PostSpy {
  private(set) var focusPosts = 0
  private(set) var layoutPosts = 0

  func record(_ element: Any, _ name: NSAccessibility.Notification) {
    if name == .focusedUIElementChanged { focusPosts += 1 }
    if name == .layoutChanged { layoutPosts += 1 }
  }

  func reset() {
    focusPosts = 0
    layoutPosts = 0
  }
}

/// A `DiffRevealing` that records every revealed row AND forwards to the real
/// controller — so the seam test proves keyboard nav and VoiceOver focus funnel
/// through the SAME P10 `reveal(row:)`.
@MainActor final class RevealSpy: DiffRevealing {
  private let base: DiffViewportController
  private(set) var revealed: [Int] = []

  init(base: DiffViewportController) { self.base = base }

  var currentMode: DiffViewMode { base.currentMode }

  func reveal(row index: Int, align: RevealAlignment) {
    revealed.append(index)
    base.reveal(row: index, align: align)
  }

  func reset() { revealed.removeAll() }
}
