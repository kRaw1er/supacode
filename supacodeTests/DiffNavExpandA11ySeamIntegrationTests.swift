import AppKit
import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

/// Camp A F2 + F7 + F8 — the NAV / EXPAND / A11Y seams driven END TO END
/// (callback → action → reducer state → coordinator → viewport/tree), not as
/// isolated Coordinator units (`DiffViewerRepresentableWiringTests` already covers
/// those in isolation). Each test drives an ACTUAL wired interaction surface — the
/// keyboard nav routed into the document view, the accessibility provider's
/// synthesized rotor action, or the expander press the provider is wired to send —
/// feeds the resulting action into a REAL `StoreOf<DiffReviewFeature>`, lets the
/// reducer mutate state, then threads that state back through the coordinator exactly
/// as `DiffViewerRepresentable.updateNSView` does (`syncExpansion` /
/// `reconcileTransientComposer` / the reload-on-`apply`), and asserts the live
/// `ChunkTree` / viewport / element set reflects the whole round trip.
///
/// - F2 KEYBOARD: `o` / `e` route to `.diffExpandWholeFile` / `.diffExpandContext`
///   into the real reducer; `revealFirstChange` lands the first change row AND scrolls
///   the viewport (the reveal→viewport leg).
/// - F7 EXPAND: the a11y expander press → `.expandGap` → the reducer's blob-slice
///   effect → `.gapSliceLoaded` populates `state.revealed` → `syncExpansion` splices
///   the gap interior onto the SAME tree instance; a keyboard `E` collapse round-trips.
/// - F8 A11Y: `apply` reloads `documentView.accessibilityChildren` (one per row); the
///   "Add comment on line N" rotor action → the wired `addComment` → `.openCommentComposer`
///   into the real reducer (the same path the gutter uses); VoiceOver focus mirrors into
///   the keyboard cursor and back through the wired `setKeyboardFocus` / `onFocusRow`.
///
/// F69 (FIXED): the KEYBOARD whole-file / context expands (`.diffExpandWholeFile` /
/// `.diffExpandContext`) now fire the eager blob slice — like the per-gap `.expandGap`
/// path — so `state.revealed` populates and the viewport reveals the context. This
/// suite drives that fix end to end (`keyboardExpandFileRevealsGapInteriorRoundTrip`).
@MainActor
struct DiffNavExpandA11ySeamIntegrationTests {
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

  private func gitWorktree() -> Worktree {
    Worktree(
      id: WorktreeID("/tmp/repo/wt"), name: "wt", detail: "",
      workingDirectory: URL(filePath: "/tmp/repo/wt"), repositoryRootURL: URL(filePath: "/tmp/repo"))
  }

  /// hunk 0 covers new lines 1…3; hunk 1 starts at new line 40 — the inter-hunk gap
  /// `GapKey(1)` is new lines 4…39 (36 lines), rendered as a single collapsed expander.
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

  /// A tall single-file tree whose first change block sits well below the fold:
  /// fileHeader (row 0) + `contextCount` context rows (1…contextCount) + a 5-del/5-add
  /// change block starting at row `contextCount + 1`.
  private func deepChangeTree(contextCount: Int) -> ChunkTree {
    let tree = ChunkTree(metrics: .production)
    var after: ChunkID? = tree.insert(
      .widget(
        Widget(key: .fileHeader(fileID: "a.swift"), estimatedHeight: 44, payload: .fileHeader(fileID: "a.swift"))),
      after: nil)
    let context = (1...contextCount).map { line(.context, old: $0, new: $0, "c\($0)") }
    after = tree.insert(
      .lineSegment(
        LineSegment(
          hunkID: HunkID(fileID: "a.swift", index: 0), lines: context, window: 0..<contextCount,
          classification: .context)),
      after: after)
    let change =
      (0..<5).map { line(.deletion, old: contextCount + 1 + $0, new: nil, "d") }
      + (0..<5).map { line(.addition, old: nil, new: contextCount + 1 + $0, "a") }
    _ = tree.insert(
      .lineSegment(
        LineSegment(
          hunkID: HunkID(fileID: "a.swift", index: 0), lines: change, window: 0..<10, classification: .change)),
      after: after)
    return tree
  }

  /// The rendered NEW-side line numbers currently materialized in `tree` (walks the
  /// whole tree; the gap-interior probe for a splice).
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

  /// The materialized row index of the expander widget for `gap`, or `nil`.
  private func expanderRow(_ coord: DiffViewerRepresentable.Coordinator, gap: Int) -> Int? {
    guard let node = coord.controller.tree.widgetNode(for: .expander(GapKey(hunkIndex: gap))) else { return nil }
    return coord.controller.tree.rowIndex(for: (chunk: node.id, localRow: 0), mode: coord.controller.currentMode)
  }

