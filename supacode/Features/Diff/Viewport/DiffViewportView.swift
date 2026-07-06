import AppKit

/// The flipped `documentView` of the diff viewport's `NSScrollView`. Flipped
/// (top-down y) so chunk `yOrigin`s match the tree's y-axis and the NSTableView
/// substrate we replace (`DiffTableController`). `layout()` runs the controller's
/// recycle loop — the AppKit-coalesced (one `layout()` per frame) analog of
/// pierre's rAF `queueRender` (`UniversalRenderingManager.ts:7`).
@MainActor
final class DiffViewportView: NSView {
  weak var controller: DiffViewportController?

  /// Phase 10 — single-letter diff-body navigation (`n`/`p`/`[`/`]`/`j`/`k`/…). Set
  /// by the viewport seam once the tree + reducer send are wired. Routed from
  /// `keyDown` WHILE THIS VIEW HOLDS FIRST RESPONDER, so the keys are inert whenever
  /// the comment editor (a different first responder) is focused — AppKit routes
  /// `keyDown` to the current first responder, never broadcasts it, so no FR guard is
  /// needed here (unlike `performKeyEquivalent`).
  weak var keyboardNav: DiffKeyboardNav?

  override var isFlipped: Bool { true }

  /// The viewport takes first responder so diff-body key navigation works. The
  /// comment editor's `NSHostingView` steals FR for typing (mutually exclusive).
  override var acceptsFirstResponder: Bool { true }

  override func layout() {
    super.layout()
    controller?.layoutVisibleChunks()
  }

  /// Route single-letter nav keys to `DiffKeyboardNav` first; unhandled keys fall
  /// through to the responder chain (so ↑/↓/⌘-chords keep working).
  override func keyDown(with event: NSEvent) {
    if keyboardNav?.handle(event) == true { return }
    super.keyDown(with: event)
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
