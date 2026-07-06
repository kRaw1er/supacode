import Foundation
import Testing

@testable import supacode

struct UsageWidgetResolverTests {
  @Test func knownLimitResolvesToBarWidget() {
    let limit = UsageLimit(
      id: "claude.session", displayName: "Session", usedPercent: 47,
      resetsAt: nil, severity: .normal, isPrimary: true
    )
    #expect(UsageWidgetResolver.kind(for: limit) == .bar)
  }

  @Test func unknownKindLimitStillResolvesToBar() throws {
    // AC-V6: a synthetic unknown limit renders via the default widget.
    let dto = try UsageFixtures.decodeDTO(UsageFixtures.unknownKindJSON)
    let limit = try #require(ClaudeUsageMapping.mapToLimits(dto).first)
    #expect(limit.presentation == .bar)
    #expect(UsageWidgetResolver.kind(for: limit) == .bar)
  }
}

struct UsagePillContentTests {
  @Test func neverFetchedWithNoDataIsSkeleton() {
    var usage = ProviderUsage()
    usage.status = .neverFetched
    #expect(UsagePillContent.resolve(usage) == .skeleton)
  }

  @Test func okWithDataShowsValuesUndimmed() {
    var usage = ProviderUsage()
    usage.status = .fresh
    usage.lastSnapshot = UsageFixtures.snapshot()
    guard case .values(let primary, _, let dimmed) = UsagePillContent.resolve(usage) else {
      Issue.record("Expected values")
      return
    }
    #expect(primary.map(\.id) == ["claude.session", "claude.weekly"])
    #expect(!dimmed)
  }

  @Test func staleWithPriorDataKeepsValuesDimmed() {
    var usage = ProviderUsage()
    usage.status = .stale
    usage.lastSnapshot = UsageFixtures.snapshot()
    guard case .values(_, _, let dimmed) = UsagePillContent.resolve(usage) else {
      Issue.record("Expected values")
      return
    }
    #expect(dimmed)
  }

  @Test func notSignedInIsMessageEvenWithStaleSnapshot() {
    var usage = ProviderUsage()
    usage.status = .notSignedIn
    usage.lastSnapshot = UsageFixtures.snapshot()  // stale data present
    guard case .message = UsagePillContent.resolve(usage) else {
      Issue.record("Expected message (never falsely show values when signed out)")
      return
    }
  }

  @Test func credentialsProblemIsMessage() {
    var usage = ProviderUsage()
    usage.status = .credentialsProblem
    guard case .message = UsagePillContent.resolve(usage) else {
      Issue.record("Expected message")
      return
    }
  }

  @Test func expiredWithoutDataIsMessage() {
    var usage = ProviderUsage()
    usage.status = .expired
    guard case .message = UsagePillContent.resolve(usage) else {
      Issue.record("Expected message")
      return
    }
  }

  @Test func worstSeverityDrivesAccent() {
    var usage = ProviderUsage()
    usage.status = .fresh
    var snapshot = UsageFixtures.snapshot()
    snapshot.limits.append(
      UsageLimit(
        id: "claude.weekly.fable", displayName: "Fable (weekly)", usedPercent: 95,
        resetsAt: nil, severity: .error, isPrimary: false
      )
    )
    usage.lastSnapshot = snapshot
    guard case .values(_, let severity, _) = UsagePillContent.resolve(usage) else {
      Issue.record("Expected values")
      return
    }
    #expect(severity == .error)
  }

  @Test func pillUnitLabels() {
    let session = UsageLimit(
      id: "claude.session", displayName: "Session", usedPercent: 47,
      resetsAt: nil, severity: .normal
    )
    let weekly = UsageLimit(
      id: "claude.weekly", displayName: "Weekly", usedPercent: 52,
      resetsAt: nil, severity: .normal
    )
    #expect(session.pillUnitLabel == "5h")
    #expect(weekly.pillUnitLabel == "wk")
    #expect(session.percentText == "47%")
  }
}
