import ComposableArchitecture
import Foundation

/// The dependency seam for usage fetching: a `nonisolated` struct of `@Sendable`
/// closures (mirrors `ShellClient`). `fetch(id)` switches on the provider id to
/// a concrete fetcher — no `UsageProvider` protocol until a second conformer
/// exists (YAGNI). Provider *enablement* is reducer / `@Shared` state, not here.
nonisolated struct UsageClient: Sendable {
  var fetch: @Sendable (UsageProviderID) async -> UsageFetchResult
}

extension UsageClient: DependencyKey {
  /// One shared Keychain actor so reads (and their ACL prompt) serialize.
  private nonisolated static let liveKeychain = Keychain()

  static let liveValue = UsageClient(
    fetch: { id in
      switch id {
      case .claude:
        return await ClaudeUsageProvider(
          transport: UsageNetworking.liveTransport,
          keychain: { await liveKeychain.read() }
        )
        .fetch()
      }
    }
  )

  /// Canned success for SwiftUI previews.
  static let previewValue = UsageClient(
    fetch: { _ in .success(UsageClient.previewSnapshot) }
  )

  /// A quiet benign default (NOT `unimplemented`): the app is its own test host,
  /// so `.appLaunched` starts the usage loop during every test run. An
  /// `unimplemented` fetch would then record a spurious issue in unrelated
  /// `AppFeature` tests. `UsageFeatureTests` always override `fetch` explicitly.
  static let testValue = UsageClient(
    fetch: { _ in .stale() }
  )
}

extension UsageClient {
  /// A representative snapshot for previews / canned rendering: Session, Weekly,
  /// and a warning-severity scoped Fable limit.
  nonisolated static var previewSnapshot: UsageSnapshot {
    let now = Date()
    return UsageSnapshot(
      provider: .claude,
      accountIdentity: "preview-account",
      accountLabel: "you@example.com",
      limits: [
        UsageLimit(
          id: "claude.session",
          displayName: "Session",
          usedPercent: 47,
          resetsAt: now.addingTimeInterval(3600 + 35 * 60),
          severity: .normal,
          isPrimary: true
        ),
        UsageLimit(
          id: "claude.weekly",
          displayName: "Weekly",
          usedPercent: 52,
          resetsAt: now.addingTimeInterval(86400 * 4 + 3600 * 10),
          severity: .normal,
          isPrimary: true
        ),
        UsageLimit(
          id: "claude.weekly.fable",
          displayName: "Fable (weekly)",
          usedPercent: 75,
          resetsAt: now.addingTimeInterval(86400 * 4 + 3600 * 10),
          severity: .warning,
          scope: UsageScope(modelDisplayName: "Fable"),
          isPrimary: false
        ),
      ],
      updatedAt: now
    )
  }
}

extension DependencyValues {
  var usageClient: UsageClient {
    get { self[UsageClient.self] }
    set { self[UsageClient.self] = newValue }
  }
}
