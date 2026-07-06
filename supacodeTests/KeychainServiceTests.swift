import Foundation
import Testing

@testable import supacode

/// Pure-logic coverage for the Keychain service-name derivation. Never touches
/// the real login Keychain (the live `read()` shells out to `/usr/bin/security`
/// and is exercised only in the running app, never under test).
struct KeychainServiceTests {
  @Test func scopedServiceAppendsFirst8HexOfConfigDirSHA256() {
    // Cross-checked against `printf '%s' <dir> | shasum -a 256` (Orca's scheme).
    #expect(Keychain.scopedService(configDir: "/Users/dmitry/.claude") == "Claude Code-credentials-e9d75657")
    #expect(Keychain.scopedService(configDir: "/tmp/cfg") == "Claude Code-credentials-519e587f")
  }

  @Test func defaultConfigDirProbesUnscopedServiceOnly() {
    #expect(Keychain.candidateServices(configDir: nil) == ["Claude Code-credentials"])
    #expect(Keychain.candidateServices(configDir: "") == ["Claude Code-credentials"])
  }

  @Test func customConfigDirProbesScopedThenUnscoped() {
    #expect(
      Keychain.candidateServices(configDir: "/tmp/cfg") == [
        "Claude Code-credentials-519e587f",
        "Claude Code-credentials",
      ]
    )
  }

  @Test func defaultAccountIsNonEmpty() {
    // Resolves from $USER / $USERNAME / NSUserName(); always yields a login name.
    #expect(!Keychain.defaultAccount().isEmpty)
  }
}
