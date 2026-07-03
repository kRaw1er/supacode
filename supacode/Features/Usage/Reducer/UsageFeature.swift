import ComposableArchitecture
import Foundation
import SupacodeSettingsShared
import SwiftUI

/// Per-provider usage state: the last GOOD snapshot kept separate from the
/// transient `status` so a failure changes status without discarding data. v1
/// holds exactly one of these (single provider); a second provider is its own
/// `ProviderUsage` + poll effect (see the plan's scoping note).
nonisolated struct ProviderUsage: Equatable, Sendable {
  /// Last good data — survives transient errors so the pill keeps showing values.
  var lastSnapshot: UsageSnapshot?
  var status: UsageStatus = .neverFetched
  /// Set for `dedupeTTL` after each completed fetch, then cleared by a
  /// cancellable clock timer. A clock-driven cooldown (rather than a stored
  /// `Date` + `\.date` dependency) keeps the reducer's ONLY time source the
  /// injected `\.continuousClock` — deterministic under `TestClock`, and safe
  /// in the app test host (no unimplemented `\.date` access).
  var isInCooldown: Bool = false
  /// In-flight guard so overlapping triggers dedupe to a single fetch.
  var isFetching: Bool = false
  /// Set after an ACL deny so auto-fetches stop hitting the Keychain; only a
  /// manual retry re-attempts.
  var deniedLatched: Bool = false
}

@Reducer
struct UsageFeature {
  @ObservableState
  struct State: Equatable {
    var usage = ProviderUsage()
    var isPopoverPresented = false
    /// Master toggle. Read here so the reducer can gate the loop; lifecycle
    /// changes arrive via the explicit `.pillEnabledChanged` action because a
    /// `@Shared` mutation alone does not notify the reducer.
    @Shared(.usagePillEnabled) var pillEnabled: Bool
  }

  enum Action: BindableAction, Equatable {
    /// Start the poll loop (sent from `AppFeature.appLaunched`). No-op if disabled.
    case task
    /// A refresh trigger. `forced` bypasses the latch + TTL (manual button);
    /// non-forced is the interval / foreground / popover-open path.
    case refreshRequested(forced: Bool)
    case usageResponse(UsageFetchResult)
    /// The post-fetch dedupe cooldown elapsed.
    case cooldownExpired
    /// Pill tapped — open the popover and refresh (an explicit action instead of
    /// a `.binding(.set(…))` whose key path isn't `Sendable`).
    case popoverOpenTapped
    case scenePhaseChanged(ScenePhase)
    /// Settings toggle changed — start / stop the whole machine.
    case pillEnabledChanged(Bool)
    /// User tapped Retry on an error state — forces past the deny latch + TTL.
    case manualRetryTapped
    case binding(BindingAction<State>)
  }

  private nonisolated enum CancelID { case poll, fetch, cooldown }

  /// Skip a non-forced fetch while a fetch completed within this window.
  private static let dedupeTTL: Duration = .seconds(15)
  /// Background poll cadence.
  private static let pollInterval: Duration = .seconds(180)

  // Type-based dependency (not the `\.usageClient` key path): under the module's
  // `@MainActor` default the key path isn't `Sendable`, matching how the other
  // reducers here reference clients (`@Dependency(AnalyticsClient.self)`).
  @Dependency(UsageClient.self) private var usageClient
  @Dependency(\.continuousClock) private var clock

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .task:
        guard state.pillEnabled else { return .none }
        return startPolling()

      case .pillEnabledChanged(let enabled):
        if enabled {
          // ON → restart the loop; its immediate tick fetches so we go
          // neverFetched → ok rather than showing prior stale-as-fresh.
          return startPolling()
        }
        // OFF → tear everything down, zero network / Keychain, close popover.
        state.usage.isFetching = false
        state.usage.isInCooldown = false
        state.isPopoverPresented = false
        return .merge(
          .cancel(id: CancelID.poll),
          .cancel(id: CancelID.fetch),
          .cancel(id: CancelID.cooldown)
        )

      case .refreshRequested(let forced):
        guard state.pillEnabled else { return .none }
        // After a latched deny, only a manual (forced) retry re-attempts.
        if state.usage.deniedLatched, !forced { return .none }
        if state.usage.isFetching { return .none }
        // Within the post-fetch cooldown, non-forced triggers dedupe.
        if !forced, state.usage.isInCooldown { return .none }
        state.usage.isFetching = true
        return .run { [usageClient] send in
          let result = await usageClient.fetch(.claude)
          // A pill-disable mid-flight cancels this effect; guard so a late
          // arrival can't resurrect state after teardown.
          guard !Task.isCancelled else { return }
          await send(.usageResponse(result))
        }
        .cancellable(id: CancelID.fetch)

      case .usageResponse(let result):
        state.usage.isFetching = false
        state.usage.isInCooldown = true
        merge(result, into: &state.usage)
        // Start (or restart) the dedupe cooldown.
        return .run { [clock] send in
          try await clock.sleep(for: Self.dedupeTTL)
          await send(.cooldownExpired)
        }
        .cancellable(id: CancelID.cooldown, cancelInFlight: true)

      case .cooldownExpired:
        state.usage.isInCooldown = false
        return .none

      case .popoverOpenTapped:
        state.isPopoverPresented = true
        return .send(.refreshRequested(forced: false))

      case .scenePhaseChanged(let phase):
        guard state.pillEnabled, phase == .active else { return .none }
        return .send(.refreshRequested(forced: false))

      case .manualRetryTapped:
        return .send(.refreshRequested(forced: true))

      case .binding:
        // The popover only ever OPENS via `.popoverOpenTapped` (which refreshes);
        // the two-way `$store.isPopoverPresented` binding exists so SwiftUI's
        // outside-click DISMISS syncs back to state. Nothing to do here.
        // (A `.binding(\.isPopoverPresented)` key-path match would need a
        // `Sendable` key path, which this MainActor-default module can't provide.)
        return .none
      }
    }
  }

  /// Kicks off the poll loop: an immediate tick, then every `pollInterval`.
  /// `cancelInFlight` so re-entry (re-enable, relaunch) restarts cleanly.
  private func startPolling() -> Effect<Action> {
    .run { [clock] send in
      while !Task.isCancelled {
        await send(.refreshRequested(forced: false))
        try await clock.sleep(for: Self.pollInterval)
      }
    }
    .cancellable(id: CancelID.poll, cancelInFlight: true)
  }

  /// Folds a fetch result into state. Success replaces the snapshot wholesale
  /// (which flushes cached limits on an account-identity change — no
  /// cross-account mixing); failures set `status` but keep `lastSnapshot`.
  private func merge(_ result: UsageFetchResult, into usage: inout ProviderUsage) {
    switch result {
    case .success(let snapshot):
      usage.lastSnapshot = snapshot
      usage.status = .fresh
      usage.deniedLatched = false
    case .notSignedIn:
      usage.status = .notSignedIn
    case .expired:
      usage.status = .expired
    case .stale:
      usage.status = .stale
    case .credentialsProblem(let denied):
      usage.status = .credentialsProblem
      if denied { usage.deniedLatched = true }
    }
  }
}
