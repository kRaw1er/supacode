import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

/// Scoped host for the usage pill (mirrors `WindowTitleHost` /
/// `CommandPaletteOverlayHost`). Owns the `@Shared(.usagePillEnabled)` read so
/// SwiftUI observes the toggle HERE, not in `ContentView.body` — a usage tick or
/// a toggle flip invalidates only this host, never the sidebar (AC-P6).
///
/// The `.onChange` on the toggle carries the flip into the reducer's lifecycle
/// (`@Shared` alone doesn't notify the reducer). Always mounted, so a toggle
/// change from the Settings window still fires even when the pill is hidden.
struct UsagePillHost: View {
  let store: StoreOf<UsageFeature>
  @Shared(.usagePillEnabled) private var pillEnabled: Bool

  var body: some View {
    Group {
      if pillEnabled {
        UsagePillView(store: store)
      } else {
        EmptyView()
      }
    }
    .onChange(of: pillEnabled) { _, newValue in
      store.send(.pillEnabledChanged(newValue))
    }
  }
}
