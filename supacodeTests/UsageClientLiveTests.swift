import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

struct UsageClientLiveTests {
  private let fixedNow = UsageFixtures.now

  /// Builds a provider with a scripted keychain + a transport that records the
  /// request and replays a scripted sequence of `(Data, status)` responses.
  private func makeProvider(
    keychain: [KeychainReadOutcome],
    responses: [(Data, Int)],
    transportThrows: Bool = false,
    recordedRequests: LockIsolated<[URLRequest]> = LockIsolated([]),
    keychainReadCount: LockIsolated<Int> = LockIsolated(0)
  ) -> ClaudeUsageProvider {
    let scripted = UsageFixtures.scriptedKeychain(keychain)
    let remainingResponses = LockIsolated(responses)
    return ClaudeUsageProvider(
      transport: { request in
        recordedRequests.withValue { $0.append(request) }
        if transportThrows { throw URLError(.notConnectedToInternet) }
        let (data, status) = remainingResponses.withValue { queue -> (Data, Int) in
          queue.count > 1 ? queue.removeFirst() : (queue.first ?? (Data(), 500))
        }
        return (data, UsageFixtures.httpResponse(status: status))
      },
      keychain: {
        keychainReadCount.withValue { $0 += 1 }
        return await scripted.read()
      },
      now: { self.fixedNow }
    )
  }

  private var validBody: Data { Data(UsageFixtures.validatedJSON.utf8) }
  private func futureToken() -> String { UsageFixtures.jwt(sub: "acct-1") }

  /// Epoch milliseconds `offset` seconds from the fixed test now.
  private func epochMs(offset: TimeInterval) -> Double {
    fixedNow.addingTimeInterval(offset).timeIntervalSince1970 * 1000
  }

  private func futureCredential() -> KeychainReadOutcome {
    .data(UsageFixtures.credentialJSON(token: futureToken(), expiresAtMs: epochMs(offset: 3600)))
  }

  @Test func success200MapsSnapshotAndSendsCorrectHeaders() async {
    let requests = LockIsolated<[URLRequest]>([])
    let provider = makeProvider(
      keychain: [futureCredential()],
      responses: [(validBody, 200)],
      recordedRequests: requests
    )

    let result = await provider.fetch()

    guard case .success(let snapshot) = result else {
      Issue.record("Expected success, got \(result)")
      return
    }
    #expect(snapshot.accountIdentity == "acct-1")
    #expect(snapshot.primaryLimits.map(\.id) == ["claude.session", "claude.weekly"])
    #expect(snapshot.updatedAt == fixedNow)

    let request = requests.value.first
    #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer \(futureToken())")
    #expect(request?.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    #expect(request?.value(forHTTPHeaderField: "User-Agent") == "claude-code/2.1.0")
    #expect(request?.url == UsageNetworking.usageURL)
  }

  @Test func notSignedInWhenKeychainItemMissing() async {
    let provider = makeProvider(keychain: [.notFound], responses: [(Data(), 200)])
    #expect(await provider.fetch() == .notSignedIn)
  }

  @Test func deniedLatchesAsCredentialsProblem() async {
    let provider = makeProvider(keychain: [.denied], responses: [(Data(), 200)])
    #expect(await provider.fetch() == .credentialsProblem(denied: true))
  }

  @Test func interactionNotAllowedIsNonLatchingCredentialsProblem() async {
    let provider = makeProvider(keychain: [.interactionNotAllowed], responses: [(Data(), 200)])
    #expect(await provider.fetch() == .credentialsProblem(denied: false))
  }

  @Test func malformedCredentialItemIsCredentialsProblem() async {
    let provider = makeProvider(
      keychain: [.data(Data("not json".utf8))],
      responses: [(Data(), 200)]
    )
    #expect(await provider.fetch() == .credentialsProblem(denied: false))
  }

  @Test func offlineTransportIsStaleAndDoesNotThrow() async {
    let provider = makeProvider(
      keychain: [futureCredential()],
      responses: [(validBody, 200)],
      transportThrows: true
    )
    #expect(await provider.fetch() == .stale())
  }

  @Test(arguments: [429, 403, 500, 502, 503])
  func serverErrorsAreStale(status: Int) async {
    let provider = makeProvider(keychain: [futureCredential()], responses: [(Data(), status)])
    #expect(await provider.fetch() == .stale())
  }

