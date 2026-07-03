import Foundation
import Testing

@testable import supacode

struct UsageResetFormatterTests {
  private let now = UsageFixtures.now

  @Test func nilResetInstantReturnsNil() {
    #expect(UsageResetFormatter.describe(resetsAt: nil, now: now) == nil)
  }

  @Test func hoursAndMinutes() {
    let resetsAt = now.addingTimeInterval(3600 + 35 * 60)  // 1h 35m
    #expect(UsageResetFormatter.describe(resetsAt: resetsAt, now: now) == "Resets in 1h 35m")
  }

  @Test func daysAndHours() {
    let resetsAt = now.addingTimeInterval(86400 * 4 + 3600 * 10)  // 4d 10h
    #expect(UsageResetFormatter.describe(resetsAt: resetsAt, now: now) == "Resets in 4d 10h")
  }

  @Test func minutesOnly() {
    let resetsAt = now.addingTimeInterval(20 * 60)  // 20m
    #expect(UsageResetFormatter.describe(resetsAt: resetsAt, now: now) == "Resets in 20m")
  }

  @Test func underOneMinuteButPositive() {
    let resetsAt = now.addingTimeInterval(30)
    #expect(UsageResetFormatter.describe(resetsAt: resetsAt, now: now) == "Resets in <1m")
  }

  @Test func negativeIntervalIsResetting() {
    let resetsAt = now.addingTimeInterval(-120)
    #expect(UsageResetFormatter.describe(resetsAt: resetsAt, now: now) == "Resetting…")
  }

  @Test func exactlyNowIsResetting() {
    #expect(UsageResetFormatter.describe(resetsAt: now, now: now) == "Resetting…")
  }

  // MARK: - "Updated X ago" (minute granularity, no seconds)

  @Test func updatedUnderAMinuteReadsLessThanAMinute() {
    for secondsAgo in [0.0, 5, 30, 59] {
      let updatedAt = now.addingTimeInterval(-secondsAgo)
      #expect(UsageResetFormatter.describeUpdated(since: updatedAt, now: now) == "Updated less than a minute ago")
    }
  }

  @Test func updatedFutureInstantReadsLessThanAMinute() {
    let updatedAt = now.addingTimeInterval(120)  // clock skew guard
    #expect(UsageResetFormatter.describeUpdated(since: updatedAt, now: now) == "Updated less than a minute ago")
  }

  @Test func updatedMinutesArePluralizedAndSingular() {
    #expect(
      UsageResetFormatter.describeUpdated(since: now.addingTimeInterval(-60), now: now)
        == "Updated 1 minute ago"
    )
    #expect(
      UsageResetFormatter.describeUpdated(since: now.addingTimeInterval(-5 * 60), now: now)
        == "Updated 5 minutes ago"
    )
  }

  @Test func updatedHoursAndDays() {
    #expect(
      UsageResetFormatter.describeUpdated(since: now.addingTimeInterval(-3600), now: now)
        == "Updated 1 hour ago"
    )
    #expect(
      UsageResetFormatter.describeUpdated(since: now.addingTimeInterval(-2 * 3600), now: now)
        == "Updated 2 hours ago"
    )
    #expect(
      UsageResetFormatter.describeUpdated(since: now.addingTimeInterval(-86400), now: now)
        == "Updated 1 day ago"
    )
    #expect(
      UsageResetFormatter.describeUpdated(since: now.addingTimeInterval(-3 * 86400), now: now)
        == "Updated 3 days ago"
    )
  }
}
