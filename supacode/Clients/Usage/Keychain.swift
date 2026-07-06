import CryptoKit
import Foundation

/// Outcome of a single Keychain read, mapping the `/usr/bin/security` exit code
/// to the states the provider cares about. `denied` latches (stop auto-reads);
/// `interactionNotAllowed` does not (recovers when the keychain unlocks).
nonisolated enum KeychainReadOutcome: Sendable, Equatable {
  /// The raw item data (the CLI's credential JSON blob).
  case data(Data)
  /// No such item — the user has never logged into the CLI.
  case notFound
  /// ACL denied / auth failed — the user clicked Deny on the access prompt.
  case denied
  /// Keychain locked / no UI context / the `security` call timed out —
  /// transient, recovers on unlock.
  case interactionNotAllowed
  /// Any other unexpected `security` exit status (carried for logging; never a token).
  case failure(Int32)
}

/// Reads the Claude Code CLI's login-keychain credential item **by shelling out
/// to `/usr/bin/security`**, off the main actor.
///
/// Why a subprocess instead of `SecItemCopyMatching`: the credential item is
/// created by the Claude Code CLI, whose ACL trusts `/usr/bin/security` (a
/// stable, Apple-signed system binary). Reading through that same trusted tool
/// returns the secret with **no ACL prompt** — matching how Orca reads it. An
/// in-process `SecItemCopyMatching` runs as *supacode*, which is not in the
/// item's ACL, so macOS prompts on every read; worse, a Debug build is
/// re-signed each build, so an "Always Allow" grant never persists and the
/// prompt returns forever. Read-only: there is no write path in v1.
///
/// A dedicated `actor` serializes reads (one `security` process at a time).
actor Keychain {
  /// The generic-password service the Claude Code CLI stores its OAuth
  /// credentials under. Isolated here so the one undocumented string lives in
  /// exactly one place.
  static let claudeCredentialsService = "Claude Code-credentials"

  /// Absolute path so a hostile `PATH` can't shadow the system tool.
  private static let securityToolPath = "/usr/bin/security"

  /// Guard against a wedged `security` invocation hanging the poll loop
  /// (mirrors Orca's 3s cap).
  private static let commandTimeout: TimeInterval = 3

  /// The keychain account (`-a`) the CLI stored the item under — its `$USER`.
  private let account: String
  /// The Claude config dir, if the user overrides it. `nil` → default `~/.claude`,
  /// which uses the unscoped service name.
  private let configDir: String?

  init(
    account: String = Keychain.defaultAccount(),
    configDir: String? = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
  ) {
    self.account = account
    self.configDir = configDir
  }

  /// The account the item is keyed under. Mirrors Orca's `USER || USERNAME`,
  /// falling back to `NSUserName()` for a GUI process that inherited neither.
  nonisolated static func defaultAccount() -> String {
    let env = ProcessInfo.processInfo.environment
    return env["USER"] ?? env["USERNAME"] ?? NSUserName()
  }

  /// Claude Code 2.1+ scopes the macOS Keychain service by config dir, appending
  /// the first 8 hex chars of `sha256(CLAUDE_CONFIG_DIR)`.
  nonisolated static func scopedService(configDir: String) -> String {
    let digest = SHA256.hash(data: Data(configDir.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "\(claudeCredentialsService)-\(hex.prefix(8))"
  }

  /// The service names to probe, in order: the config-dir-scoped name first
  /// (Claude 2.1+), then the unscoped base name as a fallback. A default config
  /// dir yields the base name alone.
  nonisolated static func candidateServices(configDir: String?) -> [String] {
    guard let configDir, !configDir.isEmpty else { return [claudeCredentialsService] }
    let scoped = scopedService(configDir: configDir)
    return scoped == claudeCredentialsService ? [claudeCredentialsService] : [scoped, claudeCredentialsService]
  }

  /// Reads the credential item, trying each candidate service until one is
  /// present. A `notFound` on the scoped name falls through to the base name;
  /// any other outcome (data / denied / failure) returns immediately.
  func read() -> KeychainReadOutcome {
    var lastOutcome: KeychainReadOutcome = .notFound
    for service in Self.candidateServices(configDir: configDir) {
      let outcome = Self.runSecurityRead(service: service, account: account)
      if case .notFound = outcome {
        lastOutcome = outcome
        continue
      }
      return outcome
    }
    return lastOutcome
  }

  /// Runs `security find-generic-password -s <service> -a <account> -w` and maps
  /// the result. `-w` prints the raw secret (the CLI's credential JSON) to
  /// stdout; a trailing newline is stripped.
  private static func runSecurityRead(service: String, account: String) -> KeychainReadOutcome {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: securityToolPath)
    process.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    // Never inherit a controlling terminal / stdin.
    process.standardInput = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      return .failure(-1)
    }

    // Watchdog: SIGTERM a wedged invocation so a stuck Keychain never hangs the
    // poll loop. `terminationReason == .uncaughtSignal` then flags the timeout.
    let timeout = DispatchWorkItem { [weak process] in
      guard let process, process.isRunning else { return }
      process.terminate()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + commandTimeout, execute: timeout)

    // The credential blob is a few KB — well under the pipe buffer — so reading
    // after exit can't deadlock.
    process.waitUntilExit()
    timeout.cancel()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

    if process.terminationReason == .uncaughtSignal {
      // We SIGTERM'd it (timeout) — treat as transient, don't latch.
      return .interactionNotAllowed
    }

    let status = process.terminationStatus
    if status == 0 {
      let trimmed = (String(bytes: stdoutData, encoding: .utf8) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return .notFound }
      return .data(Data(trimmed.utf8))
    }

    // `security` returns 44 for a missing item.
    let stderr = (String(bytes: stderrData, encoding: .utf8) ?? "").lowercased()
    if status == 44 || stderr.contains("could not be found") || stderr.contains("not be found") {
      return .notFound
    }
    if stderr.contains("user canceled") || stderr.contains("user cancelled") || stderr.contains("auth") {
      return .denied
    }
    if stderr.contains("interaction") {
      return .interactionNotAllowed
    }
    return .failure(status)
  }
}
