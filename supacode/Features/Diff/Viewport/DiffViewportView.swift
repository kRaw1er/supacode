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
}
