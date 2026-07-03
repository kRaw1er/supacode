import Foundation
import Sharing

/// Typed AppStorage handle for the "Show Claude usage" toggle. Defined in the
/// shared module so both the app target (`UsageFeature.State` poll lifecycle,
/// `UsagePillHost` visibility) and `SupacodeSettingsFeature` (the Settings
/// toggle) read one source of truth for the key string + default. Defaults on
/// so the pill is discoverable on first launch.
nonisolated extension SharedReaderKey where Self == AppStorageKey<Bool>.Default {
  public static var usagePillEnabled: Self {
    Self[.appStorage("usagePillEnabled"), default: true]
  }
}
