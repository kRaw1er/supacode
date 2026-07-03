import Foundation
import Testing

@testable import supacode

struct UsageLimitMappingTests {
  @Test func validatedPayloadMapsSessionWeeklyAndScopedFable() throws {
    let dto = try UsageFixtures.decodeDTO(UsageFixtures.validatedJSON)
    let limits = ClaudeUsageMapping.mapToLimits(dto)

    #expect(limits.count == 3)

    let session = try #require(limits.first { $0.id == "claude.session" })
    #expect(session.displayName == "Session")
    #expect(session.usedPercent == 47)
    #expect(session.isPrimary)
    #expect(session.severity == .normal)

    let weekly = try #require(limits.first { $0.id == "claude.weekly" })
    #expect(weekly.displayName == "Weekly")
    #expect(weekly.usedPercent == 52)
    #expect(weekly.isPrimary)

    let fable = try #require(limits.first { $0.id == "claude.weekly.fable" })
    #expect(fable.displayName == "Fable (weekly)")
    #expect(fable.usedPercent == 75)
    #expect(!fable.isPrimary)
    #expect(fable.severity == .warning)
    #expect(fable.scope?.modelDisplayName == "Fable")
  }

  @Test func primaryLimitsAreSessionAndWeeklyInOrder() throws {
    let dto = try UsageFixtures.decodeDTO(UsageFixtures.validatedJSON)
    let snapshot = UsageSnapshot(
      provider: .claude,
      accountIdentity: "acct",
      limits: ClaudeUsageMapping.mapToLimits(dto),
      updatedAt: UsageFixtures.now
    )
    #expect(snapshot.primaryLimits.map(\.id) == ["claude.session", "claude.weekly"])
    #expect(snapshot.worstSeverity == .warning)
  }

  @Test func fallsBackToLegacyWindowsWhenLimitsAbsent() throws {
    let dto = try UsageFixtures.decodeDTO(UsageFixtures.legacyWindowsJSON)
    let limits = ClaudeUsageMapping.mapToLimits(dto)

    #expect(limits.map(\.id) == ["claude.session", "claude.weekly"])
    #expect(limits.first?.usedPercent == 12.5)
    // 88% weekly → derived warning severity (no server severity in this shape).
    let weekly = try #require(limits.first { $0.id == "claude.weekly" })
    #expect(weekly.usedPercent == 88)
    #expect(weekly.severity == .warning)
    #expect(weekly.isPrimary)
  }

  @Test func unknownKindSurvivesAsGenericBarLimit() throws {
    let dto = try UsageFixtures.decodeDTO(UsageFixtures.unknownKindJSON)
    let limits = ClaudeUsageMapping.mapToLimits(dto)

    let generic = try #require(limits.first)
    #expect(generic.id == "claude.claudedesign")
    #expect(generic.displayName == "Claude Design")
    #expect(generic.presentation == .bar)
    #expect(!generic.isPrimary)
    #expect(generic.usedPercent == 33)
  }

  @Test func emptyLimitsAndNoWindowsYieldsNoLimits() throws {
    let dto = try UsageFixtures.decodeDTO(#"{ "limits": [] }"#)
    #expect(ClaudeUsageMapping.mapToLimits(dto).isEmpty)
  }

  @Test func malformedElementIsDroppedWithoutFailingTheArray() throws {
    // The second element is malformed (percent is a string); lossy decode keeps
    // the first and drops the bad one rather than throwing.
    let json = #"""
      {
        "limits": [
          { "kind": "session", "percent": 10, "severity": "normal" },
          { "kind": "weekly_all", "percent": "oops" }
        ]
      }
      """#
    let dto = try UsageFixtures.decodeDTO(json)
    let limits = ClaudeUsageMapping.mapToLimits(dto)
    #expect(limits.map(\.id) == ["claude.session"])
  }

  @Test func percentIsClampedAndNaNGuarded() throws {
    let json = #"""
      {
        "limits": [
          { "kind": "session", "percent": 250, "severity": "error" },
          { "kind": "weekly_all", "percent": null }
        ]
      }
      """#
    let dto = try UsageFixtures.decodeDTO(json)
    let limits = ClaudeUsageMapping.mapToLimits(dto)

    let session = try #require(limits.first { $0.id == "claude.session" })
    #expect(session.usedPercent == 100)  // clamped from 250
    #expect(session.remainingPercent == 0)

    let weekly = try #require(limits.first { $0.id == "claude.weekly" })
    #expect(weekly.usedPercent == nil)  // missing → nil, not 0
    #expect(weekly.remainingPercent == nil)
  }

  @Test(arguments: [
    ("normal", 10.0, UsageSeverity.normal),
    ("warning", 10.0, UsageSeverity.warning),
    ("error", 10.0, UsageSeverity.error),
    ("critical", 10.0, UsageSeverity.error),
    ("totally-unknown", 85.0, UsageSeverity.warning),  // derived from percent
    ("totally-unknown", 100.0, UsageSeverity.error),
    ("totally-unknown", 5.0, UsageSeverity.normal),
  ])
  func severityMapping(serverValue: String, percent: Double, expected: UsageSeverity) {
    #expect(UsageSeverity.from(serverValue: serverValue, percent: percent) == expected)
  }

  @Test func missingResetsAtDoesNotCrash() throws {
    let json = #"{ "limits": [ { "kind": "session", "percent": 10, "severity": "normal" } ] }"#
    let dto = try UsageFixtures.decodeDTO(json)
    let limits = ClaudeUsageMapping.mapToLimits(dto)
    #expect(limits.first?.resetsAt == nil)
  }

  @Test func fractionalSecondsResetInstantParses() throws {
    let json = #"""
      { "limits": [ { "kind": "session", "percent": 10, "resets_at": "2026-07-03T14:00:00.500Z" } ] }
      """#
    let dto = try UsageFixtures.decodeDTO(json)
    #expect(ClaudeUsageMapping.mapToLimits(dto).first?.resetsAt != nil)
  }
}
