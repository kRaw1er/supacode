import ComposableArchitecture
import SwiftUI

/// The compact sidebar-footer pill: Claude glyph, a decorative mini-bar, and
/// "NN% 5h · NN% wk". Renders purely from `UsagePillContent.resolve` so the
/// accent / dimming / skeleton decisions live on State, not in `body` (AC-P3).
/// A `Button` opening the popover; `ViewThatFits` degrades full → compact →
/// icon-only under a narrow sidebar / large Dynamic Type (AC-P5).
struct UsagePillView: View {
  @Bindable var store: StoreOf<UsageFeature>
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var content: UsagePillContent {
    UsagePillContent.resolve(store.usage)
  }

  var body: some View {
    let content = content
    Button {
      store.send(.popoverOpenTapped)
    } label: {
      pillBody(content)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(RoundedRectangle(cornerRadius: 7))
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 8)
    .padding(.bottom, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .popover(isPresented: $store.isPopoverPresented, arrowEdge: .trailing) {
      UsagePopoverView(store: store)
    }
    .help("Claude usage — click for session and weekly details")
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel(content))
    .accessibilityAddTraits(.isButton)
  }

  @ViewBuilder
  private func pillBody(_ content: UsagePillContent) -> some View {
    switch content {
    case .skeleton:
      HStack(spacing: 6) {
        leadingGlyph(systemName: "gauge.with.dots.needle.bottom.50percent", tint: .secondary)
        Text(verbatim: "00% 5h · 00% wk")
          .font(.caption.monospacedDigit())
      }
      .redacted(reason: .placeholder)

    case .values(let primary, let severity, let dimmed):
      ViewThatFits(in: .horizontal) {
        fullValues(primary, severity: severity)
        compactValues(primary, severity: severity)
        iconOnly(severity: severity)
      }
      .opacity(dimmed ? 0.55 : 1)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: dimmed)

    case .message(let systemImage, let text):
      HStack(spacing: 6) {
        leadingGlyph(systemName: systemImage, tint: .secondary)
        Text(verbatim: text)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }

  // MARK: - Value layouts

  private func fullValues(_ primary: [UsageLimit], severity: UsageSeverity) -> some View {
    HStack(spacing: 6) {
      severityOrGaugeGlyph(severity)
      miniBar(fraction: primaryFraction(primary), tint: UsageSeverityStyle.tint(severity))
      Text(verbatim: pillText(primary))
        .font(.caption.monospacedDigit())
        .lineLimit(1)
    }
  }

  private func compactValues(_ primary: [UsageLimit], severity: UsageSeverity) -> some View {
    HStack(spacing: 5) {
      severityOrGaugeGlyph(severity)
      Text(verbatim: pillText(primary))
        .font(.caption2.monospacedDigit())
        .lineLimit(1)
    }
  }

  private func iconOnly(severity: UsageSeverity) -> some View {
    severityOrGaugeGlyph(severity)
  }

  // MARK: - Pieces

  private func leadingGlyph(systemName: String, tint: Color) -> some View {
    Image(systemName: systemName)
      .font(.caption)
      .foregroundStyle(tint)
      .accessibilityHidden(true)
  }

  private func severityOrGaugeGlyph(_ severity: UsageSeverity) -> some View {
    let glyph = UsageSeverityStyle.glyph(severity) ?? "gauge.with.dots.needle.bottom.50percent"
    let tint: Color = severity == .normal ? .secondary : UsageSeverityStyle.tint(severity)
    return leadingGlyph(systemName: glyph, tint: tint)
  }

  private func miniBar(fraction: Double, tint: Color) -> some View {
    ZStack(alignment: .leading) {
      Capsule().fill(.quaternary).frame(width: 26, height: 4)
      Capsule().fill(tint).frame(width: max(0, 26 * fraction), height: 4)
    }
    .accessibilityHidden(true)
  }

  // MARK: - Derivations

  private func primaryFraction(_ primary: [UsageLimit]) -> Double {
    let maxUsed = primary.compactMap(\.usedPercent).max() ?? 0
    return (maxUsed / 100).clamped(to: 0...1)
  }

  /// "47% 5h · 52% wk" from the primary limits, in declaration order.
  private func pillText(_ primary: [UsageLimit]) -> String {
    primary
      .map { "\($0.percentText) \($0.pillUnitLabel)" }
      .joined(separator: " · ")
  }

  private func accessibilityLabel(_ content: UsagePillContent) -> Text {
    switch content {
    case .skeleton:
      return Text(verbatim: "Claude usage, loading")
    case .message(_, let text):
      return Text(verbatim: "Claude usage, \(text)")
    case .values(let primary, _, _):
      let parts = primary.compactMap { limit -> String? in
        guard let used = limit.usedPercent else { return nil }
        return "\(limit.displayName) \(Int(used.rounded()))% used"
      }
      return Text(verbatim: "Claude usage. " + parts.joined(separator: ", "))
    }
  }
}
