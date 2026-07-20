import AppKit
import ComposableArchitecture
import Testing

@testable import supacode

/// Camp A close-out (PR #3): the single-file interaction controllers are now
/// constructed + wired by `DiffViewerRepresentable.Coordinator` (production), not only
/// in tests. These drive the SAME coordinator methods `makeNSView` / `updateNSView`
/// call, so each test fails if the wiring is reverted.
///
/// - F1+F5: gutter overlay opens the INLINE composer; a new-comment draft seeds a
///   transient inline editor; the resolver injects the composer store for the matching
///   anchor only (the modal `.sheet` is gone).
/// - F2: `DiffKeyboardNav` is built over the live tree and routed into the document
///   view; `j`/`o`/… reach the controller / reducer; `revealFirstChange` on open.
/// - F7: an expansion-only change splices via `applyExpansion` / `collapseExpansion`
///   O(log n) on the SAME tree instance — never a `buildTree` rebuild.
/// - F8: `DiffAXProvider` is constructed + assigned to `controller.axProvider` and
///   `reload()`ed on apply, so `accessibilityChildren` is non-empty on a real tree.
@MainActor
struct DiffViewerRepresentableWiringTests {
  // MARK: - Fixtures

  private func sizedCoordinator(width: CGFloat = 800, clipHeight: CGFloat = 600)
    -> DiffViewerRepresentable.Coordinator
  {
    let coord = DiffViewerRepresentable.Coordinator()
    coord.controller.scrollView.scrollerStyle = .overlay
    coord.controller.scrollView.frame = NSRect(x: 0, y: 0, width: width, height: clipHeight)
    coord.controller.scrollView.tile()
    return coord
  }

