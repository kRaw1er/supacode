import SwiftUI

/// System-color + glyph styling for a severity. Never color-only: every level
/// pairs a distinct SF Symbol and a spoken word (AC-A2). Colors are all
/// system-provided (house rule).
nonisolated enum UsageSeverityStyle {
  nonisolated static func tint(_ severity: UsageSeverity) -> Color {
    switch severity {
    case .normal: .green
    case .warning: .orange
    case .error: .red
    }
  }

  /// A severity glyph, or `nil` for normal (no clutter when all is well).
  nonisolated static func glyph(_ severity: UsageSeverity) -> String? {
    switch severity {
    case .normal: nil
    case .warning: "exclamationmark.triangle.fill"
    case .error: "exclamationmark.octagon.fill"
    }
  }

  /// Spoken word for VoiceOver / non-color signalling.
  nonisolated static func word(_ severity: UsageSeverity) -> String {
    switch severity {
    case .normal: "normal"
    case .warning: "warning"
    case .error: "critical"
    }
  }
}

/// What the compact pill should render, resolved purely from `ProviderUsage` so
/// the accent / dimming / skeleton decisions are unit-testable and never folded
/// into a SwiftUI `body` (AC-P3).
nonisolated enum UsagePillContent: Equatable, Sendable {
  /// Before the first successful fetch and with no data — `.redacted` skeleton.
  case skeleton
  /// Real values. `dimmed` when the status is stale / expired (last-good data
  /// shown greyed). `severity` drives the single accent glyph.
  case values(primary: [UsageLimit], severity: UsageSeverity, dimmed: Bool)
  /// A terse status message (glyph + text) for the no-data error states.
  case message(systemImage: String, text: String)

  nonisolated static func resolve(_ usage: ProviderUsage) -> UsagePillContent {
    switch usage.status {
    case .notSignedIn:
      return .message(systemImage: "person.crop.circle.badge.xmark", text: "Sign in")
    case .credentialsProblem:
      return .message(systemImage: "lock.trianglebadge.exclamationmark", text: "Keychain")
    case .neverFetched:
      if let snapshot = usage.lastSnapshot, !snapshot.primaryLimits.isEmpty {
        return .values(primary: snapshot.primaryLimits, severity: snapshot.worstSeverity, dimmed: true)
      }
      return .skeleton
    case .fresh, .stale, .expired:
      if let snapshot = usage.lastSnapshot, !snapshot.primaryLimits.isEmpty {
        return .values(
          primary: snapshot.primaryLimits,
          severity: snapshot.worstSeverity,
          dimmed: usage.status != .fresh
        )
      }
      switch usage.status {
      case .expired:
        return .message(systemImage: "clock.badge.exclamationmark", text: "Expired")
      case .stale:
        return .message(systemImage: "wifi.exclamationmark", text: "Usage")
      default:
        return .skeleton  // `ok` but no limits yet (AC-D6)
      }
    }
  }
}

extension UsageLimit {
  /// Compact unit label for the pill, e.g. "5h" / "wk". Falls back to the full
  /// display name for any other limit so a new primary limit still reads.
  var pillUnitLabel: String {
    switch id {
    case "claude.session": "5h"
    case "claude.weekly": "wk"
    default: displayName
    }
  }

  /// "47%" or "—" when the percent is unknown. Callers apply `.monospacedDigit()`.
  var percentText: String {
    guard let usedPercent else { return "—" }
    return "\(Int(usedPercent.rounded()))%"
  }
}
