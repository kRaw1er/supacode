import Foundation

// All Usage value types are `nonisolated` + `Sendable`. The Usage module builds
// with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without `nonisolated`
// these would be main-actor isolated and any networking / decode that touches
// them would silently hop back to the main thread. Mirrors `ShellClient`.

/// Stable identity of a usage provider. v1 ships a single provider; a second
/// (Codex) is a new case plus a concrete fetcher — see the plan's scoping note.
nonisolated enum UsageProviderID: String, Sendable, Equatable, Codable {
  case claude
}

/// Severity of a single limit, driving glyph + tint. Never color-only (a11y).
nonisolated enum UsageSeverity: Sendable, Equatable, Comparable {
  case normal
  case warning
  case error

  private var rank: Int {
    switch self {
    case .normal: 0
    case .warning: 1
    case .error: 2
    }
  }

  nonisolated static func < (lhs: UsageSeverity, rhs: UsageSeverity) -> Bool {
    lhs.rank < rhs.rank
  }

  /// Maps a server-provided severity string; unknown / missing → derive from
  /// the percentage so a shape change still renders a sensible color.
  nonisolated static func from(serverValue: String?, percent: Double?) -> UsageSeverity {
    switch serverValue?.lowercased() {
    case "normal", "ok", "none": return .normal
    case "warning", "warn", "medium": return .warning
    case "error", "critical", "high", "exhausted": return .error
    default: return forPercent(percent)
    }
  }

  /// Threshold-derived severity used when the server omits an explicit value
  /// (the top-level `five_hour` / `seven_day` fallback carries no severity).
  nonisolated static func forPercent(_ percent: Double?) -> UsageSeverity {
    guard let percent else { return .normal }
    if percent >= 100 { return .error }
    if percent >= 80 { return .warning }
    return .normal
  }
}

/// How a limit should be rendered. Only `.bar` today; the enum exists so the
/// widget resolver is a plain `switch` and a future widget is one new case.
nonisolated enum UsagePresentation: Sendable, Equatable {
  case bar
}

/// Optional scoping of a limit to a specific model / surface (e.g. Fable).
nonisolated struct UsageScope: Sendable, Equatable {
  /// Human display name of the scoped model, e.g. "Fable". Non-secret.
  var modelDisplayName: String?

  nonisolated init(modelDisplayName: String? = nil) {
    self.modelDisplayName = modelDisplayName
  }
}

/// A single self-describing limit. The generic widget renders any `UsageLimit`,
/// so a new Claude limit (or unknown `kind`) appears with zero UI change.
nonisolated struct UsageLimit: Sendable, Equatable, Identifiable {
  /// Stable key, e.g. "claude.session", "claude.weekly", "claude.weekly.fable".
  var id: String
  var displayName: String
  /// 0...100, already clamped; `nil` when the server omitted it (render "—").
  var usedPercent: Double?
  var resetsAt: Date?
  var severity: UsageSeverity
  var scope: UsageScope?
  var presentation: UsagePresentation
  /// Pill-worthy: the compact pill shows only primary limits (Session + Weekly).
  var isPrimary: Bool

  nonisolated init(
    id: String,
    displayName: String,
    usedPercent: Double?,
    resetsAt: Date?,
    severity: UsageSeverity,
    scope: UsageScope? = nil,
    presentation: UsagePresentation = .bar,
    isPrimary: Bool = false
  ) {
    self.id = id
    self.displayName = displayName
    self.usedPercent = usedPercent
    self.resetsAt = resetsAt
    self.severity = severity
    self.scope = scope
    self.presentation = presentation
    self.isPrimary = isPrimary
  }

  /// Percentage still available, clamped to 0...100. `nil` mirrors a missing
  /// `usedPercent` so the UI can omit the "% left" affordance (no phantom 0/100).
  var remainingPercent: Double? {
    guard let usedPercent else { return nil }
    return (100 - usedPercent).clamped(to: 0...100)
  }
}

/// A provider-agnostic snapshot: the last-known-good set of limits for one
/// account. Carries a stable, non-secret `accountIdentity` so an account switch
/// flushes cached limits (no cross-account mixing).
nonisolated struct UsageSnapshot: Sendable, Equatable {
  var provider: UsageProviderID
  /// Stable non-secret identity used ONLY to detect account changes. Never
  /// logged. Not necessarily human-facing — see `accountLabel` for display.
  var accountIdentity: String
  /// Optional human-readable account label for the popover row (e.g. an email).
  /// `nil` when the provider couldn't resolve one; the UI shows a generic label.
  var accountLabel: String?
  var limits: [UsageLimit]
  var updatedAt: Date

  nonisolated init(
    provider: UsageProviderID,
    accountIdentity: String,
    accountLabel: String? = nil,
    limits: [UsageLimit],
    updatedAt: Date
  ) {
    self.provider = provider
    self.accountIdentity = accountIdentity
    self.accountLabel = accountLabel
    self.limits = limits
    self.updatedAt = updatedAt
  }

  /// Limits marked pill-worthy, in declaration order (Session before Weekly).
  var primaryLimits: [UsageLimit] {
    limits.filter(\.isPrimary)
  }

  /// Worst severity across all limits, driving the pill's single accent glyph.
  var worstSeverity: UsageSeverity {
    limits.map(\.severity).max() ?? .normal
  }
}

/// Transient status kept separate from the last-good `UsageSnapshot` so a
/// failure changes status without discarding data. Collapsed to six cases.
nonisolated enum UsageStatus: Sendable, Equatable {
  /// Before the first fetch — pill shows a `.redacted` skeleton, never 0/100.
  case neverFetched
  case fresh
  /// Transient (offline / 429 / 5xx / decode); keep `lastSnapshot`.
  case stale
  /// Token expired and the CLI hasn't rotated it — "run any claude command".
  case expired
  /// No Keychain item at all.
  case notSignedIn
  /// ACL denied or the item is malformed / locked (`deniedLatched` gates re-read).
  case credentialsProblem
}

/// The value returned by `UsageClient.fetch`. Failures are values, never
/// `throws`, so the reducer does a clean exhaustive `switch`.
nonisolated enum UsageFetchResult: Sendable, Equatable {
  case success(UsageSnapshot)
  case notSignedIn
  case expired
  /// Transient failure. The associated debug string is for logs only and is
  /// intentionally excluded from `Equatable` so tests match on the case alone.
  case stale(debug: String? = nil)
  case credentialsProblem(denied: Bool)

  nonisolated static func == (lhs: UsageFetchResult, rhs: UsageFetchResult) -> Bool {
    switch (lhs, rhs) {
    case (.success(let left), .success(let right)): return left == right
    case (.notSignedIn, .notSignedIn): return true
    case (.expired, .expired): return true
    case (.stale, .stale): return true
    case (.credentialsProblem(let left), .credentialsProblem(let right)): return left == right
    default: return false
    }
  }
}

extension Comparable {
  /// Clamps a value into `range`. Used to keep percentages in 0...100 and to
  /// guard against out-of-range server payloads.
  nonisolated func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
