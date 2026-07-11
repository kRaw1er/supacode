import AppKit
import ComposableArchitecture
import SwiftUI

/// SwiftUI bridge to the AppKit `DiffViewportController` — the Phase-13 seam swap
/// that retires the flat `DiffTableController` / `[DiffRow]` viewer. The coordinator
/// owns the controller AND the single-file interaction controllers (`DiffKeyboardNav`,
/// `GutterRibbonController`, `DiffAXProvider`); the representable re-enters through
/// `updateNSView`, rebuilds the dual-mode `ChunkTree` from the document's `hunks` +
/// `comments` (via `ChunkTreeBuilder`) whenever its content signature changes, and
/// drives the controller — `apply(tree:)` on a content change, `toggleMode` on a
/// unified↔split flip (O(log #hunks), no reproject).
///
/// Interaction is wired through the coordinator: the gutter overlay opens the INLINE
/// comment composer (pierre/GitHub-style — the modal `.sheet` is gone), keyboard nav
/// (`j`/`k`/`n`/`p`/`o`/`e`/`E`/`?`) routes single-letter keys to the reducer, VoiceOver
/// reaches the synthesized `DiffAXProvider` element set, and an expander reveal splices
/// the reducer's blob slice into the live tree O(log n) (`applyExpansion`) instead of a
/// full `buildTree` rebuild.
struct DiffViewerRepresentable: NSViewRepresentable {
  let file: FileChange
  let hunks: [DiffHunk]
  let comments: [ReviewComment]
  let mode: DiffViewMode
  /// Monotonic load/expand token — a change re-projects the tree scroll-preserving.
  let generation: Int
  /// The tab identity (path + source) — the scope for `openCommentComposer` /
  /// `expandGap` actions the interaction controllers send back to the reducer.
  var filePath: String
  var source: DiffSource
  /// Declarative, document-level collapse/expand (Phase 7 source of truth). Threaded
  /// so an expander reveal splices incrementally instead of rebuilding.
  var expansion: ExpansionState = .collapsed
  /// Per-gap blob-sliced context lines the reducer read for the current `expansion`.
  var revealed: [Int: [DiffLine]] = [:]
  /// The presented inline-composer store, scoped to THIS tab (`nil` when no composer
  /// belongs here). Injected into the comment-thread widget so it renders `.editing`.
  var composerStore: StoreOf<CommentComposer>?
  /// The open composer's draft (this tab only) — carries the anchor's `(side, range)`
  /// so a NEW comment seeds a transient inline editor at that line.
  var composerDraft: ReviewComment?
  /// `WordDiffPolicy` gate (`DiffDocument.wordDiffDisabled`): off ⇒ `WordDiff` is
  /// never invoked on the render path (only the row-level `+`/`-` tint).
  var wordDiffEnabled: Bool = true

  /// Resolved syntax runs from the reducer (`DiffDocument.old/newStyleRuns`), keyed
  /// by 1-based line number per blob side. `syntaxVersion` (== the document's
  /// `highlightGeneration`) bumps on each windowed highlight arrival so `updateNSView`
  /// repaints the visible rows without a tree rebuild.
  var oldStyleRuns: [Int: [StyleRun]] = [:]
  var newStyleRuns: [Int: [StyleRun]] = [:]
  var syntaxVersion: Int = 0

  /// The per-side blobs + size gate the controller warms the span cache from (Phase B
  /// pull model, `DiffDocument.old/newBlob` + `highlightingDisabled`). Additive to the
  /// reducer push above: the view still reads `old/newStyleRuns` for now, so threading
  /// these only fills the cache off-main for the render window (visible + overscan).
  var oldBlob: HighlightBlobInput?
  var newBlob: HighlightBlobInput?
  var highlightingDisabled: Bool = false

  /// A one-shot menu-driven nav intent (the "Diff" `CommandMenu` → viewport). Drained
  /// here into `DiffKeyboardNav.perform` and cleared via `onNavCommandConsumed`, so a
  /// menu pick reaches the SAME nav the single-letter keys drive even when the viewport
  /// doesn't hold first responder. `nil` when nothing is pending.
  var pendingNavCommand: DiffReviewFeature.MenuNavCommand?

