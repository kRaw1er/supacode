import ComposableArchitecture
import SupacodeSettingsShared
import SwiftUI

public struct AppearanceSettingsView: View {
  @Bindable var store: StoreOf<SettingsFeature>
  /// Dumb binding to the shared toggle; the popover is the live-status source of
  /// truth, so this pane only flips the key. `UsagePillHost.onChange` observes
  /// the same key and carries the flip into the usage reducer's lifecycle.
  @Shared(.usagePillEnabled) private var showClaudeUsage: Bool

  public init(store: StoreOf<SettingsFeature>) {
    self.store = store
  }

  public var body: some View {
    let openActionOptions = store.installedOpenActions
    Form {
      Section {
        LabeledContent {
          HStack(spacing: 12) {
            let appearanceMode = $store.appearanceMode
            ForEach(AppearanceMode.allCases) { mode in
              AppearanceOptionCardView(
                mode: mode,
                isSelected: mode == appearanceMode.wrappedValue
              ) {
                appearanceMode.wrappedValue = mode
              }
            }
          }
          // Keeps the wrapping subtitle from hugging the option cards.
          .padding(.leading, 16)
        } label: {
          Text("Appearance")
          Text("Follow the system appearance, or always use light or dark.")
        }
        Toggle(isOn: $store.terminalThemeSyncEnabled) {
          Text("Supacode terminal theme")
          Text("When off, honors your Ghostty config theme.")
        }
      }
      Section {
        LabeledContent {
          HStack(spacing: 12) {
            ForEach(AppVisibility.allCases) { visibility in
              AppVisibilityOptionCardView(
                visibility: visibility,
                isSelected: visibility == store.appVisibility
              ) {
                store.send(.setAppVisibility(visibility))
              }
            }
          }
          // Keeps the wrapping subtitle from hugging the option cards.
          .padding(.leading, 16)
        } label: {
          Text("Visibility")
          Text("Show Supacode in the Dock, the menu bar, or both.")
        }
      }
      Section("Persistence") {
        Toggle(isOn: $store.terminateSessionsOnQuit) {
          Text("Terminate sessions on quit")
          Text(
            """
            Close all tabs and stop background shells when quitting.
            Terminal persistence is powered by [zmx\u{00A0}\u{2197}](https://github.com/neurosnap/zmx).
            """
          )
        }
        Toggle(isOn: $store.terminalHibernationEnabled) {
          HStack(spacing: 6) {
            Text("Hibernate inactive terminals")
            BetaBadge()
          }
          Text(
            "Background terminal tabs release their renderer after a few minutes of inactivity "
              + "and reconnect instantly when viewed. Sessions and running agents are unaffected."
          )
        }
      }
      Section {
        Toggle(isOn: $store.confirmCloseSurface) {
          Text("Confirm before closing terminals")
          Text("Asks before closing a terminal with a running process or a persisted background session.")
        }
        Picker(selection: $store.confirmQuitMode) {
          ForEach(ConfirmQuitMode.allCases, id: \.self) { mode in
            Text(mode.label).tag(mode)
          }
        } label: {
          Text("Confirm before quitting app")
          Text(store.confirmQuitMode.subtitle)
        }
      }
      Section {
        Toggle(isOn: $store.remoteSessionPersistenceEnabled) {
          HStack(spacing: 6) {
            Text("Persist sessions on remote host")
            BetaBadge()
          }
          Text(
            """
            Keeps SSH sessions alive across disconnects. Ignored when \
            [zmx\u{00A0}\u{2197}](https://github.com/neurosnap/zmx) is not installed on the host.
            """
          )
        }
      }
      Section("Editor") {
        // The stored id deliberately keeps naming an uninstalled editor, so the choice
        // survives a reinstall. No row is tagged with it though, and an untagged
        // selection renders blank, so normalize for display and write back raw.
        let storedEditorID = $store.defaultEditorID
        let defaultEditorID = Binding(
          get: {
            OpenWorktreeAction.normalizedDefaultEditorID(
              storedEditorID.wrappedValue,
              installed: openActionOptions
            )
          },
          set: { storedEditorID.wrappedValue = $0 }
        )
        Picker(
          selection: defaultEditorID
        ) {
          Text("Automatic")
            .tag(OpenWorktreeAction.automaticSettingsID)
          ForEach(openActionOptions) { action in
            Text(action.labelTitle)
              .tag(action.settingsID)
          }
        } label: {
          Text("Default editor")
          Text("Applies to Worktrees without repository overrides.")
        }
      }
      Section("Scripts") {
        Stepper(value: $store.maxPinnedToolbarButtons, in: GlobalSettings.pinnedToolbarButtonRange) {
          Text("Pinned toolbar buttons: \(store.maxPinnedToolbarButtons)")
          Text("How many pinned scripts show as toolbar buttons before the rest fall into the Scripts menu.")
        }
        .help("Set how many pinned scripts appear as one-click toolbar buttons.")
      }
      Section {
        Toggle(
          isOn: Binding(
            get: { showClaudeUsage },
            set: { newValue in $showClaudeUsage.withLock { $0 = newValue } }
          )
        ) {
          Text("Show Claude usage")
          Text("Displays session and weekly Claude usage in the sidebar.")
        }
        .help("Show a Claude usage pill at the bottom of the sidebar.")
      } header: {
        Text("Usage")
      } footer: {
        Text(
          """
          Usage is read from the account signed in to the Claude Code CLI. \
          Turning this off stops all usage checks.
          """
        )
      }
      Section {
        Toggle(isOn: $store.analyticsEnabled) {
          Text("Share analytics")
          Text("Anonymous usage data helps improve Supacode.")
        }
        Toggle(isOn: $store.crashReportsEnabled) {
          Text("Share crash reports")
          Text("Anonymous crash reports help improve stability.")
        }
      } header: {
        Text("Analytics")
      } footer: {
        Text("Changes to Analytics require Supacode to restart before they take effect.")
      }
    }
    .formStyle(.grouped)
    .contentMargins(.trailing, 6, for: .scrollIndicators)
    .padding(.top, -20)
    .padding(.leading, -8)
    .padding(.trailing, -6)
    .navigationTitle("General")
  }
}

/// Small system-styled tag marking a setting as Beta. Uses `.quaternary` fill so
/// it tracks the theme and never introduces a custom color.
private struct BetaBadge: View {
  var body: some View {
    Text("Beta")
      .font(.caption2)
      .fontWeight(.semibold)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(.quaternary, in: .capsule)
  }
}
