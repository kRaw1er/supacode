import Foundation
import SupacodeSettingsShared

private nonisolated let usageLogger = SupaLogger("Usage")

/// Fetches Claude usage: read the CLI's OAuth token from the Keychain, GET the
/// undocumented usage endpoint, map the response. READ-ONLY — never writes the
/// Keychain, never mints tokens; the CLI owns rotation (Orca's usage-path
/// behavior). Failures are returned as `UsageFetchResult`, never thrown.
///
/// Both I/O seams are injectable so tests drive it with closures (no
/// `URLProtocol`, no real Keychain):
/// - `transport`: performs one HTTP request → `(Data, HTTPURLResponse)`.
/// - `keychain`: performs one credential read → `KeychainReadOutcome`.
nonisolated struct ClaudeUsageProvider: Sendable {
  var transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
  var keychain: @Sendable () async -> KeychainReadOutcome
  var now: @Sendable () -> Date

  /// Reject any response body larger than this — the real payload is a few KB,
  /// so anything larger is a misdirected/hostile response we won't decode.
  static let maxBodySize = 256 * 1024

  init(
    transport: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse),
    keychain: @escaping @Sendable () async -> KeychainReadOutcome,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.transport = transport
    self.keychain = keychain
    self.now = now
  }

  func fetch() async -> UsageFetchResult {
    switch await readCredentials() {
    case .failure(let result):
      return result
    case .success(var credentials):
      // Pre-empt a doomed GET: if the token already expired locally, re-read
      // once (a live `claude` session may have just rotated it).
      if let expiresAt = credentials.expiresAt, expiresAt <= now() {
        switch await readCredentials() {
        case .failure(let result):
          return result
        case .success(let fresh):
          if let freshExp = fresh.expiresAt, freshExp <= now() {
            return .expired  // CLI hasn't rotated yet
          }
          credentials = fresh
        }
      }
      return await performGET(credentials: credentials, allowReReadOn401: true)
    }
  }

  // MARK: - Credential read + parse

  private enum CredentialReadResult {
    case success(Credentials)
    case failure(UsageFetchResult)
  }

  private struct Credentials: Sendable {
    let token: String
    let accountIdentity: String
    let expiresAt: Date?
  }

  private func readCredentials() async -> CredentialReadResult {
    switch await keychain() {
    case .notFound:
      return .failure(.notSignedIn)
    case .denied:
      return .failure(.credentialsProblem(denied: true))
    case .interactionNotAllowed:
      return .failure(.credentialsProblem(denied: false))
    case .failure(let status):
      usageLogger.warning("Keychain read failed (OSStatus \(status)).")
      return .failure(.credentialsProblem(denied: false))
    case .data(let data):
      guard let parsed = Self.parseCredentials(data) else {
        usageLogger.warning("Keychain item present but credential JSON was malformed.")
        return .failure(.credentialsProblem(denied: false))
      }
      guard Self.isValidTokenCharset(parsed.token) else {
        usageLogger.warning("Access token failed charset validation; treating as corrupt item.")
        return .failure(.credentialsProblem(denied: false))
      }
      return .success(parsed)
    }
  }

  /// Parses the CLI credential blob `{ "claudeAiOauth": { accessToken, expiresAt } }`.
  /// `expiresAt` is epoch **milliseconds** in the CLI's format; we also fall
  /// back to the JWT `exp` claim. `accountIdentity` comes from the JWT `sub`
  /// (stable across rotations) so an account switch flushes cached limits.
  private nonisolated static func parseCredentials(_ data: Data) -> Credentials? {
    struct CredentialFile: Decodable {
      struct OAuth: Decodable {
        var accessToken: String?
        var expiresAt: Double?
      }
      var claudeAiOauth: OAuth?
    }
    guard
      let file = try? JSONDecoder().decode(CredentialFile.self, from: data),
      let token = file.claudeAiOauth?.accessToken,
      !token.isEmpty
    else { return nil }

    let claims = decodeJWTClaims(token)
    let subject = (claims?["sub"] as? String) ?? "claude-account"

    // Prefer the CLI's own expiry (ms epoch); fall back to the JWT `exp` (sec).
    let expiresAt: Date?
    if let milliseconds = file.claudeAiOauth?.expiresAt {
      expiresAt = Date(timeIntervalSince1970: milliseconds / 1000)
    } else if let exp = claims?["exp"] as? Double {
      expiresAt = Date(timeIntervalSince1970: exp)
    } else {
      expiresAt = nil
    }

    return Credentials(token: token, accountIdentity: subject, expiresAt: expiresAt)
  }

  /// Header-injection guard: the token becomes an `Authorization` header value,
  /// so a corrupt item carrying control chars must be rejected, not sent.
  nonisolated static func isValidTokenCharset(_ token: String) -> Bool {
    let allowed = CharacterSet(charactersIn: "._~+/=-").union(.alphanumerics)
    return token.unicodeScalars.allSatisfy { allowed.contains($0) }
  }

  /// Decodes a JWT's payload segment into a claims dictionary. Best-effort:
  /// returns `nil` on any structural problem (we never depend on it for
  /// correctness, only for `sub` / `exp` hints).
  nonisolated static func decodeJWTClaims(_ token: String) -> [String: Any]? {
    let segments = token.split(separator: ".")
    guard segments.count >= 2 else { return nil }
    var base64 = String(segments[1])
      .replacing("-", with: "+")
      .replacing("_", with: "/")
    // Pad to a multiple of 4 for base64 decoding.
    while base64.count % 4 != 0 { base64.append("=") }
    guard
      let data = Data(base64Encoded: base64),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return json
  }

  // MARK: - HTTP

  private func performGET(
    credentials: Credentials,
    allowReReadOn401: Bool
  ) async -> UsageFetchResult {
    let request = UsageNetworking.makeRequest(token: credentials.token)
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport(request)
    } catch {
      // Offline / timeout / transport error → transient; keep last snapshot.
      return .stale(debug: "transport: \(type(of: error))")
    }

    switch response.statusCode {
    case 200:
      guard data.count <= Self.maxBodySize else {
        return .stale(debug: "oversize \(data.count)")
      }
      guard let dto = try? JSONDecoder().decode(ClaudeUsageDTO.self, from: data) else {
        return .stale(debug: "decode")
      }
      let snapshot = UsageSnapshot(
        provider: .claude,
        accountIdentity: credentials.accountIdentity,
        accountLabel: dto.email,
        limits: ClaudeUsageMapping.mapToLimits(dto),
        updatedAt: now()
      )
      return .success(snapshot)

    case 401:
      guard allowReReadOn401 else { return .expired }
      // The CLI may have rotated the token since our read — re-read once and
      // retry with a *different* token; a same-token 401 means truly expired.
      switch await readCredentials() {
      case .failure(let result):
        return result
      case .success(let fresh):
        guard fresh.token != credentials.token else { return .expired }
        return await performGET(credentials: fresh, allowReReadOn401: false)
      }

    default:
      // 429 / 403 / 5xx → transient; keep last snapshot.
      return .stale(debug: "http \(response.statusCode)")
    }
  }
}

