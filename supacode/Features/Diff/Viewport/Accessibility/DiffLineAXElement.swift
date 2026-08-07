import AppKit

/// One synthesized accessibility element per **materialized** tree row, decoupled
/// from the recycle pool: identity is keyed by `rowIndex`, never by a recycled
/// `LineRowView`. Everything (role / label / value / frame / actions) is computed
/// **lazily from the tree** through the `unowned` provider on every VoiceOver query
/// — nothing is cached, so a scroll / recycle never invalidates it and a line far
/// off either edge is still reachable.
///
/// > Source-grounded deviation from the plan's `NSAccessibilityElement` subclass:
/// > in the Swift 6 macOS 26 SDK the `NSAccessibilityElement` **class** does NOT
/// > conform to the `NSAccessibilityElementProtocol` **protocol** (an
/// > `accessibilityIdentifier()` optionality mismatch makes the conformance
/// > uncompilable, and even a runtime `as?` cast fails), so an element built on that
/// > class can never be a `NSAccessibilityCustomRotor.ItemResult` target (its
/// > `targetElement:` / the loader return are typed `any NSAccessibilityElementProtocol`).
/// > We therefore build on `NSObject` and conform to `NSAccessibilityElementProtocol`
/// > directly — implementing the parent-space→screen frame ourselves — which keeps the
/// > element usable BOTH as a `documentView.accessibilityChildren` member AND as a
/// > rotor target. `@objc` on the informal `NSAccessibility` getters so AppKit
/// > dispatches to them.
///
/// `@MainActor` because AppKit accessibility runs on the main thread; the protocol
/// conformance is main-actor-isolated (Swift 6).
@MainActor
final class DiffLineAXElement: NSObject, @MainActor NSAccessibilityElementProtocol {
  /// The materialized-row index this element represents — the ONLY stored state.
  let rowIndex: Int
  private unowned let provider: DiffAXProvider

  init(rowIndex: Int, provider: DiffAXProvider) {
    self.rowIndex = rowIndex
    self.provider = provider
    super.init()
  }

  // MARK: - NSAccessibilityElementProtocol (required)

  /// The row's rect in SCREEN space — derived from the parent-space rect through the
  /// documentView / window chain (or the parent-space rect verbatim when there is no
  /// window, e.g. headless tests). VALID OFFSCREEN: the parent-space rect is a pure
  /// O(log n) tree seek with no dependency on a live view, so VoiceOver reaches lines
  /// far off both edges.
  func accessibilityFrame() -> NSRect { provider.screenFrame(rowIndex) }

  /// The AX parent is the flipped Phase-2 documentView (parent-space coordinates).
  func accessibilityParent() -> Any? { provider.documentView }

  // MARK: - Informal NSAccessibility getters (recomputed from the tree per query)

  @objc func accessibilityRole() -> NSAccessibility.Role? { provider.role(rowIndex) }

  @objc func accessibilityLabel() -> String? { provider.label(rowIndex) }

  /// The raw code text so VoiceOver's "read text" surfaces the line contents.
  @objc func accessibilityValue() -> Any? { provider.value(rowIndex) }

  @objc func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
    provider.customActions(rowIndex)
  }

  /// Activating an expander row runs the Phase-7 expand; any other row ignores it.
  @objc func accessibilityPerformPress() -> Bool { provider.performPress(rowIndex) }

  @objc func isAccessibilityFocused() -> Bool { false }

  /// VoiceOver moved its cursor onto this element → mirror into keyboard focus +
  /// scroll in (via the provider's shared `reveal`).
  @objc func setAccessibilityFocused(_ accessibilityFocused: Bool) {
    if accessibilityFocused { provider.voiceOverDidFocus(rowIndex) }
  }

  // MARK: - Convenience

  /// The row's rect in the AX parent's (documentView) coordinate system — a pure
  /// O(log n) tree seek, valid offscreen. The screen-space `accessibilityFrame()` is
  /// derived from this; exposed so callers / tests read the tree-anchored geometry
  /// directly (mirrors the `NSAccessibilityElement.accessibilityFrameInParentSpace`
  /// the plan referenced).
  var accessibilityFrameInParentSpace: NSRect { provider.frameInParent(rowIndex) }
}