  /// The reducer action sink for the interaction controllers (gutter comment,
  /// keyboard nav, a11y add-comment / expand).
  var send: (DiffReviewFeature.Action) -> Void = { _ in }
  /// Fired once the pending menu nav intent has been forwarded to `DiffKeyboardNav`,
  /// so the reducer clears `pendingNavCommand` (consume-once).
  var onNavCommandConsumed: () -> Void = {}
  /// Viewport scrolled/resized → windowed highlight (re)issue (Phase 4 driver). The
  /// payload is the per-side 1-based visible SOURCE-line window, not rendered-row
  /// indices — the coordinate the highlighter queries + the row lookup keys off.
  var onVisibleRangeChanged: (VisibleLineWindow) -> Void = { _ in }
  /// An expander widget's reveal button → the reducer's incremental `expandGap`.
  var onExpandGap: (_ gap: Int, _ step: ExpansionState.Step, _ direction: ExpansionState.Direction) -> Void = {
    _, _, _ in
  }
  /// A comment-thread widget row's edit tap → open it in the composer.
  var onEditComment: (UUID) -> Void = { _ in }
  /// Anchors (head comment ids) whose thread is collapsed in this tab. Threaded into the
  /// resolver so the widget renders its collapsed summary; part of the content signature
  /// so a toggle re-projects the tree and the collapse takes visible effect.
  var collapsedThreads: Set<UUID> = []
  /// A comment-thread chevron tap → toggle that thread's collapsed state.
  var onToggleCommentThreadCollapsed: (UUID) -> Void = { _ in }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let coordinator = context.coordinator
    let controller = coordinator.controller
    controller.onVisibleRangeChanged = { [weak coordinator] window in
      coordinator?.onVisibleRangeChanged(window)
    }
    syncCallbacks(coordinator)
    controller.wordDiffEnabled = wordDiffEnabled
    controller.widgetResolver = makeResolver(coordinator)
    // Construct the interaction controllers ONCE (gutter overlay + a11y provider),
    // BEFORE the first `apply` so the provider's `reload()` fires from it.
    coordinator.installInteraction()
    let tree = buildTree()
    controller.apply(tree: tree, mode: mode, scrollPreserving: false)
    controller.setSyntax(old: oldStyleRuns, new: newStyleRuns)
    controller.setHighlightBlobs(old: oldBlob, new: newBlob, disabled: highlightingDisabled)
    coordinator.rebuildKeyboardNav()
    coordinator.syncExpansion(expansion: expansion, revealed: revealed, hunks: hunks, file: file, rebuilt: true)
    coordinator.keyboardNav?.revealFirstChange()
    coordinator.lastSignature = signature
    coordinator.lastMode = mode
    coordinator.lastGeneration = generation
    coordinator.lastExpansion = expansion
    coordinator.lastRevealedCounts = revealed.mapValues(\.count)
    coordinator.lastSyntaxVersion = syntaxVersion
    coordinator.lastHighlightBlobKey = highlightBlobKey
    return controller.scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    let coordinator = context.coordinator
    let controller = coordinator.controller
    syncCallbacks(coordinator)
    controller.wordDiffEnabled = wordDiffEnabled
    controller.widgetResolver = makeResolver(coordinator)
    coordinator.gutter?.frame = controller.scrollView.contentView.frame

    // Change classification. `generation` bumps on BOTH a re-diff and an incremental
    // expand — the two are told apart by the expansion delta: a generation bump WITHOUT
    // an expansion change is a real re-diff (rebuild); a bump WITH one is an expand
    // (incremental splice, no rebuild — F7).
    let sigChanged = coordinator.lastSignature != signature
    let generationChanged = coordinator.lastGeneration != generation
    let expansionChanged = coordinator.lastExpansion != expansion
    let revealedCounts = revealed.mapValues(\.count)
    let revealedChanged = coordinator.lastRevealedCounts != revealedCounts
    let contentChanged = sigChanged || (generationChanged && !expansionChanged)

