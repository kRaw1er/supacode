import Foundation

/// Pure precedence rule for resolving which terminal surface a review batch is
/// injected into. IDs only, so it is unit-testable without a `GhosttySurfaceView`.
/// `.diff`-kind tabs own no surface and are never eligible as a text sink (5.6).
enum TerminalTextSinkResolver {
  /// Precedence: the selected tab (if it is a terminal) with a focused surface →
  /// the first terminal tab (in tab order) with a focused-or-first surface →
  /// `nil` (caller blocks and warns).
  static func resolve(
    orderedTabs: [(id: TerminalTabID, kind: TerminalTabItem.Kind)],
    selectedTabID: TerminalTabID?,
    focusedSurfaceByTab: [TerminalTabID: UUID],
    surfaceIDsByTab: [TerminalTabID: [UUID]]
  ) -> (tabID: TerminalTabID, surfaceID: UUID)? {
    // 1. Selected tab, if terminal, with a focused surface.
    if let selected = selectedTabID,
      orderedTabs.first(where: { $0.id == selected })?.kind == .terminal,
      let focused = focusedSurfaceByTab[selected]
    {
      return (selected, focused)
    }
    // 2. First terminal tab (tab order) with a focused surface, else its first surface.
    for tab in orderedTabs where tab.kind == .terminal {
      if let focused = focusedSurfaceByTab[tab.id] { return (tab.id, focused) }
      if let first = surfaceIDsByTab[tab.id]?.first { return (tab.id, first) }
    }
    // 3. No terminal surface exists.
    return nil
  }
}
