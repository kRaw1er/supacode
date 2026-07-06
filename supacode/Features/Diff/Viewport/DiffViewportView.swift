import AppKit

/// The flipped `documentView` of the diff viewport's `NSScrollView`. Flipped
/// (top-down y) so chunk `yOrigin`s match the tree's y-axis and the NSTableView
/// substrate we replace (`DiffTableController`). `layout()` runs the controller's
/// recycle loop — the AppKit-coalesced (one `layout()` per frame) analog of
/// pierre's rAF `queueRender` (`UniversalRenderingManager.ts:7`).
@MainActor
final class DiffViewportView: NSView {
  weak var controller: DiffViewportController?

  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    controller?.layoutVisibleChunks()
  }

  /// Appearance / Dynamic Type flip → bump `styleGeneration`, drop the CTLine
  /// cache, re-measure with top-visible anchoring (Phase 3 §Round-3 theme/font
  /// invalidation). The `effectiveAppearance` change propagates here because the
  /// document view is in the scroll view's hierarchy.
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    controller?.styleDidChange()
  }
}