/// Endpoint, headers, and the ephemeral session for the usage GET. All the
/// undocumented / CLI-impersonation surface (endpoint, spoofed UA, beta header,
/// first-party assumptions) is isolated here so a ToS/shape change is a
/// one-file edit (Risk-2).
nonisolated enum UsageNetworking {
  static let host = "api.anthropic.com"
  static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
  static let userAgent = "claude-code/2.1.0"
  static let betaHeaderValue = "oauth-2025-04-20"

  nonisolated static func makeRequest(token: String) -> URLRequest {
    var request = URLRequest(url: usageURL)
    request.httpMethod = "GET"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(betaHeaderValue, forHTTPHeaderField: "anthropic-beta")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.cachePolicy = .reloadIgnoringLocalCacheData
    return request
  }

  /// Ephemeral session (no on-disk cache — the response may carry an email),
  /// short timeout, cross-host redirects refused.
  nonisolated static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.timeoutIntervalForRequest = 20
    config.httpShouldSetCookies = false
    return URLSession(
      configuration: config,
      delegate: RedirectRefusingDelegate(),
      delegateQueue: nil
    )
  }()

  nonisolated static func liveTransport(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    return (data, http)
  }

  /// A redirect may be followed only when it stays on the expected host.
  nonisolated static func allowsRedirect(toHost host: String?) -> Bool {
    host == self.host
  }
}

/// Refuses any redirect that leaves the expected host so a compromised /
/// misconfigured endpoint can't bounce the bearer token to another origin.
private nonisolated final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    if UsageNetworking.allowsRedirect(toHost: request.url?.host) {
      completionHandler(request)
    } else {
      completionHandler(nil)  // stop the redirect; the 3xx surfaces as `.stale`
    }
  }
}