  @Test func undecodable200IsStale() async {
    let provider = makeProvider(
      keychain: [futureCredential()],
      responses: [(Data("<html>nope</html>".utf8), 200)]
    )
    #expect(await provider.fetch() == .stale())
  }

  @Test func oversizeBodyIsStale() async {
    let big = Data(count: ClaudeUsageProvider.maxBodySize + 1)
    let provider = makeProvider(keychain: [futureCredential()], responses: [(big, 200)])
    #expect(await provider.fetch() == .stale())
  }

  @Test func on401ReReadsKeychainAndRetriesWithRotatedToken() async {
    let readCount = LockIsolated(0)
    let staleToken = UsageFixtures.jwt(sub: "acct-1")
    let rotatedToken = UsageFixtures.jwt(sub: "acct-1", expEpochSeconds: nil) + "X"
    let staleCred = KeychainReadOutcome.data(
      UsageFixtures.credentialJSON(token: staleToken, expiresAtMs: epochMs(offset: 3600))
    )
    let rotatedCred = KeychainReadOutcome.data(
      UsageFixtures.credentialJSON(token: rotatedToken, expiresAtMs: epochMs(offset: 3600))
    )
    let provider = makeProvider(
      keychain: [staleCred, rotatedCred],
      responses: [(Data(), 401), (validBody, 200)],
      keychainReadCount: readCount
    )

    let result = await provider.fetch()

    guard case .success = result else {
      Issue.record("Expected success after re-read + retry, got \(result)")
      return
    }
    // One initial read + one re-read on the 401.
    #expect(readCount.value == 2)
  }

  @Test func on401WithSameTokenIsExpired() async {
    let sameCred = futureCredential()
    let provider = makeProvider(
      keychain: [sameCred, sameCred],
      responses: [(Data(), 401)]
    )
    #expect(await provider.fetch() == .expired)
  }

  @Test func locallyExpiredTokenReReadsBeforeGET() async {
    let readCount = LockIsolated(0)
    let expiredCred = KeychainReadOutcome.data(
      UsageFixtures.credentialJSON(
        token: UsageFixtures.jwt(sub: "acct-1"),
        expiresAtMs: epochMs(offset: -60)
      )
    )
    let provider = makeProvider(
      keychain: [expiredCred, futureCredential()],
      responses: [(validBody, 200)],
      keychainReadCount: readCount
    )

    let result = await provider.fetch()
    guard case .success = result else {
      Issue.record("Expected success after pre-empt re-read, got \(result)")
      return
    }
    #expect(readCount.value == 2)  // initial + pre-empt re-read
  }

  @Test func locallyExpiredAndStillExpiredAfterReReadIsExpired() async {
    let expiredCred = KeychainReadOutcome.data(
      UsageFixtures.credentialJSON(
        token: UsageFixtures.jwt(sub: "acct-1"),
        expiresAtMs: epochMs(offset: -60)
      )
    )
    let provider = makeProvider(
      keychain: [expiredCred, expiredCred],
      responses: [(validBody, 200)]
    )
    #expect(await provider.fetch() == .expired)
  }

  // MARK: - Pure guards (AC-D9)

  @Test func tokenCharsetRejectsControlCharacters() {
    #expect(ClaudeUsageProvider.isValidTokenCharset("eyJhbGc.payload-part_09.sig"))
    #expect(!ClaudeUsageProvider.isValidTokenCharset("bad token with space"))
    #expect(!ClaudeUsageProvider.isValidTokenCharset("line\nbreak"))
  }

  @Test func corruptTokenCharsetIsCredentialsProblem() async {
    let provider = makeProvider(
      keychain: [.data(UsageFixtures.credentialJSON(token: "bad token"))],
      responses: [(validBody, 200)]
    )
    #expect(await provider.fetch() == .credentialsProblem(denied: false))
  }

  @Test func crossHostRedirectIsRefused() {
    #expect(UsageNetworking.allowsRedirect(toHost: "api.anthropic.com"))
    #expect(!UsageNetworking.allowsRedirect(toHost: "evil.example.com"))
    #expect(!UsageNetworking.allowsRedirect(toHost: nil))
  }

  @Test func jwtClaimsDecodeSubject() {
    let claims = ClaudeUsageProvider.decodeJWTClaims(UsageFixtures.jwt(sub: "abc-123"))
    #expect(claims?["sub"] as? String == "abc-123")
  }
}
