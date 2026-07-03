import ComposableArchitecture
import SwiftUI

/// The click-through popover: header with "Updated Xm ago" + Refresh, a bar per
/// limit via the widget resolver, a status message for error states, and a
/// read-only account row (laid out switcher-ready).
struct UsagePopoverView: View {
  @Bindable var store: StoreOf<UsageFeature>
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var usage: ProviderUsage { store.usage }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      Divider()
      limitsOrMessage
      Divider()
      accountRow
    }
    .padding(14)
    .frame(width: 300)
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: "Claude Usage")
          .font(.headline)
        updatedText
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      refreshButton
    }
  }

  @ViewBuilder
  private var updatedText: some View {
    if let updatedAt = usage.lastSnapshot?.updatedAt {
      // Minute granularity, refreshed once a minute (seconds don't tick).
      TimelineView(.everyMinute) { context in
        Text(verbatim: UsageResetFormatter.describeUpdated(since: updatedAt, now: context.date))
      }
    } else {
      Text(verbatim: "Not yet updated")
    }
  }

  private var refreshButton: some View {
    Button {
      store.send(.manualRetryTapped)
    } label: {
      if usage.isFetching {
        ProgressView().controlSize(.small)
      } else {
        Image(systemName: "arrow.clockwise")
      }
    }
    .buttonStyle(.borderless)
    .disabled(usage.isFetching)
    .help("Refresh usage now")
    .accessibilityLabel("Refresh usage")
  }

  // MARK: - Body

  @ViewBuilder
  private var limitsOrMessage: some View {
    if let snapshot = usage.lastSnapshot, !snapshot.limits.isEmpty {
      TimelineView(.everyMinute) { context in
        VStack(alignment: .leading, spacing: 14) {
          ForEach(snapshot.limits) { limit in
            UsageWidgetResolver.widget(for: limit, now: context.date, reduceMotion: reduceMotion)
          }
        }
      }
      statusBanner
    } else {
      emptyOrErrorMessage
    }
  }

  /// A one-line banner shown ABOVE-the-fold data when the status is degraded but
  /// last-good data is still displayed (stale / expired) — so the popover never
  /// falsely claims signed-out while showing values (AC-V5).
  @ViewBuilder
  private var statusBanner: some View {
    switch usage.status {
    case .stale:
      messageRow(systemImage: "wifi.exclamationmark", text: "Couldn't refresh — showing last known usage.")
    case .expired:
      messageRow(
        systemImage: "clock.badge.exclamationmark",
        text: "Session token expired. Run any `claude` command to refresh."
      )
    case .credentialsProblem:
      messageRow(
        systemImage: "lock.trianglebadge.exclamationmark",
        text: "Couldn't read the Claude credentials from your keychain."
      )
    default:
      EmptyView()
    }
  }

  @ViewBuilder
  private var emptyOrErrorMessage: some View {
    switch usage.status {
    case .neverFetched:
      messageRow(systemImage: "ellipsis", text: "Loading usage…")
        .redacted(reason: .placeholder)
    case .notSignedIn:
      messageRow(
        systemImage: "person.crop.circle.badge.xmark",
        text: "Not signed in. Run `claude` in a terminal to log in."
      )
    case .credentialsProblem:
      messageRow(
        systemImage: "lock.trianglebadge.exclamationmark",
        text: "Couldn't read the Claude credentials from your keychain."
      )
    case .expired:
      messageRow(
        systemImage: "clock.badge.exclamationmark",
        text: "Session token expired. Run any `claude` command to refresh."
      )
    case .stale:
      messageRow(systemImage: "wifi.exclamationmark", text: "Couldn't reach Anthropic. Check your connection.")
    case .fresh:
      messageRow(systemImage: "checkmark.circle", text: "No usage limits reported for this account.")
    }
  }

  private func messageRow(systemImage: String, text: String) -> some View {
    Label {
      Text(verbatim: text)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  // MARK: - Account

  private var accountRow: some View {
    HStack(spacing: 8) {
      Image(systemName: "person.crop.circle")
        .foregroundStyle(.secondary)
      Text(verbatim: accountLabel)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Account: \(accountLabel)")
  }

  private var accountLabel: String {
    if usage.status == .notSignedIn { return "Not signed in" }
    if let label = usage.lastSnapshot?.accountLabel, !label.isEmpty { return label }
    return "Signed in"
  }
}
