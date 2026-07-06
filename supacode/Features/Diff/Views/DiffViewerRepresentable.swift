import AppKit
import SwiftUI

/// SwiftUI bridge to the AppKit `DiffTableController`. Mirrors the
/// `CommandPalettePanelHost` idiom: the coordinator owns the AppKit object, the
/// representable re-enters through `updateNSView`, and teardown happens in
/// `dismantleNSView`. `revision` is bumped by the reducer on every live re-diff;
/// a change in `revision`/`mode` (not row identity) is what triggers a re-apply
/// with scroll preserved.
///
/// Phase 4: syntax highlighting moved OUT of this coordinator into the reducer's
/// neon-backed `DiffHighlightEngine` driver + the tree-backed viewport. This legacy
/// `DiffTableController` viewer therefore renders plain from wave 4 until the Phase-13
/// seam swap replaces it wholesale — intentional (the whole plan deletes this viewer;
/// no temporary highlight bridge is built for it). `main` is untouched; the swap is
/// atomic at Phase 13.
struct DiffViewerRepresentable: NSViewRepresentable {
  let rows: [DiffRow]
  let mode: DiffViewMode
  let revision: Int
  var onExpandGap: (Int) -> Void = { _ in }
  /// Handed the controller once so Phase 5 can reach the geometry API.
  var onController: (DiffTableController) -> Void = { _ in }
  var onVisibleRangeChanged: (Range<Int>) -> Void = { _ in }
  /// Gutter "+"/drag resolved a range → open the composer (Phase 5).
  var onOpenComposer:
    (_ side: DiffSide, _ startLine: Int, _ endLine: Int, _ snippet: String, _ contextBefore: String) -> Void = {
      _, _, _, _, _ in
    }
  /// An inline comment thread row was clicked → open it to edit (Phase 5).
  var onCommentTap: (UUID) -> Void = { _ in }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let controller = context.coordinator.controller
    controller.onExpandGap = { [coordinator = context.coordinator] anchor in
      coordinator.onExpandGap(anchor)
    }
    controller.onVisibleRangeChanged = { [coordinator = context.coordinator] range in
      coordinator.handleVisibleRange(range)
    }
    controller.onOpenComposer = { [coordinator = context.coordinator] side, start, end, snippet, context in
      coordinator.onOpenComposer(side, start, end, snippet, context)
    }
    controller.onCommentTap = { [coordinator = context.coordinator] id in
      coordinator.onCommentTap(id)
    }
    context.coordinator.onExpandGap = onExpandGap
    context.coordinator.onVisibleRangeChanged = onVisibleRangeChanged
    context.coordinator.onOpenComposer = onOpenComposer
    context.coordinator.onCommentTap = onCommentTap
    onController(controller)
    controller.apply(rows: rows, mode: mode, scrollPreserving: false)
    context.coordinator.lastRevision = revision
    context.coordinator.lastMode = mode
    return controller.scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    // Refresh the callbacks so the latest closures (capturing fresh SwiftUI
    // state) are used, then apply only when something actually changed.
    context.coordinator.onExpandGap = onExpandGap
    context.coordinator.onVisibleRangeChanged = onVisibleRangeChanged
    context.coordinator.onOpenComposer = onOpenComposer
    context.coordinator.onCommentTap = onCommentTap
    let coordinator = context.coordinator
    guard coordinator.lastRevision != revision || coordinator.lastMode != mode else { return }
    let preserve = coordinator.lastMode == mode  // mode switch reloads; re-diff preserves scroll.
    coordinator.lastRevision = revision
    coordinator.lastMode = mode
    coordinator.controller.apply(rows: rows, mode: mode, scrollPreserving: preserve)
  }

  static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
    coordinator.tearDown()
  }

  @MainActor
  final class Coordinator {
    let controller = DiffTableController()
    var onExpandGap: (Int) -> Void = { _ in }
    var onVisibleRangeChanged: (Range<Int>) -> Void = { _ in }
    var onOpenComposer: (DiffSide, Int, Int, String, String) -> Void = { _, _, _, _, _ in }
    var onCommentTap: (UUID) -> Void = { _ in }
    var lastRevision = -1
    var lastMode: DiffViewMode = .unified

    /// Forwards the viewport change to SwiftUI. Highlighting is no longer driven
    /// here — the reducer's neon `DiffHighlightEngine` owns it (Phase 4), consumed
    /// by the tree-backed viewport at the Phase-13 swap.
    func handleVisibleRange(_ range: Range<Int>) {
      onVisibleRangeChanged(range)
    }

    func tearDown() {
      controller.onExpandGap = nil
      controller.onVisibleRangeChanged = nil
    }
  }
}
