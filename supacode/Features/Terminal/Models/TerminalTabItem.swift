import Foundation
import SupacodeSettingsShared

struct TerminalTabItem: Identifiable, Equatable, Sendable {
  /// Discriminates a Ghostty terminal tab from a surface-less diff tab so the
  /// tab bar can host both without either coupling to the other's machinery.
  enum Kind: Equatable, Sendable {
    case terminal
    case diff
  }

  let id: TerminalTabID
  /// Live shell title; for display use `displayTitle`.
  var title: String
  /// User-supplied override; nil means follow the live shell title.
  var customTitle: String?
  var icon: String?
  var isDirty: Bool
  var isTitleLocked: Bool
  var tintColor: RepositoryColor?
  /// Sticky marker for tabs born from `runBlockingScript`; stays true after
  /// completion so guardrails outlive the script (these tabs die with the app).
  var isBlockingScript: Bool
  /// Flips true once `markBlockingScriptCompleted` runs. Distinguishes "running"
  /// from "frozen" so the view can show the lock indicator only post-completion.
  var isBlockingScriptCompleted: Bool
  /// Discriminates a Ghostty terminal tab from a surface-less diff tab. Default
  /// `.terminal` so every existing construction is unchanged.
  var kind: Kind = .terminal

  var displayTitle: String { customTitle ?? title }

  init(
    id: TerminalTabID = TerminalTabID(),
    title: String,
    customTitle: String? = nil,
    icon: String?,
    isDirty: Bool = false,
    isTitleLocked: Bool = false,
    tintColor: RepositoryColor? = nil,
    isBlockingScript: Bool = false,
    isBlockingScriptCompleted: Bool = false,
    kind: Kind = .terminal,
  ) {
    self.id = id
    self.title = title
    self.customTitle = customTitle
    self.icon = icon
    self.isDirty = isDirty
    self.isTitleLocked = isTitleLocked
    self.tintColor = tintColor
    self.isBlockingScript = isBlockingScript
    self.isBlockingScriptCompleted = isBlockingScriptCompleted
    self.kind = kind
  }
}