    if contentChanged {
      // Content changed (re-diff / comment insert-remove / composer open-close):
      // re-project the tree scroll-preserving, then re-apply the live expansion state
      // (the fresh tree is collapsed) and rebuild the keyboard nav over the new tree.
      controller.apply(tree: buildTree(), mode: mode, scrollPreserving: true)
      controller.setSyntax(old: oldStyleRuns, new: newStyleRuns)
      controller.setHighlightBlobs(old: oldBlob, new: newBlob, disabled: highlightingDisabled)
      coordinator.lastHighlightBlobKey = highlightBlobKey
      coordinator.rebuildKeyboardNav()
      coordinator.syncExpansion(expansion: expansion, revealed: revealed, hunks: hunks, file: file, rebuilt: true)
      coordinator.lastSyntaxVersion = syntaxVersion
    } else {
      if coordinator.lastMode != mode {
        // Only the unified↔split preference flipped: O(log #hunks) re-seek, no rebuild.
        controller.toggleMode(to: mode)
        coordinator.rebuildKeyboardNav()
      }
      if expansionChanged || revealedChanged {
        // An expand / collapse without a re-diff: splice ONLY the changed gaps.
        coordinator.syncExpansion(
          expansion: expansion, revealed: revealed, hunks: hunks, file: file, rebuilt: false)
      }
      // Windowed syntax arrival: push the latest runs and repaint the visible rows —
      // no tree rebuild, cache-hit on rows whose runs are unchanged.
      if coordinator.lastSyntaxVersion != syntaxVersion {
        controller.setSyntax(old: oldStyleRuns, new: newStyleRuns)
        coordinator.lastSyntaxVersion = syntaxVersion
      }
      // Pull-model: re-warm the span cache when the blobs / size gate change without a
      // full re-project (e.g. the size gate resolving after the first batch).
      if coordinator.lastHighlightBlobKey != highlightBlobKey {
        controller.setHighlightBlobs(old: oldBlob, new: newBlob, disabled: highlightingDisabled)
        coordinator.lastHighlightBlobKey = highlightBlobKey
      }
    }

    // Drain a menu-driven nav intent into the SAME `DiffKeyboardNav` the letter keys
    // drive (the "Diff" menu path). Runs AFTER the tree/mode reconcile above so the nav
    // is rebuilt over the current tree, then clears the one-shot in the reducer.
    if let command = pendingNavCommand {
      coordinator.performMenuNav(command)
      onNavCommandConsumed()
    }

    // Reconcile the transient INLINE editor for a not-yet-committed (new) comment.
    coordinator.reconcileTransientComposer(draft: composerDraft, comments: comments)
    coordinator.focusViewportIfNeeded(editing: composerDraft != nil)

