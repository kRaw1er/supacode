import Foundation
import SupacodeSettingsShared

/// Raw decode of `GET /api/oauth/usage`. Field names use explicit snake_case
/// `CodingKeys` (no `.convertFromSnakeCase`) so the mapping is bulletproof
/// against future keys. Everything is optional + lossy: an undocumented shape
/// change degrades to a `.stale` fallback rather than throwing.
nonisolated struct ClaudeUsageDTO: Decodable, Sendable {
  /// A top-level `{ utilization, resets_at }` window (the `five_hour` /
  /// `seven_day` fallback shape the pre-`limits[]` API returned).
  nonisolated struct Window: Decodable, Sendable {
    var utilization: Double?
    var resetsAt: String?

    private enum CodingKeys: String, CodingKey {
      case utilization
      case resetsAt = "resets_at"
    }
  }

  /// One entry of the self-describing `limits[]` array.
  nonisolated struct LimitEntry: Decodable, Sendable {
    var kind: String?
    var group: String?
    var percent: Double?
    var severity: String?
    var resetsAt: String?
    var scope: ClaudeLimitScope?

    private enum CodingKeys: String, CodingKey {
      case kind
      case group
      case percent
      case severity
      case resetsAt = "resets_at"
      case scope
    }
  }

  var fiveHour: Window?
  var sevenDay: Window?
  var limits: [LimitEntry]?
  /// Best-effort account label (undocumented; the popover falls back gracefully).
  var email: String?

  private enum CodingKeys: String, CodingKey {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"
    case limits
    case email
  }

  nonisolated init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    fiveHour = try? container.decodeIfPresent(Window.self, forKey: .fiveHour)
    sevenDay = try? container.decodeIfPresent(Window.self, forKey: .sevenDay)
    // Lossy: one malformed limit entry must not drop the whole array.
    limits = container.decodeLossyArrayIfPresent(forKey: .limits)
    email = try? container.decodeIfPresent(String.self, forKey: .email)
  }
}

/// Scope of a `limits[]` entry (e.g. a per-model weekly limit). Top-level (not
/// nested in `ClaudeUsageDTO.LimitEntry`) to stay within the 2-level nesting rule.
nonisolated struct ClaudeLimitScope: Decodable, Sendable {
  var model: ClaudeLimitScopeModel?
}

nonisolated struct ClaudeLimitScopeModel: Decodable, Sendable {
  var displayName: String?

  private enum CodingKeys: String, CodingKey {
    case displayName = "display_name"
  }
}

