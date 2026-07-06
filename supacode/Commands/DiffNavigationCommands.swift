import SwiftUI

/// The "Diff" menu — Next/Previous Change and Next/Previous File, discoverable in
/// the menu bar **without** single-letter key-equivalents. The single-letter keys
/// (`n`/`p`/`]`/`[`) are the app-level `DiffKeyboardNav` key path (the viewport's
/// `keyDown`), never menu equivalents — a menu `keyboardShortcut("n")` fires globally
/// and would swallow `n` even inside a focused text field (CLAUDE.md FocusedAction
/// rule). The letter is surfaced as an informational `.help(...)` hint instead, so
/// the button still satisfies the tooltip+hotkey UX rule.
///
/// Actions are `FocusedAction<Void>` (mirrors `SidebarCommands`) published from the
/// diff host view once the ChunkTree viewport is wired (Phase-13 seam). Until a
/// diff is focused, `@FocusedValue` resolves `nil` and every button is disabled — the
/// menu structure + `FocusedAction` plumbing are complete; only the publisher rides
/// in with the viewport.
struct DiffNavigationCommands: Commands {
  @FocusedValue(\.diffNextChangeAction) private var nextChange
  @FocusedValue(\.diffPrevChangeAction) private var prevChange
  @FocusedValue(\.diffNextFileAction) private var nextFile
  @FocusedValue(\.diffPrevFileAction) private var prevFile

  var body: some Commands {
    CommandMenu("Diff") {
      Button("Next Change") { nextChange?() }
        .help("Go to the next change — press n in the diff")  // hint, NOT a keyEquivalent
        .disabled(nextChange?.isEnabled != true)
      Button("Previous Change") { prevChange?() }
        .help("Go to the previous change — press p in the diff")
        .disabled(prevChange?.isEnabled != true)
      Button("Next File") { nextFile?() }
        .help("Jump to the next file — press ] in the diff")
        .disabled(nextFile?.isEnabled != true)
      Button("Previous File") { prevFile?() }
        .help("Jump to the previous file — press [ in the diff")
        .disabled(prevFile?.isEnabled != true)
    }
  }
}

private struct DiffNextChangeKey: FocusedValueKey { typealias Value = FocusedAction<Void> }
private struct DiffPrevChangeKey: FocusedValueKey { typealias Value = FocusedAction<Void> }
private struct DiffNextFileKey: FocusedValueKey { typealias Value = FocusedAction<Void> }
private struct DiffPrevFileKey: FocusedValueKey { typealias Value = FocusedAction<Void> }

extension FocusedValues {
  var diffNextChangeAction: FocusedAction<Void>? {
    get { self[DiffNextChangeKey.self] }
    set { self[DiffNextChangeKey.self] = newValue }
  }
  var diffPrevChangeAction: FocusedAction<Void>? {
    get { self[DiffPrevChangeKey.self] }
    set { self[DiffPrevChangeKey.self] = newValue }
  }
  var diffNextFileAction: FocusedAction<Void>? {
    get { self[DiffNextFileKey.self] }
    set { self[DiffNextFileKey.self] = newValue }
  }
  var diffPrevFileAction: FocusedAction<Void>? {
    get { self[DiffPrevFileKey.self] }
    set { self[DiffPrevFileKey.self] = newValue }
  }
}
