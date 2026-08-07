import AppKit

/// The three custom VoiceOver rotors — **Changes / Files / Comments** — that let a
/// VoiceOver user hop hunk→hunk, file→file, comment→comment through the diff. Each
/// query seeks membership straight off the tree (`DiffAXProvider.rotorRows`), never
/// a retained array, so it survives a re-diff for free, and each result `reveal`s
/// the row (anchored scroll) BEFORE focus lands so an offscreen target scrolls in.
///
/// `itemLoadingDelegate` points at the provider for the huge-file
/// `NSAccessibilityElementLoading` hatch: when a target row isn't eagerly
/// materialized, the result carries an `itemLoadingToken` VoiceOver hands back to
/// realize exactly that one row.
@MainActor
final class DiffAXRotors: NSObject, @MainActor NSAccessibilityCustomRotorItemSearchDelegate {
  private unowned let provider: DiffAXProvider

  private lazy var changes = makeRotor(.changes)
  private lazy var files = makeRotor(.files)
  private lazy var comments = makeRotor(.comments)

  init(provider: DiffAXProvider) {
    self.provider = provider
    super.init()
  }

  /// The three rotors, in menu order (VO-U lists Changes / Files / Comments).
  func make() -> [NSAccessibilityCustomRotor] { [changes, files, comments] }

  private func makeRotor(_ kind: DiffAXRotorKind) -> NSAccessibilityCustomRotor {
    let rotor = NSAccessibilityCustomRotor(label: kind.rawValue, itemSearchDelegate: self)
    rotor.type = .custom  // default; explicit — these are app-defined categories
    rotor.itemLoadingDelegate = provider  // huge-file windowed hatch (§F)
    return rotor
  }

  // MARK: - NSAccessibilityCustomRotorItemSearchDelegate

  /// VoiceOver asks for the next / previous member of this rotor relative to
  /// `currentItem`. Reveal the resolved row first (anchored scroll), then return the
  /// live element — or, in the huge-file hatch, an `itemLoadingToken` result.
  func rotor(
    _ rotor: NSAccessibilityCustomRotor,
    resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters
  ) -> NSAccessibilityCustomRotor.ItemResult? {
    guard let kind = DiffAXRotorKind(rawValue: rotor.label) else { return nil }
    let membership = provider.rotorRows(for: kind)
    let current = (searchParameters.currentItem?.targetElement as? DiffLineAXElement)?.rowIndex
    guard let row = DiffAXRotorMembership.step(membership, from: current, direction: searchParameters.searchDirection)
    else { return nil }

    provider.reveal(row)  // anchored scroll BEFORE focus lands (offscreen reachability)

    // Comments rotor: target the live hosting view (rich content) when the row is
    // onscreen; otherwise the synthesized fallback below. Exactly one is live.
    if kind == .comments, let live = provider.liveWidgetElement(forRow: row) {
      return NSAccessibilityCustomRotor.ItemResult(targetElement: live)
    }
    if let element = provider.element(row) {
      return NSAccessibilityCustomRotor.ItemResult(targetElement: element)  // eager path
    }
    // Huge-file hatch: not eagerly materialized → hand back a load token VoiceOver
    // returns via `accessibilityElement(withToken:)` to realize just this row.
    return NSAccessibilityCustomRotor.ItemResult(
      itemLoadingToken: DiffAXRowToken(rowIndex: row), customLabel: provider.label(row))
  }
}

/// Pure next / previous stepping over a sorted membership array — factored out (a
/// caseless `enum`, no free functions) so the hunk-hop ordering is unit-testable
/// without an AppKit rotor. `membership` MUST be ascending. `nil` current starts at
/// the first (Next) / last (Previous) member; the ends return `nil` (no wrap — VO
/// stops at the boundary).
enum DiffAXRotorMembership {
  static func step(
    _ membership: [Int],
    from current: Int?,
    direction: NSAccessibilityCustomRotor.SearchDirection
  ) -> Int? {
    switch direction {
    case .next:
      guard let current else { return membership.first }
      return membership.first { $0 > current }
    case .previous:
      guard let current else { return membership.last }
      return membership.last { $0 < current }
    @unknown default:
      return nil
    }
  }
}
