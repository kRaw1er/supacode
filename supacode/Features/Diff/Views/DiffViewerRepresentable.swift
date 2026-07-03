import AppKit
import SwiftUI

/// SwiftUI bridge to the AppKit `DiffTableController`. Mirrors the
/// `CommandPalettePanelHost` idiom: the coordinator owns the AppKit object, the
/// representable re-enters through `updateNSView`, and teardown happens in
/// `dismantleNSView`. `revision` is bumped by the reducer on every live re-diff;
/// a change in `revision`/`mode` (not row identity) is what triggers a re-apply
/// with scroll preserved.
struct DiffViewerRepresentable: NSViewRepresentable {
  let rows: [DiffRow]
  let mode: DiffViewMode
  let revision: Int
  var onExpandGap: (Int) -> Void = { _ in }
  /// Handed the controller once so Phase 5 can reach the geometry API.
  var onController: (DiffTableController) -> Void = { _ in }
  var onVisibleRangeChanged: (Range<Int>) -> Void = { _ in }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let controller = context.coordinator.controller
    controller.onExpandGap = { [coordinator = context.coordinator] anchor in
      coordinator.onExpandGap(anchor)
    }
    controller.onVisibleRangeChanged = { [coordinator = context.coordinator] range in
      coordinator.onVisibleRangeChanged(range)
    }
    context.coordinator.onExpandGap = onExpandGap
    context.coordinator.onVisibleRangeChanged = onVisibleRangeChanged
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
    var lastRevision = -1
    var lastMode: DiffViewMode = .unified

    func tearDown() {
      controller.onExpandGap = nil
      controller.onVisibleRangeChanged = nil
    }
  }
}
