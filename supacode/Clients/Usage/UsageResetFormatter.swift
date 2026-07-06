import Foundation

/// Formats a limit's reset instant into a compact relative countdown, e.g.
/// "Resets in 1h 35m" / "Resets in 4d 10h". `nonisolated` + pure so it can run
/// off the main actor and be unit-tested against a fixed `now`.
nonisolated enum UsageResetFormatter {
  /// Returns a countdown string, or `nil` when there is no reset instant.
  /// A non-positive interval renders "Resetting…" (the window has elapsed but
  /// the server hasn't reported the new one yet).
  nonisolated static func describe(resetsAt: Date?, now: Date) -> String? {
    guard let resetsAt else { return nil }
    let seconds = resetsAt.timeIntervalSince(now)
    guard seconds > 0 else { return "Resetting…" }

    let totalMinutes = Int(seconds / 60)
    let days = totalMinutes / (60 * 24)
    let hours = (totalMinutes % (60 * 24)) / 60
    let minutes = totalMinutes % 60

    if days >= 1 {
      return "Resets in \(days)d \(hours)h"
    }
    if hours >= 1 {
      return "Resets in \(hours)h \(minutes)m"
    }
    if minutes >= 1 {
      return "Resets in \(minutes)m"
    }
    // Under a minute but still positive — avoid "Resets in 0m".
    return "Resets in <1m"
  }

  /// "Updated X ago" for the popover header, at MINUTE granularity — seconds are
  /// never shown because the label doesn't tick per-second (it refreshes on a
  /// per-minute `TimelineView`). Anything under a minute reads "less than a
  /// minute ago"; otherwise the single largest unit (minutes / hours / days).
  nonisolated static func describeUpdated(since updatedAt: Date, now: Date) -> String {
    let seconds = now.timeIntervalSince(updatedAt)
    guard seconds >= 60 else { return "Updated less than a minute ago" }

    let totalMinutes = Int(seconds / 60)
    let days = totalMinutes / (60 * 24)
    let hours = (totalMinutes % (60 * 24)) / 60
    let minutes = totalMinutes % 60

    if days >= 1 { return "Updated \(days) \(Self.unit(days, "day")) ago" }
    if hours >= 1 { return "Updated \(hours) \(Self.unit(hours, "hour")) ago" }
    return "Updated \(minutes) \(Self.unit(minutes, "minute")) ago"
  }

  nonisolated private static func unit(_ count: Int, _ singular: String) -> String {
    count == 1 ? singular : "\(singular)s"
  }
}