  /// A real `StoreOf<DiffReviewFeature>` with only the invoked dependencies stubbed.
  /// Non-exhaustive because the round trips read `store.state` back after driving the
  /// wired seam rather than mirroring every intermediate mutation.
  private func makeStore(
    _ state: DiffReviewFeature.State = DiffReviewFeature.State(),
    slice: @escaping @Sendable (Range<Int>) -> [DiffLine] = { _ in [] }
  ) -> TestStore<DiffReviewFeature.State, DiffReviewFeature.Action> {
    let store = TestStore(initialState: state) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 1000))
      $0[CommentPersistenceStoreClient.self] = CommentPersistenceStoreClient(
        load: { _ in [] }, save: { _, _ in })
      $0.blobSliceClient.slice = { _, _, _, range, _ in slice(range) }
    }
    store.exhaustivity = .off
    return store
  }

  /// Initial reducer state with one open, loaded diff document for `file`/`hunks`.
  private func loadedState(file: FileChange, hunks: [DiffHunk], worktree: Worktree) -> DiffReviewFeature.State {
    var document = DiffDocument(file: file, source: .workingTree, loadState: .loaded, generation: 0)
    document.hunks = hunks
    var state = DiffReviewFeature.State()
    state.selectedWorktree = worktree
    state.files = [file]
    state.openDiffs = [DiffDocumentKey(path: file.id, source: .workingTree): document]
    state.diffLoadToken = 0
    return state
  }

  // MARK: - F7 — a11y expander press → .expandGap → slice → revealed → splice, then keyboard collapse

  /// The GOOD incremental path, driven END TO END: the accessibility provider's
  /// expander-press action (the coordinator wires `expand:` → `self.send(.expandGap)`)
  /// reaches the real reducer, which fires the blob-slice effect; `.gapSliceLoaded`
  /// populates `state.revealed`; feeding that back through `syncExpansion` splices the
  /// gap interior onto the SAME `ChunkTree` instance (an O(log n) splice, NOT a
  /// rebuild). A keyboard `E` (lessContext) then collapses it back through the reducer.
  @Test func axExpanderPressExpandsGapThenKeyboardCollapseRoundTrip() async throws {
    let coord = sizedCoordinator()
    let (file, hunks) = twoHunkFixture()
    var captured: [DiffReviewFeature.Action] = []
    coord.filePath = file.id
    coord.source = .workingTree
    coord.send = { captured.append($0) }
    coord.installInteraction()
    coord.controller.apply(
      tree: ChunkTreeBuilder.build(file: file, hunks: hunks, mode: .unified), mode: .unified, scrollPreserving: false)
    coord.rebuildKeyboardNav()
    let treeInstance = coord.controller.tree
    #expect(!renderedNewNumbers(coord.controller.tree).contains(20))  // gap interior collapsed at rest

    // Drive the WIRED accessibility expander-press on gap 1's collapsed expander row.
    let row = try #require(expanderRow(coord, gap: 1))
    #expect(coord.controller.axProvider?.performPress(row) == true)
    // The provider routed the press to the coordinator's `.expandGap` (scoped to this tab).
    guard case .expandGap(let key, let gap, let step, let direction)? = captured.first else {
      Issue.record("a11y expander press did not send .expandGap")
      return
    }
    #expect(key == DiffDocumentKey(path: file.id, source: .workingTree))
    #expect(gap == 1)
    #expect(step == .fine)
    #expect(direction == .both)

    // Feed it into the REAL reducer, which fires the incremental blob slice (36 ctx lines).
    let store = makeStore(loadedState(file: file, hunks: hunks, worktree: gitWorktree())) { range in
      range.map {
        DiffLine(origin: .context, oldLineNumber: $0, newLineNumber: $0, content: "gap\($0)", noNewlineAtEof: false)
      }
    }
    await store.send(captured[0])
    await store.receive(\.gapSliceLoaded)
    await store.finish()

    let expandedExpansion = try #require(store.state.openDiffs[key]?.expansion)
    let revealed = store.state.openDiffs[key]?.revealed ?? [:]
    #expect(revealed[1]?.isEmpty == false)  // the slice landed in the reducer's handoff cache

    // Round-trip the reducer's expansion + revealed back through the coordinator.
    coord.syncExpansion(
      expansion: expandedExpansion, revealed: revealed, hunks: hunks, file: file, rebuilt: false)
    #expect(renderedNewNumbers(coord.controller.tree).contains(20))  // gap interior spliced in
    #expect(coord.controller.tree === treeInstance)  // SAME instance — an O(log n) splice, not a rebuild
    #expect(coord.controller.tree.widgetNode(for: .expander(GapKey(hunkIndex: 1))) == nil)  // expander consumed
    // Mirror `updateNSView`'s change-detection baselines for the next incremental pass.
    coord.lastExpansion = expandedExpansion
    coord.lastRevealedCounts = revealed.mapValues(\.count)

    // Collapse via the WIRED keyboard `E` (lessContext) → the reducer resets expansion.
    captured.removeAll()
    coord.keyboardNav?.perform(.lessContext)
    #expect(captured == [.diffExpandContext(fileID: file.id, delta: -1)])
    await store.send(captured[0])
    await store.finish()
    #expect(store.state.openDiffs[key]?.expansion == .collapsed)
    #expect(store.state.openDiffs[key]?.revealed.isEmpty == true)

    // Round-trip the collapse → the expander is restored and the gap re-hidden, same instance.
    coord.syncExpansion(
      expansion: .collapsed, revealed: [:], hunks: hunks, file: file, rebuilt: false)
    #expect(!renderedNewNumbers(coord.controller.tree).contains(20))
    #expect(coord.controller.tree.widgetNode(for: .expander(GapKey(hunkIndex: 1))) != nil)
    #expect(coord.controller.tree === treeInstance)
  }

  // MARK: - F2 / F7 / F69(fixed) — keyboard `o` (whole-file) expands AND reveals the gap

  /// Keyboard `o` (expandFile) routes through the WIRED nav to the real reducer, which
  /// flips the document to `.full` AND fires the eager blob slice (the F69 fix — this
  /// path used to skip the slice, so `o` revealed nothing). `.gapSliceLoaded` populates
  /// `state.revealed`; feeding that back through `syncExpansion` splices the gap interior
  /// (new line 20) onto the tree — proven end to end, no `withKnownIssue`.
  @Test func keyboardExpandFileRevealsGapInteriorRoundTrip() async throws {
    let coord = sizedCoordinator()
    let (file, hunks) = twoHunkFixture()
    var captured: [DiffReviewFeature.Action] = []
    coord.filePath = file.id
    coord.source = .workingTree
    coord.send = { captured.append($0) }
    coord.installInteraction()
    coord.controller.apply(
      tree: ChunkTreeBuilder.build(file: file, hunks: hunks, mode: .unified), mode: .unified, scrollPreserving: false)
    coord.rebuildKeyboardNav()

    // Drive the WIRED keyboard `o` (expandFile) — the focused row's file is this file.
    coord.keyboardNav?.perform(.expandFile)
    #expect(captured == [.diffExpandWholeFile(fileID: file.id)])

    // Feed it into the REAL reducer: it flips to `.full` AND slices the newly-revealed
    // gaps (F69 fix). twoHunkFixture reveals the inter-hunk gap (1) and the trailing gap.
    let key = DiffDocumentKey(path: file.id, source: .workingTree)
    let store = makeStore(loadedState(file: file, hunks: hunks, worktree: gitWorktree())) { range in
      range.map {
        DiffLine(origin: .context, oldLineNumber: $0, newLineNumber: $0, content: "gap\($0)", noNewlineAtEof: false)
      }
    }
    await store.send(captured[0])
    await store.receive(\.gapSliceLoaded)
    await store.receive(\.gapSliceLoaded)
    await store.finish()
    #expect(store.state.openDiffs[key]?.expansion == .full)
    // F69 fixed: the slice ran, so the reducer's handoff cache is populated.
    let revealed = store.state.openDiffs[key]?.revealed ?? [:]
    #expect(revealed[1]?.isEmpty == false)

    // Round-trip the reducer's expansion + revealed back through the coordinator: the
    // gap interior (new line 20) now materializes in the viewport.
    coord.syncExpansion(expansion: .full, revealed: revealed, hunks: hunks, file: file, rebuilt: false)
    #expect(renderedNewNumbers(coord.controller.tree).contains(20))
  }

  // MARK: - F2 — revealFirstChange lands the first change row AND scrolls the viewport

  /// The reveal→viewport leg: on a tall single-file tree whose first change block is
  /// below the fold, `revealFirstChange` lands `focusedRowIndex` on the first change
  /// row AND the controller's `reveal` actually scrolls the clip view to bring it on
  /// screen. A routed keyboard `j` then steps the cursor one row down.
  @Test func revealFirstChangeLandsChangeRowAndScrollsViewport() throws {
    let coord = sizedCoordinator(clipHeight: 400)
    let contextCount = 80
    coord.installInteraction()
    coord.controller.apply(tree: deepChangeTree(contextCount: contextCount), mode: .unified, scrollPreserving: false)
    coord.rebuildKeyboardNav()

    #expect(coord.controller.visibleRect.minY == 0)  // starts at the top
    let firstChangeRow = contextCount + 1  // fileHeader(0) + context(1…contextCount) + change starts here

    // Land the first change (centered) — the reveal must scroll the clip down to it.
    coord.keyboardNav?.revealFirstChange()
    #expect(coord.keyboardNav?.focusedRowIndex == firstChangeRow)
    #expect(coord.controller.visibleRect.minY > 0)  // viewport scrolled to bring the change into view

    // A routed `j` (line down) advances the cursor through the wired document view.
    #expect(coord.controller.documentView.keyboardNav?.handle(keyEvent("j")) == true)
    #expect(coord.keyboardNav?.focusedRowIndex == firstChangeRow + 1)
  }

  // MARK: - F8 — apply reloads accessibilityChildren; the "Add comment" action reaches the reducer

  /// `apply` reloads the provider so `documentView.accessibilityChildren` holds one
  /// element per materialized row. The synthesized "Add comment on line N" rotor action
  /// invokes the WIRED `addComment` closure → `.openCommentComposer` into the real
  /// reducer (the SAME path the gutter uses), opening the composer for that anchor.
  @Test func accessibilityAddCommentActionOpensComposerRoundTrip() async throws {
    let coord = sizedCoordinator()
    var captured: [DiffReviewFeature.Action] = []
    coord.filePath = "a.swift"
    coord.source = .workingTree
    coord.send = { captured.append($0) }
    coord.installInteraction()
    let tree = ViewportTestSupport.contextLeaves(Array(1...10))
    coord.controller.apply(tree: tree, mode: .unified, scrollPreserving: false)

    // The reload on `apply` installed one AX element per materialized row.
    #expect(coord.controller.documentView.accessibilityChildren()?.count == tree.rowCount(.unified))

    // Row 4 → new line 5: fire the synthesized "Add comment" action's handler.
    let action = try #require(coord.controller.axProvider?.element(4)?.accessibilityCustomActions()?.first)
    #expect(action.name == "Add comment on line 5")
    #expect(action.handler?() == true)

    // The wired closure sent the SAME inline-composer action the gutter sends.
    guard case .openCommentComposer(let path, let src, let side, let start, let end, _, _)? = captured.first else {
      Issue.record("a11y add-comment action did not send .openCommentComposer")
      return
    }
    #expect(path == "a.swift")
    #expect(src == .workingTree)
    #expect(side == .new)
    #expect(start == 5)
    #expect(end == 5)

    // Feed it into the REAL reducer → the composer opens on that anchor (new comment).
    let store = makeStore()
    await store.send(captured[0])
    let composer = try #require(store.state.composer)
    #expect(composer.isEditing == false)
    #expect(composer.draft.side == .new)
    #expect(composer.draft.startLine == 5)
    #expect(composer.draft.endLine == 5)
  }

  // MARK: - F8 — VoiceOver focus mirrors into the keyboard cursor and back (single SoT, no loop)

  /// The keyboard⇄VoiceOver focus mirror, driven through the WIRED closures the
  /// coordinator installs (`rebuildKeyboardNav` sets `onFocusRow`; `installInteraction`
  /// wires `setKeyboardFocus` → `syncFocusedRow`). A VoiceOver focus change mirrors into
  /// the keyboard cursor WITHOUT re-driving it (the `suppressFocusPost` guard breaks the
  /// loop), and keyboard nav then continues from the VO-set row — proving one shared
  /// source of truth.
  @Test func voiceOverFocusMirrorsKeyboardCursorRoundTrip() throws {
    let coord = sizedCoordinator()
    coord.installInteraction()
    coord.controller.apply(
      tree: ViewportTestSupport.contextLeaves(Array(1...20)), mode: .unified, scrollPreserving: false)
    coord.rebuildKeyboardNav()

    // Keyboard→VoiceOver mirror is wired (nav pushes focus into the AX provider).
    #expect(coord.keyboardNav?.onFocusRow != nil)

    // Move the keyboard cursor first, then have VoiceOver jump elsewhere.
    coord.keyboardNav?.perform(.lineDown)
    #expect(coord.keyboardNav?.focusedRowIndex == 1)

    // VoiceOver focuses row 7 → the wired `setKeyboardFocus` mirrors it into the
    // keyboard cursor under the loop guard (no re-post back into VoiceOver).
    coord.controller.axProvider?.voiceOverDidFocus(7)
    #expect(coord.keyboardNav?.focusedRowIndex == 7)

    // Keyboard nav continues from the VO-set row — the guard did not leak; single SoT.
    #expect(coord.controller.documentView.keyboardNav?.handle(keyEvent("j")) == true)
    #expect(coord.keyboardNav?.focusedRowIndex == 8)
  }
}
