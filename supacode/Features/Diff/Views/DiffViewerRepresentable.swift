import AppKit
import SwiftUI

/// SwiftUI bridge to the AppKit `DiffViewportController` — the Phase-13 seam swap
/// that retires the flat `DiffTableController` / `[DiffRow]` viewer. The coordinator
/// owns the controller; the representable re-enters through `updateNSView`, rebuilds
/// the dual-mode `ChunkTree` from the document's `hunks` + `comments` (via
/// `ChunkTreeBuilder`) whenever its content signature changes, and drives the
/// controller — `apply(tree:)` on a content change, `toggleMode` on a unified↔split
/// flip (O(log #hunks), no reproject). The `generation` token + comment set replace
/// the deleted `revision`/`rows` inputs.
///
/// Interaction is wired through the widget harness callbacks (expander taps → the
/// reducer's `expandGap`; comment-thread edit → `editComment`), not a per-row closure
/// on this view. Gated follow-ups (documented in the PR body): incremental blob-slice
/// reveal spliced into the live tree, gutter-drag comment CREATION, and the a11y
/// provider wiring. (Syntax-run compositing into `LineRowView` is now wired — the
/// reducer's `old/newStyleRuns` flow through `setSyntax`.)
struct DiffViewerRepresentable: NSViewRepresentable {
  let file: FileChange
  let hunks: [DiffHunk]
  let comments: [ReviewComment]
  let mode: DiffViewMode
  /// Monotonic load/expand token — a change re-projects the tree scroll-preserving.
  let generation: Int
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

  /// Viewport scrolled/resized → windowed highlight (re)issue (Phase 4 driver).
  var onVisibleRangeChanged: (Range<Int>) -> Void = { _ in }
  /// An expander widget's reveal button → the reducer's incremental `expandGap`.
  var onExpandGap: (_ gap: Int, _ step: ExpansionState.Step, _ direction: ExpansionState.Direction) -> Void = {
    _, _, _ in
  }
  /// A comment-thread widget row's edit tap → open it in the composer.
  var onEditComment: (UUID) -> Void = { _ in }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let coordinator = context.coordinator
    let controller = coordinator.controller
    controller.onVisibleRangeChanged = { [weak coordinator] range in
      coordinator?.onVisibleRangeChanged(range.rows)
    }
    syncCallbacks(coordinator)
    controller.wordDiffEnabled = wordDiffEnabled
    controller.widgetResolver = makeResolver(coordinator)
    let tree = buildTree()
    controller.apply(tree: tree, mode: mode, scrollPreserving: false)
    controller.setSyntax(old: oldStyleRuns, new: newStyleRuns)
    coordinator.lastSignature = signature
    coordinator.lastMode = mode
    coordinator.lastSyntaxVersion = syntaxVersion
    return controller.scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    let coordinator = context.coordinator
    let controller = coordinator.controller
    syncCallbacks(coordinator)
    controller.wordDiffEnabled = wordDiffEnabled
    controller.widgetResolver = makeResolver(coordinator)

    let contentChanged = coordinator.lastSignature != signature
    if contentChanged {
      // Content changed (re-diff / comment insert-remove): re-project the tree,
      // scroll-preserving by line identity, in the current render mode.
      controller.apply(tree: buildTree(), mode: mode, scrollPreserving: true)
      coordinator.lastSignature = signature
      coordinator.lastMode = mode
    } else if coordinator.lastMode != mode {
      // Only the unified↔split preference flipped: O(log #hunks) re-seek, no rebuild.
      controller.toggleMode(to: mode)
      coordinator.lastMode = mode
    }

    // Windowed syntax arrival (or a content change that reset the tree): push the
    // latest runs and repaint the visible rows — no tree rebuild, cache-hit on rows
    // whose runs are unchanged.
    if contentChanged || coordinator.lastSyntaxVersion != syntaxVersion {
      controller.setSyntax(old: oldStyleRuns, new: newStyleRuns)
      coordinator.lastSyntaxVersion = syntaxVersion
    }
  }

  static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
    coordinator.tearDown()
  }

  // MARK: - Projection

  private func buildTree() -> ChunkTree {
    // Incremental blob-slice reveal is a gated follow-up, so the pure rebuild
    // renders at the loaded context with collapsed-gap expanders (the reducer's
    // `ExpansionState` / `revealed` machinery is intact for the follow-up splice).
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
      onEditComment: { [weak coordinator] id in coordinator?.onEditComment(id) }
    )
  }

  private func syncCallbacks(_ coordinator: Coordinator) {
    // Refresh so the latest SwiftUI closures (fresh store) are used on each pass.
    coordinator.onVisibleRangeChanged = onVisibleRangeChanged
    coordinator.onExpandGap = onExpandGap
    coordinator.onEditComment = onEditComment
  }

  /// The content signature that triggers a full tree re-projection. `generation`
  /// covers a re-diff / expand token; `comments` covers a thread insert / remove
  /// / edit (which does not bump `generation`); `wordDiffEnabled` re-renders on a
  /// gate flip. Mode is handled separately (`toggleMode`).
  private var signature: Coordinator.Signature {
    Coordinator.Signature(generation: generation, comments: comments, wordDiffEnabled: wordDiffEnabled)
  }

  @MainActor
  final class Coordinator {
    let controller = DiffViewportController()
    var onVisibleRangeChanged: (Range<Int>) -> Void = { _ in }
    var onExpandGap: (Int, ExpansionState.Step, ExpansionState.Direction) -> Void = { _, _, _ in }
    var onEditComment: (UUID) -> Void = { _ in }
    var lastSignature: Signature?
    var lastMode: DiffViewMode = .unified
    var lastSyntaxVersion: Int = -1

    struct Signature: Equatable {
      var generation: Int
      var comments: [ReviewComment]
      var wordDiffEnabled: Bool
    }

    func tearDown() {
      controller.onVisibleRangeChanged = nil
      controller.onHit = nil
    }
  }
}
