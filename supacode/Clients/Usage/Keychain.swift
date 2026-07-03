import Foundation
import Security

/// Outcome of a single Keychain read, mapping raw `OSStatus` codes to the
/// states the provider cares about. `denied` latches (stop auto-reads);
/// `interactionNotAllowed` does not (recovers when the keychain unlocks).
nonisolated enum KeychainReadOutcome: Sendable, Equatable {
  /// The raw item data (the CLI's credential JSON blob).
  case data(Data)
  /// No such item — the user has never logged into the CLI.
  case notFound
  /// ACL denied / auth failed — the user clicked Deny on the access prompt.
  case denied
  /// Keychain locked or no UI context — transient, recovers on unlock.
  case interactionNotAllowed
  /// Any other unexpected status (carried for logging; never a token).
  case failure(OSStatus)
}

/// Reads the Claude Code CLI's login-keychain credential item, off the main
/// actor. A dedicated `actor` serializes reads and — critically — keeps the
/// synchronous, blocking, system-modal ACL prompt off the main actor so it can
/// never freeze the UI. Read-only: there is no write path in v1.
actor Keychain {
  /// The generic-password service the Claude Code CLI stores its OAuth
  /// credentials under. Isolated here so the one undocumented string lives in
  /// exactly one place.
  static let claudeCredentialsService = "Claude Code-credentials"

  private let service: String

  init(service: String = Keychain.claudeCredentialsService) {
    self.service = service
  }

  /// Reads the credential item. Notes on the query:
  /// - `kSecClassGenericPassword` + service match, first item only.
  /// - We deliberately DO NOT set `kSecUseDataProtectionKeychain`: on macOS
  ///   that targets the iOS-style data-protection store and would miss the
  ///   CLI's login-keychain item entirely.
  /// - `kSecAttrSynchronizableAny` so an iCloud-synced item is still matched.
  func read() -> KeychainReadOutcome {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
    ]

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)

    switch status {
    case errSecSuccess:
      guard let data = item as? Data else { return .failure(status) }
      return .data(data)
    case errSecItemNotFound:
      return .notFound
    case errSecUserCanceled, errSecAuthFailed:
      return .denied
    case errSecInteractionNotAllowed:
      return .interactionNotAllowed
    default:
      return .failure(status)
    }
  }
}