    coordinator.lastSignature = signature
    coordinator.lastMode = mode
    coordinator.lastGeneration = generation
    coordinator.lastExpansion = expansion
    coordinator.lastRevealedCounts = revealedCounts
  }

  static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
    coordinator.tearDown()
  }

  // MARK: - Projection

  private func buildTree() -> ChunkTree {
    // The pure rebuild renders at the loaded context with collapsed-gap expanders;
    // the live `expansion` / `revealed` is re-applied incrementally on top via
    // `Coordinator.syncExpansion` (O(log n) splice), never baked into a full rebuild.
    ChunkTreeBuilder.build(file: file, hunks: hunks, mode: mode, comments: comments)
  }

  private func makeResolver(_ coordinator: Coordinator) -> DiffWidgetResolver {
    DiffWidgetResolver(
      file: file,
      hunks: hunks,
      comments: comments,
      onExpand: { [weak coordinator] gap, step, direction in
        coordinator?.onExpandGap(gap.hunkIndex, step, direction)
      },
      onEditComment: { [weak coordinator] id in coordinator?.onEditComment(id) },
      collapsedThreads: collapsedThreads,
      onToggleCommentThreadCollapsed: { [weak coordinator] id in coordinator?.onToggleCommentThreadCollapsed(id) },
      composerStore: { [weak coordinator] anchorID in
        guard let coordinator, let store = coordinator.composerStore, coordinator.composerAnchorID == anchorID
        else { return nil }
        return store
      }
    )
  }

  private func syncCallbacks(_ coordinator: Coordinator) {
    // Refresh so the latest SwiftUI closures (fresh store) are used on each pass.
    coordinator.send = send
    coordinator.onVisibleRangeChanged = onVisibleRangeChanged
    coordinator.onExpandGap = onExpandGap
    coordinator.onEditComment = onEditComment
    coordinator.onToggleCommentThreadCollapsed = onToggleCommentThreadCollapsed
    coordinator.file = file
    coordinator.filePath = filePath
    coordinator.source = source
    coordinator.comments = comments
    coordinator.composerStore = composerStore
    coordinator.composerAnchorID = composerDraft?.id
  }

  /// The content signature that triggers a full tree re-projection. `comments` covers
  /// a thread insert / remove / edit; `wordDiffEnabled` re-renders on a gate flip;
  /// `composerAnchorID` flips an existing thread's display↔editing (its widget refuses
  /// recycle, so the re-project mounts a fresh editing host). `generation` (a re-diff
  /// vs expand token) and `expansion` are classified separately in `updateNSView`.
  private var signature: Coordinator.Signature {
    Coordinator.Signature(
      comments: comments, wordDiffEnabled: wordDiffEnabled, composerAnchorID: composerDraft?.id,
      collapsedThreads: collapsedThreads)
  }

  /// Identity of the warm inputs (per-side blob OID + the size gate) — the controller
  /// re-warms only when this changes, so a plain SwiftUI update pass doesn't re-kick a
  /// warm the missing-line check would no-op anyway.
  private var highlightBlobKey: String {
    "\(oldBlob?.blobOID ?? "-")|\(newBlob?.blobOID ?? "-")|\(highlightingDisabled)"
  }

  @MainActor
  final class Coordinator {
    let controller = DiffViewportController()

    /// Single-file interaction controllers, constructed once by `installInteraction`
    /// and re-fed live via the coordinator's refreshed closures.
    private(set) var keyboardNav: DiffKeyboardNav?
    private(set) var gutter: GutterRibbonController?

    // Live inputs, refreshed each SwiftUI pass (read by the long-lived callbacks).
    var send: (DiffReviewFeature.Action) -> Void = { _ in }
    var onVisibleRangeChanged: (VisibleLineWindow) -> Void = { _ in }
    var onExpandGap: (Int, ExpansionState.Step, ExpansionState.Direction) -> Void = { _, _, _ in }
    var onEditComment: (UUID) -> Void = { _ in }
    var onToggleCommentThreadCollapsed: (UUID) -> Void = { _ in }
    var file: FileChange?
    var filePath: String = ""
    var source: DiffSource = .workingTree
    var comments: [ReviewComment] = []
    var composerStore: StoreOf<CommentComposer>?
    var composerAnchorID: UUID?

    // Change-detection baselines.
    var lastSignature: Signature?
    var lastMode: DiffViewMode = .unified
    var lastSyntaxVersion: Int = -1
    var lastHighlightBlobKey: String = ""
    var lastGeneration: Int = .min
    var lastExpansion: ExpansionState = .collapsed
    var lastRevealedCounts: [Int: Int] = [:]

    /// The anchor of the transient inline editor currently inserted for a NEW,
    /// not-yet-committed comment (removed on cancel; replaced by the tree swap on
    /// commit). `nil` when no such editor is live.
    private var transientCommentAnchorID: UUID?
    private var installed = false
    private var didFocusViewport = false

    struct Signature: Equatable {
      var comments: [ReviewComment]
      var wordDiffEnabled: Bool
      var composerAnchorID: UUID?
      var collapsedThreads: Set<UUID> = []
    }

    // MARK: - Install (once)

    /// Build + mount the gutter overlay and the accessibility provider. Idempotent —
    /// the interaction controllers persist for the coordinator's lifetime and are fed
    /// live by the refreshed closures.
    func installInteraction() {
      guard !installed else { return }
      installed = true

      let gutter = GutterRibbonController()
      gutter.controller = controller
      gutter.onOpenComposer = { [weak self] side, startLine, endLine, snippet, context in
        guard let self else { return }
        self.send(
          .openCommentComposer(
            filePath: self.filePath, source: self.source, side: side, startLine: startLine, endLine: endLine,
            anchorSnippet: snippet, contextBefore: context))
      }
      gutter.frame = controller.scrollView.contentView.frame
      gutter.autoresizingMask = [.width, .height]
      controller.scrollView.addFloatingSubview(gutter, for: .vertical)
      self.gutter = gutter

      let provider = DiffAXProvider(
        documentView: controller.documentView,
        snapshot: { [weak self] in
          self?.accessibilitySnapshot() ?? DiffAXSnapshot(tree: ChunkTree(), mode: .unified)
        },
        reveal: { [weak self] row in self?.controller.reveal(row: row, align: .center) },
        setKeyboardFocus: { [weak self] row in
          self?.keyboardNav?.syncFocusedRow(row)
          self?.controller.axProvider?.keyboardDidFocus(row)
        },
        addComment: { [weak self] side, line in
          guard let self else { return }
          let payload = self.controller.anchorPayload(side: side, startLine: line, endLine: line)
          self.send(
            .openCommentComposer(
              filePath: self.filePath, source: self.source, side: side, startLine: line, endLine: line,
              anchorSnippet: payload.snippet, contextBefore: payload.contextBefore))
        },
        expand: { [weak self] gap in
          guard let self else { return }
          self.send(
            .expandGap(
              key: DiffDocumentKey(path: self.filePath, source: self.source), gap: gap.hunkIndex, step: .fine,
              direction: .both))
        },
        liveWidgetView: { [weak self] chunkID in
          guard let self, let node = self.controller.tree.nodesByID[chunkID] else { return nil }
          return self.controller.pools[node.chunk.reuseKind]?.getView(forKey: chunkID)
        })
      controller.axProvider = provider
    }

    /// The a11y snapshot read fresh on every VoiceOver query — reuses the SAME
    /// comments-by-anchor + `FileHeaderWidget.Model` mapping the widget resolver does,
    /// over the controller's live tree / mode.
    private func accessibilitySnapshot() -> DiffAXSnapshot {
      DiffAXSnapshot(
        tree: controller.tree,
        mode: controller.currentMode,
        comments: { [weak self] anchorID in (self?.comments ?? []).filter { $0.id == anchorID } },
        fileHeader: { [weak self] fileID in
          guard let self, let file = self.file, file.id == fileID else { return nil }
          return FileHeaderWidget.Model.make(from: file, canCommentOnFile: false)
        })
    }

    // MARK: - Keyboard nav (rebuilt on each tree swap)

    /// (Re)build the keyboard nav over the controller's CURRENT tree and route it into
    /// the document view. `DiffKeyboardNav` snapshots the tree instance, so a full
    /// `apply` (new instance) needs a fresh nav; an in-place splice keeps the instance.
    func rebuildKeyboardNav() {
      let nav = DiffKeyboardNav(
        controller: controller, tree: controller.tree, send: { [weak self] action in self?.send(action) })
      nav.onFocusRow = { [weak self] row in self?.controller.axProvider?.keyboardDidFocus(row) }
      keyboardNav = nav
      controller.documentView.keyboardNav = nav
    }

    /// Forward a menu-driven nav intent to the live `DiffKeyboardNav` — the SAME path
    /// the single-letter `n`/`p`/`]`/`[` keys drive, so the "Diff" menu items and the
    /// keys stay in lockstep. A no-op when no nav is built yet (no diff on screen).
    func performMenuNav(_ command: DiffReviewFeature.MenuNavCommand) {
      switch command {
      case .nextChange: keyboardNav?.perform(.nextChange)
      case .prevChange: keyboardNav?.perform(.prevChange)
      case .nextFile: keyboardNav?.perform(.nextFile)
      case .prevFile: keyboardNav?.perform(.prevFile)
      }
    }

    /// Take first responder once the viewport is on-screen so single-letter nav works
    /// without a click — but never while the inline editor is up (it owns first
    /// responder for typing).
    func focusViewportIfNeeded(editing: Bool) {
      guard !didFocusViewport, !editing, let window = controller.documentView.window else { return }
      didFocusViewport = true
      window.makeFirstResponder(controller.documentView)
    }

    // MARK: - Incremental expansion (F7 — O(log n) splice, NOT a rebuild)

    /// Reconcile the live `expansion` / `revealed` against the tree via per-gap
    /// `applyExpansion` / `collapseExpansion`. `rebuilt` ⇒ the tree was just re-projected
    /// collapsed, so diff against a collapsed baseline (re-apply every expanded gap);
    /// otherwise diff against the last-applied state (splice only the changed gaps).
    func syncExpansion(
      expansion: ExpansionState, revealed: [Int: [DiffLine]], hunks: [DiffHunk], file: FileChange, rebuilt: Bool
    ) {
      let from = rebuilt ? .collapsed : lastExpansion
      let baseCounts = rebuilt ? [:] : lastRevealedCounts
      // Reuse the reducer's exact gap geometry (pure over `hunks`).
      let geometry = DiffDocument(file: file, hunks: hunks)
      for gap in 0...hunks.count {
        let size = geometry.gapRangeSize(gap)
        let isTrailing = geometry.isTrailingGap(gap)
        let before = from.resolve(gap: gap, rangeSize: size, isTrailing: isTrailing)
        let after = expansion.resolve(gap: gap, rangeSize: size, isTrailing: isTrailing)
        let revealedLines = revealed[gap] ?? []
        let revealedCountChanged = (baseCounts[gap] ?? 0) != revealedLines.count
        guard before != after || revealedCountChanged else { continue }
        let gapKey = GapKey(hunkIndex: gap)
        let wantsReveal = after.renderAll || after.fromStart > 0 || after.fromEnd > 0
        let wasRevealed = before.renderAll || before.fromStart > 0 || before.fromEnd > 0
        if wantsReveal {
          // The slice arrives after the expand tick; splice once it is present. An
          // empty slice (not yet loaded) leaves the collapsed expander for now — the
          // populating `.gapSliceLoaded` re-enters here and splices it.
          if !revealedLines.isEmpty {
            controller.applyExpansion(gap: gapKey, region: after, revealedLines: revealedLines)
          }
        } else if wasRevealed {
          controller.collapseExpansion(gap: gapKey)
        }
      }
    }

    // MARK: - Inline comment composer (F1+F5 — NO modal sheet)

    /// Keep a transient INLINE editing widget in step with the open composer for a
    /// NEW (not-yet-committed) comment. Opening the composer on an anchor absent from
    /// `comments` inserts an editing widget at its line; cancelling (composer closes
    /// with the anchor still uncommitted) removes it. A commit lands the anchor in
    /// `comments`, so the content re-project renders the display thread and the guard
    /// below keeps us from removing that committed widget.
    func reconcileTransientComposer(draft: ReviewComment?, comments: [ReviewComment]) {
      let openAnchor = draft?.id
      // Drop a stale transient editor whose composer moved on / closed and that never
      // committed (a committed anchor is left to the tree swap).
      if let transient = transientCommentAnchorID, transient != openAnchor,
        !comments.contains(where: { $0.id == transient })
      {
        controller.removeCommentWidget(anchorID: transient)
        transientCommentAnchorID = nil
      }
      // Seed a fresh transient editor when the composer opens on a brand-new anchor.
      if let draft, transientCommentAnchorID != draft.id, !comments.contains(where: { $0.id == draft.id }) {
        controller.insertCommentWidget(
          side: draft.side, startLine: draft.startLine, endLine: draft.endLine, anchorID: draft.id,
          estimatedHeight: ChunkLayoutMetrics.production.commentThreadHeight)
        transientCommentAnchorID = draft.id
      }
      if openAnchor == nil { transientCommentAnchorID = nil }
    }

    func tearDown() {
      controller.onVisibleRangeChanged = nil
      controller.onHit = nil
      controller.axProvider = nil
      controller.documentView.keyboardNav = nil
      keyboardNav = nil
      gutter?.removeFromSuperview()
      gutter = nil
    }
  }
}
