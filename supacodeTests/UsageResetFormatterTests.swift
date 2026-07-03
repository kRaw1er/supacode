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
}
