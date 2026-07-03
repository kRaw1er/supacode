import ConcurrencyExtras
import Foundation

@testable import supacode

/// Shared fixtures + fakes for the Usage feature tests. Kept in one place so the
/// mapping, client, reducer, and widget suites all decode the same validated
/// payloads and construct the same canned snapshots. `nonisolated` (the test
/// module defaults to `@MainActor`) so fixtures are usable from the `@Sendable`
/// transport / keychain closures and non-`@MainActor` suites.
nonisolated enum UsageFixtures {
  /// A fixed "now" the reset-formatter and reducer tests anchor to. All fixture
  /// reset instants are expressed relative to this so countdowns are stable.
  static let now = Date(timeIntervalSince1970: 1_751_500_000)  // 2025-07-03 (UTC-ish)

  /// The validated live response (brainstorm Appendix): Session + Weekly primary
  /// plus a scoped Fable weekly limit.
  static let validatedJSON = """
    {
      "five_hour": { "utilization": 47.0, "resets_at": "2026-07-03T14:00:00Z" },
      "seven_day": { "utilization": 52.0, "resets_at": "2026-07-07T23:00:00Z" },
      "limits": [
        {
          "kind": "session", "group": "session", "percent": 47,
          "severity": "normal", "resets_at": "2026-07-03T14:00:00Z"
        },
        {
          "kind": "weekly_all", "group": "weekly", "percent": 52,
          "severity": "normal", "resets_at": "2026-07-07T23:00:00Z"
        },
        {
          "kind": "weekly_scoped", "group": "weekly", "percent": 75,
          "severity": "warning", "resets_at": "2026-07-07T23:00:00Z",
          "scope": { "model": { "display_name": "Fable" } }
        }
      ],
      "spend": { "enabled": false }
    }
    """

  /// Legacy shape with no `limits[]` array — exercises the window fallback.
  static let legacyWindowsJSON = """
    {
      "five_hour": { "utilization": 12.5, "resets_at": "2026-07-03T14:00:00Z" },
      "seven_day": { "utilization": 88.0, "resets_at": "2026-07-07T23:00:00Z" }
    }
    """

  /// A future/unknown `kind` with no scope — must survive as a generic limit.
  static let unknownKindJSON = """
    {
      "limits": [
        {
          "kind": "claude_design", "group": "design", "percent": 33,
          "severity": "normal", "resets_at": "2026-07-03T14:00:00Z"
        }
      ]
    }
    """

  static func decodeDTO(_ json: String) throws -> ClaudeUsageDTO {
    try JSONDecoder().decode(ClaudeUsageDTO.self, from: Data(json.utf8))
  }

  // MARK: - Provider I/O fakes (Phase 2)

  /// Builds a JWT of `header.payload.signature` whose payload carries `sub` /
  /// `exp` claims so `ClaudeUsageProvider.parseCredentials` can resolve identity
  /// and expiry. Signature is a fixed dummy — nothing verifies it.
  static func jwt(sub: String = "acct-1", expEpochSeconds: Double? = nil) -> String {
    var claims: [String: Any] = ["sub": sub]
    if let expEpochSeconds { claims["exp"] = expEpochSeconds }
    // Fixed header base64url of {"alg":"HS256","typ":"JWT"} so the token string
    // is deterministic (dict key ordering from JSONSerialization is not).
    let header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    let payloadData = (try? JSONSerialization.data(withJSONObject: claims)) ?? Data()
    return "\(header).\(base64URL(payloadData)).sig"
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacing("+", with: "-")
      .replacing("/", with: "_")
      .replacing("=", with: "")
  }

  /// The CLI credential-blob JSON containing an access token. `expiresAtMs` is
  /// epoch **milliseconds** (the CLI's own format), controlling the local
  /// expiry pre-empt.
  static func credentialJSON(token: String, expiresAtMs: Double? = nil) -> Data {
    var oauth: [String: Any] = ["accessToken": token]
    if let expiresAtMs { oauth["expiresAt"] = expiresAtMs }
    let object: [String: Any] = ["claudeAiOauth": oauth]
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
  }

  static func httpResponse(status: Int) -> HTTPURLResponse {
    HTTPURLResponse(
      url: UsageNetworking.usageURL,
      statusCode: status,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!
  }

  /// A keychain closure that returns a scripted sequence of outcomes (repeating
  /// the last), plus a thread-safe read counter for asserting re-read behavior.
  struct ScriptedKeychain {
    let read: @Sendable () async -> KeychainReadOutcome
    let readCount: @Sendable () -> Int
  }

  static func scriptedKeychain(_ outcomes: [KeychainReadOutcome]) -> ScriptedKeychain {
    let remaining = LockIsolated(outcomes)
    let count = LockIsolated(0)
    return ScriptedKeychain(
      read: {
        count.withValue { $0 += 1 }
        return remaining.withValue { queue in
          queue.count > 1 ? queue.removeFirst() : (queue.first ?? .notFound)
        }
      },
      readCount: { count.value }
    )
  }

  /// A ready-made good snapshot for reducer / UI tests.
  static func snapshot(
    accountIdentity: String = "acct-1",
    accountLabel: String? = "user@example.com",
    updatedAt: Date = UsageFixtures.now
  ) -> UsageSnapshot {
    UsageSnapshot(
      provider: .claude,
      accountIdentity: accountIdentity,
      accountLabel: accountLabel,
      limits: [
        UsageLimit(
          id: "claude.session",
          displayName: "Session",
          usedPercent: 47,
          resetsAt: updatedAt.addingTimeInterval(3600),
          severity: .normal,
          isPrimary: true
        ),
        UsageLimit(
          id: "claude.weekly",
          displayName: "Weekly",
          usedPercent: 52,
          resetsAt: updatedAt.addingTimeInterval(86400 * 4),
          severity: .normal,
          isPrimary: true
        ),
      ],
      updatedAt: updatedAt
    )
  }
}
