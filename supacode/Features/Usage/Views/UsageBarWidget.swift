import SwiftUI

/// Maps a `UsageLimit` to its popover widget. A plain `@ViewBuilder switch`
/// (no `AnyView`, no registry) — a new presentation is one new case, and any
/// limit (including an unknown `kind` mapped to `.bar`) renders for free.
nonisolated enum UsageWidgetResolver {
  /// Pure classification so the switch is unit-testable (AC-V6).
  nonisolated enum WidgetKind: Equatable, Sendable {
    case bar
  }

  nonisolated static func kind(for limit: UsageLimit) -> WidgetKind {
    switch limit.presentation {
    case .bar: .bar
    }
  }

  @ViewBuilder
  static func widget(for limit: UsageLimit, now: Date, reduceMotion: Bool) -> some View {
    switch limit.presentation {
    case .bar:
      UsageBarWidget(limit: limit, now: now, reduceMotion: reduceMotion)
    }
  }
}

/// A labeled progress bar for one limit: name + severity glyph, a
/// `Gauge(.accessoryLinearCapacity)` fill tinted by severity, and a footer with
/// "% left" and the reset countdown. Missing fields are omitted (no NaN / no
/// phantom values).
struct UsageBarWidget: View {
  let limit: UsageLimit
  let now: Date
  let reduceMotion: Bool

  private var fraction: Double? {
    guard let usedPercent = limit.usedPercent else { return nil }
    return (usedPercent / 100).clamped(to: 0...1)
  }

  private var resetText: String? {
    UsageResetFormatter.describe(resetsAt: limit.resetsAt, now: now)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      header
      gauge
      footer
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(accessibilityValue)
  }

  private var header: some View {
    HStack(spacing: 6) {
      Text(verbatim: limit.displayName)
        .font(.callout.weight(.medium))
      if let glyph = UsageSeverityStyle.glyph(limit.severity) {
        Image(systemName: glyph)
          .foregroundStyle(UsageSeverityStyle.tint(limit.severity))
          .font(.caption)
          .accessibilityHidden(true)
      }
      Spacer(minLength: 8)
      Text(verbatim: limit.percentText)
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var gauge: some View {
    if let fraction {
      Gauge(value: fraction) { EmptyView() }
        .gaugeStyle(.accessoryLinearCapacity)
        .tint(UsageSeverityStyle.tint(limit.severity))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: fraction)
    } else {
      // Unknown percent → an inert track so the row still has structure.
      Gauge(value: 0) { EmptyView() }
        .gaugeStyle(.accessoryLinearCapacity)
        .tint(.secondary)
        .opacity(0.4)
    }
  }

  @ViewBuilder
  private var footer: some View {
    HStack(spacing: 8) {
      if let remaining = limit.remainingPercent {
        Text(verbatim: "\(Int(remaining.rounded()))% left")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if let resetText {
        Text(verbatim: resetText)
          .font(.caption.monospacedDigit())
          .foregroundStyle(limit.severity == .error ? UsageSeverityStyle.tint(.error) : .secondary)
      }
    }
  }

  private var accessibilityLabel: Text {
    Text(verbatim: limit.displayName)
  }

  /// e.g. "42% used, warning, resets in 1h 35m". Composed so VoiceOver reads a
  /// single coherent value instead of the decorative bar.
  private var accessibilityValue: Text {
    var parts: [String] = []
    if let usedPercent = limit.usedPercent {
      parts.append("\(Int(usedPercent.rounded()))% used")
    }
    if limit.severity != .normal {
      parts.append(UsageSeverityStyle.word(limit.severity))
    }
    if let resetText {
      parts.append(resetText.replacing("Resets in", with: "resets in"))
    }
    return Text(verbatim: parts.joined(separator: ", "))
  }
}