  private func keyEvent(_ chars: String, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
      characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0)!
  }

  private func line(_ origin: DiffLineOrigin, old: Int?, new: Int?, _ content: String) -> DiffLine {
    DiffLine(origin: origin, oldLineNumber: old, newLineNumber: new, content: content, noNewlineAtEof: false)
  }

  /// fileHeader (row 0) + 3 context (rows 1–3) + a change block (5 del + 5 add) →
  /// 14 unified rows; the first change block starts at row 4.
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

  /// fileHeader + context + change block A + context + change block B → TWO distinct
  /// (non-coalesced) change blocks so `n`/`p` step between them. Used to prove the menu
  /// drain reaches the SAME `seekChange` the letter keys do.
  private func twoChangeBlockTree() -> ChunkTree {
    let tree = ChunkTree(metrics: .production)
    var after: ChunkID? = tree.insert(
      .widget(Widget(key: .fileHeader(fileID: "f"), estimatedHeight: 44, payload: .fileHeader(fileID: "f"))),
      after: nil)
    after = tree.insert(
      .lineSegment(
        LineSegment(
          hunkID: HunkID(fileID: "f", index: 0), lines: (1...3).map { line(.context, old: $0, new: $0, "c\($0)") },
          window: 0..<3, classification: .context)),
      after: after)
    let changeA =
      (0..<2).map { line(.deletion, old: $0 + 4, new: nil, "dA") }
      + (0..<2).map { line(.addition, old: nil, new: $0 + 4, "aA") }
    after = tree.insert(
      .lineSegment(
        LineSegment(hunkID: HunkID(fileID: "f", index: 0), lines: changeA, window: 0..<4, classification: .change)),
      after: after)
    after = tree.insert(
      .lineSegment(
        LineSegment(
          hunkID: HunkID(fileID: "f", index: 1),
          lines: (10...11).map { line(.context, old: $0, new: $0, "c\($0)") }, window: 0..<2,
          classification: .context)),
      after: after)
    let changeB =
      (0..<2).map { line(.deletion, old: $0 + 12, new: nil, "dB") }
      + (0..<2).map { line(.addition, old: nil, new: $0 + 12, "aB") }
    _ = tree.insert(
      .lineSegment(
        LineSegment(hunkID: HunkID(fileID: "f", index: 1), lines: changeB, window: 0..<4, classification: .change)),
      after: after)
    return tree
  }

  /// hunk 0 covers new lines 1…3; hunk 1 starts at new line 40 — the inter-hunk gap
  /// `GapKey(1)` is new lines 4…39 (36 lines).
  private func twoHunkFixture() -> (FileChange, [DiffHunk]) {
    let file = DiffFixture.file()
    let hunk0 = DiffHunk(
      oldStart: 1, oldCount: 3, newStart: 1, newCount: 3, header: "@@ -1,3 +1,3 @@",
      lines: [
        line(.context, old: 1, new: 1, "a"),
        line(.deletion, old: 2, new: nil, "b-old"),
        line(.addition, old: nil, new: 2, "b-new"),
        line(.context, old: 3, new: 3, "c"),
      ])
    let hunk1 = DiffHunk(
      oldStart: 40, oldCount: 1, newStart: 40, newCount: 1, header: "@@ -40 +40 @@",
      lines: [
        line(.deletion, old: 40, new: nil, "z-old"),
        line(.addition, old: nil, new: 40, "z-new"),
      ])
    return (file, [hunk0, hunk1])
  }

  private func revealedContext(_ range: Range<Int>) -> [DiffLine] {
    range.map { line(.context, old: $0, new: $0, "gap\($0)") }
  }

  private func renderedNewNumbers(_ tree: ChunkTree, mode: DiffViewMode = .unified) -> [Int] {
    var out: [Int] = []
    var hit = tree.seek(index: 0, mode: mode)
    while let current = hit {
      if let segment = current.chunk.lineSegment {
        let rows = segment.renderedRows(mode)
        if current.localRow < rows.count, let number = rows[current.localRow].newNumber { out.append(number) }
      }
      hit = tree.successor(of: current, mode: mode)
    }
    return out
  }

  private func newComment(_ id: UUID, side: DiffSide = .new, start: Int = 5, end: Int = 5) -> ReviewComment {
    ReviewComment(
      id: id, filePath: "a.swift", source: .workingTree, side: side, startLine: start, endLine: end,
      anchorSnippet: "", contextBefore: "")
  }

  // MARK: - F8 — DiffAXProvider constructed, assigned, reloaded on apply

  @Test func axProviderInstalledAndReloadsOnApply() {
    let coord = sizedCoordinator()
    coord.file = DiffFixture.file()
    coord.installInteraction()
    #expect(coord.controller.axProvider != nil)  // constructed + assigned in production wiring

    let tree = changeTree()
    coord.controller.apply(tree: tree, mode: .unified, scrollPreserving: false)  // apply → axProvider.reload()
    let children = coord.controller.documentView.accessibilityChildren()
    #expect(children?.count == tree.rowCount(.unified))  // one AX element per materialized row
    #expect((children?.count ?? 0) > 0)  // non-empty on a real documentView

    // A re-diff (fewer rows) re-reads the live tree on the next apply.
    coord.controller.apply(
      tree: ViewportTestSupport.contextLeaves(Array(1...4)), mode: .unified, scrollPreserving: false)
    #expect(coord.controller.documentView.accessibilityChildren()?.count == 4)
  }

  // MARK: - F2 — DiffKeyboardNav built over the tree, routed, reaches controller + reducer

  @Test func keyboardNavWiredToDocumentViewAndReducer() {
    let coord = sizedCoordinator()
    var sent: [DiffReviewFeature.Action] = []
    coord.send = { sent.append($0) }
    coord.installInteraction()
    coord.controller.apply(tree: changeTree(), mode: .unified, scrollPreserving: false)
    coord.rebuildKeyboardNav()

    #expect(coord.keyboardNav != nil)
    #expect(coord.controller.documentView.keyboardNav === coord.keyboardNav)

    // revealFirstChange lands the first change block (row 4).
    coord.keyboardNav?.revealFirstChange()
    #expect(coord.keyboardNav?.focusedRowIndex == 4)

    // `j` (line down) is consumed + advances the cursor through the routed handle().
    #expect(coord.controller.documentView.keyboardNav?.handle(keyEvent("j")) == true)
    #expect(coord.keyboardNav?.focusedRowIndex == 5)

    // `o` (expand whole file) reaches the reducer for the focused row's file.
    coord.keyboardNav?.perform(.expandFile)
    #expect(sent.contains(.diffExpandWholeFile(fileID: "f")))
  }

  // MARK: - F10 — a menu-driven nav intent drains into the SAME DiffKeyboardNav

  /// The "Diff" `CommandMenu` items route through `pendingNavCommand` →
  /// `Coordinator.performMenuNav`, which forwards to the live `DiffKeyboardNav` — the
  /// identical nav the single-letter keys drive. Fails if the drain is unwired.
  @Test func menuNavDrainsIntoKeyboardNav() {
    let coord = sizedCoordinator()
    coord.installInteraction()
    coord.controller.apply(tree: twoChangeBlockTree(), mode: .unified, scrollPreserving: false)
    coord.rebuildKeyboardNav()
    coord.keyboardNav?.revealFirstChange()  // lands the first change block's first row
    let firstBlock = coord.keyboardNav?.focusedRowIndex ?? -1
    #expect(firstBlock >= 0)

    // A menu "Next Change" pick, drained via performMenuNav, steps to the SECOND change
    // block exactly as pressing `n` would (the drain forwards to the live nav).
    coord.performMenuNav(.nextChange)
    let secondBlock = coord.keyboardNav?.focusedRowIndex ?? -1
    #expect(secondBlock > firstBlock)

    // "Previous Change" walks back to the first change block.
    coord.performMenuNav(.prevChange)
    #expect(coord.keyboardNav?.focusedRowIndex == firstBlock)
  }

  // MARK: - F5 — gutter overlay mounted; a commit opens the INLINE composer

  @Test func gutterMountedAndOpensComposerOnCommit() {
    let coord = sizedCoordinator()
    var sent: [DiffReviewFeature.Action] = []
    coord.send = { sent.append($0) }
    coord.filePath = "a.swift"
    coord.source = .workingTree
    coord.installInteraction()
    coord.controller.apply(
      tree: ViewportTestSupport.contextLeaves(Array(1...20)), mode: .unified, scrollPreserving: false)

    guard let gutter = coord.gutter else {
      Issue.record("gutter overlay was not constructed")
      return
    }
    #expect(gutter.superview != nil)  // floating overlay mounted into the scroll view
    #expect(gutter.controller === coord.controller)

    // Down on the old-side number column of line 3 (leaf i → line i+1 at y = i·20), commit.
    let oldNumX = DiffHitTest.changeBarWidth + coord.controller.gutterWidth / 2
    #expect(gutter.beginSelection(atDocument: CGPoint(x: oldNumX, y: 2 * 20 + 10)))
    _ = gutter.commitSelection()

    guard case .openCommentComposer(let path, let src, let side, let start, let end, _, _)? = sent.first else {
      Issue.record("gutter commit did not send .openCommentComposer")
      return
    }
    #expect(path == "a.swift")
    #expect(src == .workingTree)
    #expect(side == .old)
    #expect(start == 3)
    #expect(end == 3)
  }

  // MARK: - F8 (a11y comment) — the installed provider exposes the "Add comment" action

  @Test func accessibilityProviderExposesAddCommentAction() {
    let coord = sizedCoordinator()
    coord.filePath = "a.swift"
    coord.source = .workingTree
    coord.installInteraction()
    coord.controller.apply(
      tree: ViewportTestSupport.contextLeaves(Array(1...10)), mode: .unified, scrollPreserving: false)

    // Row 4 → new line 5: the synthesized element carries the "Add comment on line 5"
    // rotor action (which the installed provider routes to `.openCommentComposer` — the
    // same reducer path the gutter commit proves). No provider ⇒ no element ⇒ no action.
    let action = coord.controller.axProvider?.element(4)?.accessibilityCustomActions()?.first
    #expect(action?.name == "Add comment on line 5")
  }

  // MARK: - F7 — an expansion-only change splices O(log n), NOT a buildTree rebuild

  @Test func expansionSplicesInPlaceThenCollapseRestores() {
    let coord = sizedCoordinator()
    let (file, hunks) = twoHunkFixture()
    coord.controller.apply(
      tree: ChunkTreeBuilder.build(file: file, hunks: hunks, mode: .unified), mode: .unified, scrollPreserving: false)
    let treeInstance = coord.controller.tree
    #expect(!renderedNewNumbers(coord.controller.tree).contains(20))  // gap interior collapsed

    // Fully reveal gap 1 with the reducer-shaped inputs.
    coord.syncExpansion(
      expansion: .full, revealed: [1: revealedContext(4..<40)], hunks: hunks, file: file, rebuilt: false)
    #expect(renderedNewNumbers(coord.controller.tree).contains(20))  // context is on screen
    #expect(coord.controller.tree === treeInstance)  // SAME instance — an O(log n) splice, not a rebuild
    #expect(coord.controller.tree.widgetNode(for: .expander(GapKey(hunkIndex: 1))) == nil)  // expander removed

    // Collapse restores the expander and re-hides the gap.
    coord.lastExpansion = .full
    coord.lastRevealedCounts = [1: 36]
    coord.syncExpansion(expansion: .collapsed, revealed: [:], hunks: hunks, file: file, rebuilt: false)
    #expect(!renderedNewNumbers(coord.controller.tree).contains(20))
    #expect(coord.controller.tree.widgetNode(for: .expander(GapKey(hunkIndex: 1))) != nil)
    #expect(coord.controller.tree === treeInstance)  // still the same instance
  }

  // MARK: - F1 — a NEW-comment draft seeds a transient INLINE editor; cancel removes it

  @Test func newCommentSeedsTransientInlineEditorAndCancelRemovesIt() {
    let coord = sizedCoordinator()
    coord.filePath = "a.swift"
    coord.source = .workingTree
    coord.controller.apply(
      tree: ViewportTestSupport.contextLeaves(Array(1...10)), mode: .unified, scrollPreserving: false)

    let anchor = UUID()
    // Open the composer for a brand-new comment (absent from `comments`) → transient
    // editing widget inserted at line 5.
    coord.reconcileTransientComposer(draft: newComment(anchor), comments: [])
    #expect(coord.controller.tree.widgetNode(for: .commentThread(anchorID: anchor)) != nil)

    // Cancel (composer closes, still uncommitted) → the editor is removed.
    coord.reconcileTransientComposer(draft: nil, comments: [])
    #expect(coord.controller.tree.widgetNode(for: .commentThread(anchorID: anchor)) == nil)
  }

  // MARK: - F1 — a committed anchor is NOT torn down by the transient reconcile

  @Test func committedAnchorSurvivesTransientReconcile() {
    let coord = sizedCoordinator()
    coord.controller.apply(
      tree: ViewportTestSupport.contextLeaves(Array(1...10)), mode: .unified, scrollPreserving: false)
    let anchor = UUID()
    let comment = newComment(anchor)
    coord.reconcileTransientComposer(draft: comment, comments: [])  // transient inserted
    #expect(coord.controller.tree.widgetNode(for: .commentThread(anchorID: anchor)) != nil)

    // Commit path: the anchor now lives in `comments`; a full re-project (not modelled
    // here) renders the display thread, so the reconcile must NOT remove the widget.
    let widget = coord.controller.tree.widgetNode(for: .commentThread(anchorID: anchor))?.id
    coord.reconcileTransientComposer(draft: nil, comments: [comment])
    #expect(coord.controller.tree.widgetNode(for: .commentThread(anchorID: anchor))?.id == widget)  // untouched
  }

  // MARK: - F1+F5 — the resolver injects the composer store for the matching anchor ONLY

  @Test func resolverInjectsComposerStoreForMatchingAnchorOnly() {
    let anchor = UUID()
    let other = UUID()
    let comment = ReviewComment(
      id: anchor, filePath: "a.swift", source: .workingTree, side: .new, startLine: 5, endLine: 5,
      anchorSnippet: "", contextBefore: "", body: "x")
    let store = Store(initialState: CommentComposer.State(draft: comment, isEditing: true)) { CommentComposer() }
    let coalescer = LayoutCoalescer(host: sizedCoordinator().controller)
    let widget = Widget(
      key: .commentThread(anchorID: anchor), estimatedHeight: 100, payload: .commentThread(anchorID: anchor))

    // Matching anchor → `.editing` (inline composer embedded), NOT display.
    var editing = DiffWidgetResolver(comments: [comment])
    editing.composerStore = { $0 == anchor ? store : nil }
    #expect((editing.resolve(widget, coalescer: coalescer) as? CommentThreadWidget)?.isEditing == true)

    // A non-matching / closed composer → display mode (no store injected).
    var display = DiffWidgetResolver(comments: [comment])
    display.composerStore = { $0 == other ? store : nil }
    #expect((display.resolve(widget, coalescer: coalescer) as? CommentThreadWidget)?.isEditing == false)
  }

  // MARK: - F23 — the resolver threads collapse state + a live toggle into the thread widget

  /// The chevron was a dead button: the resolver built the thread widget without
  /// `isCollapsed` (hardcoded false) or `onToggleCollapse` (defaulted `{}`). This proves
  /// both are now wired — the model reflects `collapsedThreads`, and the chevron sink
  /// forwards the anchor to `onToggleCommentThreadCollapsed`. Fails if the wiring reverts.
  @Test func resolverThreadsCollapseStateAndToggle() {
    let anchor = UUID()
    let comment = ReviewComment(
      id: anchor, filePath: "a.swift", source: .workingTree, side: .new, startLine: 5, endLine: 5,
      anchorSnippet: "", contextBefore: "", body: "x")
    let coalescer = LayoutCoalescer(host: sizedCoordinator().controller)
    let widget = Widget(
      key: .commentThread(anchorID: anchor), estimatedHeight: 100, payload: .commentThread(anchorID: anchor))

    // Anchor in the collapsed set → the widget renders collapsed; the chevron forwards it.
    var toggled: [UUID] = []
    var collapsedResolver = DiffWidgetResolver(comments: [comment])
    collapsedResolver.collapsedThreads = [anchor]
    collapsedResolver.onToggleCommentThreadCollapsed = { toggled.append($0) }
    let collapsed = collapsedResolver.resolve(widget, coalescer: coalescer) as? CommentThreadWidget
    #expect(collapsed?.model.isCollapsed == true)
    collapsed?.onToggleCollapse()  // the chevron action
    #expect(toggled == [anchor])

    // Anchor absent from the set → expanded (the default).
    let expandedResolver = DiffWidgetResolver(comments: [comment])
    let expanded = expandedResolver.resolve(widget, coalescer: coalescer) as? CommentThreadWidget
    #expect(expanded?.model.isCollapsed == false)
  }
}