/// Pure translation of the Claude usage DTO into the provider-agnostic
/// `[UsageLimit]` model. All classification / clamping / date parsing lives here
/// so it can be unit-tested without any I/O.
nonisolated enum ClaudeUsageMapping {
  /// Prefers the dynamic `limits[]` array; falls back to the legacy
  /// `five_hour` / `seven_day` windows when it is absent or empty. Unknown
  /// `kind`s survive as generic `.bar` limits. Percentages are clamped 0...100
  /// with NaN guarded to `nil`.
  nonisolated static func mapToLimits(_ dto: ClaudeUsageDTO) -> [UsageLimit] {
    if let entries = dto.limits, !entries.isEmpty {
      var seenIDs = Set<String>()
      var mapped: [UsageLimit] = []
      for entry in entries {
        let limit = mapEntry(entry)
        // Dedupe on stable id so two entries that classify identically (e.g. a
        // scoped limit missing its model name) don't render a duplicate bar.
        guard seenIDs.insert(limit.id).inserted else { continue }
        mapped.append(limit)
      }
      if !mapped.isEmpty { return mapped }
    }
    return fallbackLimits(from: dto)
  }

  /// Session + Weekly from the legacy top-level windows. Used when `limits[]`
  /// is absent so the pill still has its two primary bars.
  nonisolated private static func fallbackLimits(from dto: ClaudeUsageDTO) -> [UsageLimit] {
    var limits: [UsageLimit] = []
    if let session = dto.fiveHour {
      let percent = sanitizedPercent(session.utilization)
      limits.append(
        UsageLimit(
          id: "claude.session",
          displayName: "Session",
          usedPercent: percent,
          resetsAt: parseDate(session.resetsAt),
          severity: .forPercent(percent),
          isPrimary: true
        )
      )
    }
    if let weekly = dto.sevenDay {
      let percent = sanitizedPercent(weekly.utilization)
      limits.append(
        UsageLimit(
          id: "claude.weekly",
          displayName: "Weekly",
          usedPercent: percent,
          resetsAt: parseDate(weekly.resetsAt),
          severity: .forPercent(percent),
          isPrimary: true
        )
      )
    }
    return limits
  }

  nonisolated private static func mapEntry(_ entry: ClaudeUsageDTO.LimitEntry) -> UsageLimit {
    let percent = sanitizedPercent(entry.percent)
    let severity = UsageSeverity.from(serverValue: entry.severity, percent: percent)
    let resetsAt = parseDate(entry.resetsAt)
    let modelName = entry.scope?.model?.displayName?.trimmed
    let classification = classify(kind: entry.kind, group: entry.group, modelName: modelName)
    return UsageLimit(
      id: classification.id,
      displayName: classification.displayName,
      usedPercent: percent,
      resetsAt: resetsAt,
      severity: severity,
      scope: modelName.map { UsageScope(modelDisplayName: $0) },
      presentation: .bar,
      isPrimary: classification.isPrimary
    )
  }

  private struct Classification {
    let id: String
    let displayName: String
    let isPrimary: Bool
  }

  /// Maps `(kind, group, model)` to a stable id + label. Session and weekly-all
  /// are the two primary (pill-worthy) limits; scoped and unknown kinds render
  /// in the popover only.
  nonisolated private static func classify(
    kind: String?,
    group: String?,
    modelName: String?
  ) -> Classification {
    let normalized = kind?.lowercased().trimmed

    switch normalized {
    case "session", "five_hour", "5h", "fivehour":
      return Classification(id: "claude.session", displayName: "Session", isPrimary: true)
    case "weekly_all", "seven_day", "weekly", "sevenday":
      // A bare "weekly" with a model scope is really a scoped limit.
      if let modelName {
        return scopedClassification(modelName: modelName)
      }
      return Classification(id: "claude.weekly", displayName: "Weekly", isPrimary: true)
    case "weekly_scoped", "scoped":
      if let modelName {
        return scopedClassification(modelName: modelName)
      }
      // Scoped but no model name — keep it distinct via a generic id.
      return genericClassification(rawKind: normalized ?? group ?? "limit")
    default:
      if let modelName {
        return scopedClassification(modelName: modelName)
      }
      return genericClassification(rawKind: normalized ?? group ?? "limit")
    }
  }

  nonisolated private static func scopedClassification(modelName: String) -> Classification {
    Classification(
      id: "claude.weekly.\(slug(modelName))",
      displayName: "\(modelName) (weekly)",
      isPrimary: false
    )
  }

  nonisolated private static func genericClassification(rawKind: String) -> Classification {
    Classification(
      id: "claude.\(slug(rawKind))",
      displayName: humanize(rawKind),
      isPrimary: false
    )
  }

  // MARK: - Value helpers

  /// Clamps a percentage to 0...100, mapping NaN / infinite to `nil` so the UI
  /// never renders a phantom bar or divides by a garbage value.
  nonisolated static func sanitizedPercent(_ value: Double?) -> Double? {
    guard let value, value.isFinite else { return nil }
    return value.clamped(to: 0...100)
  }

  /// Parses an ISO-8601 instant, tolerating both fractional-second and plain
  /// forms the API may emit. Returns `nil` for missing / unparseable strings.
  /// Formatters are constructed locally (`ISO8601DateFormatter` is not
  /// `Sendable`, so it can't be a `nonisolated static let`); parse volume is a
  /// handful of dates per fetch, so the cost is negligible.
  nonisolated static func parseDate(_ string: String?) -> Date? {
    guard let string, !string.isEmpty else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: string) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: string)
  }

  /// Lowercased, alphanumerics-only id fragment (e.g. "Fable" → "fable",
  /// "Claude Design" → "claudedesign") so ids stay stable and URL-safe.
  nonisolated private static func slug(_ value: String) -> String {
    let filtered = value.lowercased().unicodeScalars.filter {
      CharacterSet.alphanumerics.contains($0)
    }
    let result = String(String.UnicodeScalarView(filtered))
    return result.isEmpty ? "limit" : result
  }

  /// Turns a raw kind ("weekly_scoped", "claude_design") into a Title Case label.
  nonisolated private static func humanize(_ value: String) -> String {
    let words = value.replacing("_", with: " ").split(separator: " ")
    let titled = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    let joined = titled.joined(separator: " ")
    return joined.isEmpty ? "Limit" : joined
  }
}

extension String {
  /// Whitespace-trimmed value, or `nil` if empty after trimming. Kept file-local
  /// to the Usage mapping so it doesn't collide with app-wide String helpers.
  nonisolated fileprivate var trimmed: String? {
    let result = trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? nil : result
  }
}
