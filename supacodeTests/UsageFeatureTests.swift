import ComposableArchitecture
import ConcurrencyExtras
import Foundation
import Sharing
import SupacodeSettingsShared
import SwiftUI
import Testing

@testable import supacode

@MainActor
struct UsageFeatureTests {
  private func makeStore(
    pillEnabled: Bool = true,
    initial: UsageFeature.State = UsageFeature.State(),
    clock: TestClock<Duration>,
    fetch: @escaping @Sendable (UsageProviderID) async -> UsageFetchResult
  ) -> TestStoreOf<UsageFeature> {
    @Shared(.usagePillEnabled) var enabled
    $enabled.withLock { $0 = pillEnabled }
    return TestStore(initialState: initial) {
      UsageFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.usageClient.fetch = fetch
    }
  }

  @Test func taskStartsPollingAndFetchesImmediately() async {
    let snapshot = UsageFixtures.snapshot()
    let clock = TestClock()
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      let store = makeStore(clock: clock) { _ in .success(snapshot) }

      await store.send(.task)
      await store.receive(.refreshRequested(forced: false)) {
        $0.usage.isFetching = true
      }
      await store.receive(\.usageResponse) {
        $0.usage.isFetching = false
        $0.usage.isInCooldown = true
        $0.usage.lastSnapshot = snapshot
        $0.usage.status = .fresh
      }
      // Tear down the poll loop + cooldown (cancels regardless of @Shared).
      await store.send(.pillEnabledChanged(false)) {
        $0.usage.isInCooldown = false
      }
      await store.finish()
    }
  }

  @Test func taskIsNoOpWhenPillDisabled() async {
    let clock = TestClock()
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      let store = makeStore(pillEnabled: false, clock: clock) { _ in .success(UsageFixtures.snapshot()) }
      await store.send(.task)  // no effects
      await store.finish()
    }
  }

  @Test func advancingLessThanIntervalDoesNotRefetch() async {
    let snapshot = UsageFixtures.snapshot()
    let clock = TestClock()
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      let store = makeStore(clock: clock) { _ in .success(snapshot) }

      await store.send(.task)
      await store.receive(.refreshRequested(forced: false)) { $0.usage.isFetching = true }
      await store.receive(\.usageResponse) {
        $0.usage.isFetching = false
        $0.usage.isInCooldown = true
        $0.usage.lastSnapshot = snapshot
        $0.usage.status = .fresh
      }

      // Under the 180s interval → no poll tick. The 15s cooldown expires en route.
      await clock.advance(by: .seconds(179))
      await store.receive(.cooldownExpired) { $0.usage.isInCooldown = false }

      // Crossing 180s → exactly one new poll tick.
      await clock.advance(by: .seconds(1))
      await store.receive(.refreshRequested(forced: false)) { $0.usage.isFetching = true }
      await store.receive(\.usageResponse) {
        $0.usage.isFetching = false
        $0.usage.isInCooldown = true
      }

      await store.send(.pillEnabledChanged(false)) {
        $0.usage.isInCooldown = false
      }
      await store.finish()
    }
  }

  @Test func failureKeepsLastSnapshot() async {
    let clock = TestClock()
    var initial = UsageFeature.State()
    let good = UsageFixtures.snapshot()
    initial.usage.lastSnapshot = good
    initial.usage.status = .fresh
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      let store = makeStore(initial: initial, clock: clock) { _ in .stale() }

      await store.send(.refreshRequested(forced: true)) { $0.usage.isFetching = true }
      await store.receive(\.usageResponse) {
        $0.usage.isFetching = false
        $0.usage.isInCooldown = true
        $0.usage.status = .stale
        // lastSnapshot intentionally unchanged.
      }
      #expect(store.state.usage.lastSnapshot == good)
      await drainCooldown(store, clock)
    }
  }

  @Test func accountChangeReplacesSnapshot() async {
    let clock = TestClock()
    var initial = UsageFeature.State()
    initial.usage.lastSnapshot = UsageFixtures.snapshot(accountIdentity: "acct-A")
    initial.usage.status = .fresh
    let newSnapshot = UsageFixtures.snapshot(accountIdentity: "acct-B")
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      let store = makeStore(initial: initial, clock: clock) { _ in .success(newSnapshot) }

      await store.send(.refreshRequested(forced: true)) { $0.usage.isFetching = true }
      await store.receive(\.usageResponse) {
        $0.usage.isFetching = false
        $0.usage.isInCooldown = true
        $0.usage.lastSnapshot = newSnapshot
        $0.usage.status = .fresh
      }
      #expect(store.state.usage.lastSnapshot?.accountIdentity == "acct-B")
      await drainCooldown(store, clock)
    }
  }

  @Test func deniedLatchSkipsAutoRefetchButManualRetries() async {
    let clock = TestClock()
    let responses = LockIsolated<[UsageFetchResult]>([
      .credentialsProblem(denied: true),
      .success(UsageFixtures.snapshot()),
    ])
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      let store = makeStore(clock: clock) { _ in
        responses.withValue { $0.count > 1 ? $0.removeFirst() : ($0.first ?? .stale()) }
      }

      // First auto fetch → deny latches.
      await store.send(.refreshRequested(forced: false)) { $0.usage.isFetching = true }
      await store.receive(\.usageResponse) {
        $0.usage.isFetching = false
        $0.usage.isInCooldown = true
        $0.usage.status = .credentialsProblem
        $0.usage.deniedLatched = true
      }

      // Auto fetch while latched → gated, zero network (no usageResponse).
      await store.send(.refreshRequested(forced: false))

      // Manual retry forces past the latch and cooldown.
      await store.send(.manualRetryTapped)
      await store.receive(.refreshRequested(forced: true)) { $0.usage.isFetching = true }
      await store.receive(\.usageResponse) {
        $0.usage.isFetching = false
        $0.usage.isInCooldown = true
        $0.usage.status = .fresh
        $0.usage.lastSnapshot = UsageFixtures.snapshot()
        $0.usage.deniedLatched = false
      }
      await drainCooldown(store, clock)
    }
  }

  @Test func nonForcedRefreshWithinCooldownDedupes() async {
    let clock = TestClock()
    let snapshot = UsageFixtures.snapshot()
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      let store = makeStore(clock: clock) { _ in .success(snapshot) }

      await store.send(.refreshRequested(forced: true)) { $0.usage.isFetching = true }
      await store.receive(\.usageResponse) {
        $0.usage.isFetching = false
        $0.usage.isInCooldown = true
        $0.usage.lastSnapshot = snapshot
        $0.usage.status = .fresh
      }
      // Within the cooldown → deduped (no new fetch).
      await store.send(.refreshRequested(forced: false))
      await drainCooldown(store, clock)
    }
  }

  @Test func toggleOffCancelsLoopAndGatesFetch() async {
    let clock = TestClock()
    let snapshot = UsageFixtures.snapshot()
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      let store = makeStore(clock: clock) { _ in .success(snapshot) }

      await store.send(.task)
      await store.receive(.refreshRequested(forced: false)) { $0.usage.isFetching = true }
      await store.receive(\.usageResponse) {
        $0.usage.isFetching = false
        $0.usage.isInCooldown = true
        $0.usage.lastSnapshot = snapshot
        $0.usage.status = .fresh
      }

      @Shared(.usagePillEnabled) var enabled
      $enabled.withLock { $0 = false }
      await store.send(.pillEnabledChanged(false)) {
        $0.usage.isInCooldown = false
      }
      // Gated: auto refresh does nothing while disabled.
      await store.send(.refreshRequested(forced: false))
      await store.finish()
    }
  }

  @Test func popoverOpenTriggersRefresh() async {
    let clock = TestClock()
    let snapshot = UsageFixtures.snapshot()
    await withDependencies {
      $0.defaultAppStorage = .inMemory
    } operation: {
      let store = makeStore(clock: clock) { _ in .success(snapshot) }

      await store.send(.popoverOpenTapped) {
        $0.isPopoverPresented = true
      }
      await store.receive(.refreshRequested(forced: false)) { $0.usage.isFetching = true }
      await store.receive(\.usageResponse) {
        $0.usage.isFetching = false
        $0.usage.isInCooldown = true
        $0.usage.lastSnapshot = snapshot
        $0.usage.status = .fresh
      }
      await drainCooldown(store, clock)
    }
  }

  /// Advances past the dedupe cooldown and drains the resulting `.cooldownExpired`
  /// so `store.finish()` sees no outstanding effect.
  private func drainCooldown(_ store: TestStoreOf<UsageFeature>, _ clock: TestClock<Duration>) async {
    await clock.advance(by: .seconds(15))
    await store.receive(.cooldownExpired) { $0.usage.isInCooldown = false }
    await store.finish()
  }
}
