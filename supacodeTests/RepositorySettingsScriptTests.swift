import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsFeature
@testable import SupacodeSettingsShared

// MARK: - Codable migration tests.

struct RepositorySettingsCodableTests {
  @Test func decodeFromLegacyRunScriptOnly() throws {
    // JSON with only `runScript` and no `scripts` key should produce
    // a single `.run`-kind ScriptDefinition.
    let json = """
      {
        "setupScript": "",
        "archiveScript": "",
        "deleteScript": "",
        "runScript": "npm start",
        "openActionID": "automatic"
      }
      """
    let data = Data(json.utf8)
    let settings = try JSONDecoder().decode(RepositorySettings.self, from: data)
    #expect(settings.scripts.count == 1)
    #expect(settings.scripts.first?.kind == .run)
    #expect(settings.scripts.first?.command == "npm start")
  }

  @Test func decodeWithBothRunScriptAndScripts() throws {
    // When both `runScript` and `scripts` are present, `scripts` wins.
    let json = """
      {
        "setupScript": "",
        "archiveScript": "",
        "deleteScript": "",
        "runScript": "legacy command",
        "scripts": [
          {
            "id": "00000000-0000-0000-0000-000000000001",
            "kind": "test", "name": "Test",
            "systemImage": "checkmark.diamond.fill",
            "tintColor": "blue", "command": "npm test"
          }
        ],
        "openActionID": "automatic"
      }
      """
    let data = Data(json.utf8)
    let settings = try JSONDecoder().decode(RepositorySettings.self, from: data)
    #expect(settings.scripts.count == 1)
    #expect(settings.scripts.first?.kind == .test)
    #expect(settings.scripts.first?.command == "npm test")
  }

  @Test func encodeRoundTripPopulatesRunScript() throws {
    // Encoding settings with scripts should derive `runScript` from
    // the first `.run`-kind script's command.
    var settings = RepositorySettings.default
    settings.scripts = [
      ScriptDefinition(kind: .test, command: "npm test"),
      ScriptDefinition(kind: .run, command: "npm run dev"),
    ]
    let data = try JSONEncoder().encode(settings)
    let raw = try JSONDecoder().decode([String: AnyCodable].self, from: data)
    #expect(raw["runScript"]?.stringValue == "npm run dev")
  }

  @Test func encodeWithNoRunKindScriptClearsRunScript() throws {
    // When no `.run`-kind script exists, the encoded `runScript`
    // should be empty — not the stale legacy value.
    var settings = RepositorySettings(
      setupScript: "",
      archiveScript: "",
      deleteScript: "",
      runScript: "stale legacy command",
      scripts: [ScriptDefinition(kind: .test, command: "npm test")],
      openActionID: "automatic",
      worktreeBaseRef: nil
    )
    let data = try JSONEncoder().encode(settings)
    let raw = try JSONDecoder().decode([String: AnyCodable].self, from: data)
    #expect(raw["runScript"]?.stringValue == "")
  }

  @Test func decodeWithUnknownScriptKindDropsOnlyInvalidEntries() throws {
    // An unknown `kind` value should only drop that entry, not the
    // entire array. Valid sibling scripts must survive.
    let json = """
      {
        "setupScript": "",
        "archiveScript": "",
        "deleteScript": "",
        "runScript": "",
        "scripts": [
          {
            "id": "00000000-0000-0000-0000-000000000001",
            "kind": "run", "name": "Run",
            "systemImage": "play",
            "tintColor": "green", "command": "npm start"
          },
          {
            "id": "00000000-0000-0000-0000-000000000002",
            "kind": "unknown_future_kind", "name": "X",
            "systemImage": "star",
            "tintColor": "red", "command": "echo hi"
          },
          {
            "id": "00000000-0000-0000-0000-000000000003",
            "kind": "test", "name": "Test",
            "systemImage": "play.diamond",
            "tintColor": "yellow", "command": "npm test"
          }
        ],
        "openActionID": "automatic"
      }
      """
    let data = Data(json.utf8)
    let settings = try JSONDecoder().decode(RepositorySettings.self, from: data)
    #expect(settings.scripts.count == 2)
    #expect(settings.scripts[0].kind == .run)
    #expect(settings.scripts[0].command == "npm start")
    #expect(settings.scripts[1].kind == .test)
    #expect(settings.scripts[1].command == "npm test")
  }
}

// MARK: - Script icon + pin decoding.

struct ScriptDefinitionIconPinCodableTests {
  private static let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

  @Test func showInToolbarRoundTrips() throws {
    var script = ScriptDefinition(id: Self.id, kind: .custom, name: "Deploy", command: "fly deploy")
    script.showInToolbar = true
    let decoded = try JSONDecoder().decode(
      ScriptDefinition.self,
      from: try JSONEncoder().encode(script),
    )
    #expect(decoded.showInToolbar == true)
    #expect(decoded == script)  // whole-value round-trip guards against field drift
  }

  @Test func missingShowInToolbarKeyDecodesFalse() throws {
    // Simulates a script written by a build that predates the flag.
    let json = """
      {"id":"\(Self.id)","kind":"custom","name":"Lint","command":"make lint"}
      """
    let decoded = try JSONDecoder().decode(ScriptDefinition.self, from: Data(json.utf8))
    #expect(decoded.showInToolbar == false)  // opt-in default: no surprise pins on upgrade
  }

  @Test func malformedShowInToolbarCollapsesToFalseAndKeepsScript() throws {
    // A corrupt / hand-edited value must not fail the whole entry.
    let json = """
      {"id":"\(Self.id)","kind":"custom","name":"Lint","command":"make lint","showInToolbar":"yes-please"}
      """
    let decoded = try JSONDecoder().decode(ScriptDefinition.self, from: Data(json.utf8))
    #expect(decoded.showInToolbar == false)
    #expect(decoded.name == "Lint")  // rest of the script survives
    #expect(decoded.command == "make lint")
  }

  @Test func systemImageRoundTrips() throws {
    var script = ScriptDefinition(id: Self.id, kind: .custom, name: "Deploy", command: "fly deploy")
    script.systemImage = "paperplane.fill"
    let decoded = try JSONDecoder().decode(
      ScriptDefinition.self,
      from: try JSONEncoder().encode(script),
    )
    #expect(decoded.systemImage == "paperplane.fill")
    #expect(decoded.resolvedSystemImage == "paperplane.fill")
  }

  @Test func malformedSystemImageDropsOverrideNotScript() throws {
    // A non-string systemImage drops to nil → resolvedSystemImage falls back to the kind default.
    let json = """
      {"id":"\(Self.id)","kind":"custom","name":"Lint","command":"make lint","systemImage":123}
      """
    let decoded = try JSONDecoder().decode(ScriptDefinition.self, from: Data(json.utf8))
    #expect(decoded.systemImage == nil)
    #expect(decoded.name == "Lint")
    #expect(decoded.resolvedSystemImage == ScriptKind.custom.defaultSystemImage)
  }
}

// MARK: - Pin-to-toolbar helper.

struct ScriptDefinitionPinHelperTests {
  private func pinned(_ script: ScriptDefinition) -> ScriptDefinition {
    var copy = script
    copy.showInToolbar = true
    return copy
  }

  @Test func filtersToShowInToolbar() {
    let pin = pinned(ScriptDefinition(kind: .custom, name: "A", command: "a"))
    let plain = ScriptDefinition(kind: .custom, name: "B", command: "b")
    #expect([pin, plain].pinnedToolbarScripts(limit: 4) == [pin])
  }

  @Test func preservesMergedOrderRepoBeforeGlobal() {
    let repoPin = pinned(ScriptDefinition(kind: .run, name: "Repo", command: "r"))
    let globalPin = pinned(ScriptDefinition(kind: .custom, name: "Global", command: "g"))
    let merged = [ScriptDefinition].merged(repo: [repoPin], global: [globalPin])
    #expect(merged.pinnedToolbarScripts(limit: 4) == [repoPin, globalPin])
  }

  @Test func respectsLimitCapKeepingLeadingOrder() {
    let pins = (0..<6).map { pinned(ScriptDefinition(kind: .custom, name: "S\($0)", command: "c")) }
    #expect(pins.pinnedToolbarScripts(limit: 4) == Array(pins.prefix(4)))
  }

  @Test func keepsBlankCommandPins() {
    // Explicitly pinned but blank-command scripts stay (rendered disabled), unlike
    // visibleGlobalScripts which hides half-configured UNpinned globals.
    let blankPin = pinned(ScriptDefinition(kind: .custom, name: "Empty", command: "   "))
    #expect([blankPin].pinnedToolbarScripts(limit: 4) == [blankPin])
  }

  @Test func dropsGlobalShadowedByRepoID() {
    // A pinned global shadowed by a repo script of the same ID must not double-render:
    // `.merged` already drops it, so the helper on the merged input reflects that.
    let id = UUID()
    let repoPin = pinned(ScriptDefinition(id: id, kind: .test, name: "Repo", command: "r"))
    let globalPin = pinned(ScriptDefinition(id: id, kind: .custom, name: "Global", command: "g"))
    let merged = [ScriptDefinition].merged(repo: [repoPin], global: [globalPin])
    #expect(merged.pinnedToolbarScripts(limit: 4) == [repoPin])
  }
}

// MARK: - Global scripts decoding.

struct GlobalSettingsScriptsCodableTests {
  @Test func decodeMissingGlobalScriptsKeyDefaultsToEmpty() throws {
    let json = try baseGlobalSettingsJSON()
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: Data(json.utf8))
    #expect(settings.globalScripts.isEmpty)
  }

  @Test func decodeMalformedGlobalScriptsValueDefaultsToEmpty() throws {
    var dict = baseGlobalSettingsDict()
    dict["globalScripts"] = "not-an-array"
    let data = try JSONSerialization.data(withJSONObject: dict)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: data)
    #expect(settings.globalScripts.isEmpty)
  }

  @Test func decodeWithUnknownGlobalScriptKindDropsOnlyInvalidEntries() throws {
    var dict = baseGlobalSettingsDict()
    dict["globalScripts"] = [
      [
        "id": "00000000-0000-0000-0000-000000000001",
        "kind": "custom", "name": "Lint", "command": "make lint",
      ],
      [
        "id": "00000000-0000-0000-0000-000000000002",
        "kind": "unknown_future_kind", "name": "Bad", "command": "noop",
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: dict)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: data)
    #expect(settings.globalScripts.count == 1)
    #expect(settings.globalScripts.first?.name == "Lint")
  }

  @Test func decodeMissingRequiredFieldDropsOnlyThatEntry() throws {
    // A script entry missing a required field (id / kind / name / command)
    // is dropped by `Lossy<ScriptDefinition>` rather than failing the whole
    // `globalScripts` decode.
    var dict = baseGlobalSettingsDict()
    dict["globalScripts"] = [
      [
        "id": "00000000-0000-0000-0000-000000000001",
        "kind": "custom", "name": "Good", "command": "echo good",
      ],
      [
        "kind": "custom", "name": "MissingID", "command": "echo bad",
      ],
    ]
    let data = try JSONSerialization.data(withJSONObject: dict)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: data)
    #expect(settings.globalScripts.count == 1)
    #expect(settings.globalScripts.first?.name == "Good")
  }

  @Test func decodeMalformedTintColorPreservesScript() throws {
    // A bad `tintColor` payload should drop just the override, not the
    // entire script — otherwise one malformed hex wipes the user's name
    // and command for that entry.
    var dict = baseGlobalSettingsDict()
    dict["globalScripts"] = [
      [
        "id": "00000000-0000-0000-0000-000000000001",
        "kind": "custom", "name": "Lint", "command": "make lint",
        "tintColor": "not-a-color",
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: dict)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: data)
    #expect(settings.globalScripts.count == 1)
    #expect(settings.globalScripts.first?.name == "Lint")
    #expect(settings.globalScripts.first?.command == "make lint")
    #expect(settings.globalScripts.first?.tintColor == nil)
  }

  @Test func decodeRoundTripsCustomHexTintOnGlobalScript() throws {
    // Custom hex tint chosen via the SwiftUI color picker should survive a
    // settings file round-trip without normalization stripping it.
    var dict = baseGlobalSettingsDict()
    dict["globalScripts"] = [
      [
        "id": "00000000-0000-0000-0000-000000000001",
        "kind": "custom", "name": "Lint", "command": "make lint",
        "tintColor": "#A1B2C3",
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: dict)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: data)
    #expect(settings.globalScripts.first?.tintColor == .custom("#A1B2C3"))
  }

  @Test func decodeNormalizesNonCustomGlobalScriptKindToCustom() throws {
    // A hand-edited or forged settings file shipping a `.run` global must not
    // be able to hijack the primary toolbar slot. Decoder forces `.custom`.
    var dict = baseGlobalSettingsDict()
    dict["globalScripts"] = [
      [
        "id": "00000000-0000-0000-0000-000000000001",
        "kind": "run", "name": "Sneaky", "command": "rm -rf /",
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: dict)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: data)
    #expect(settings.globalScripts.count == 1)
    #expect(settings.globalScripts.first?.kind == .custom)
  }

  @Test func decodePreservesShowInToolbarAndSystemImageWhileForcingCustomKind() throws {
    // The `.custom` normalization loop must not wipe the new fields.
    var dict = baseGlobalSettingsDict()
    dict["globalScripts"] = [
      [
        "id": "00000000-0000-0000-0000-000000000001",
        "kind": "run",  // forged — must normalize to .custom
        "name": "Sneaky", "command": "echo hi",
        "showInToolbar": true,
        "systemImage": "bolt.fill",
      ]
    ]
    let data = try JSONSerialization.data(withJSONObject: dict)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: data)
    let script = try #require(settings.globalScripts.first)
    #expect(script.kind == .custom)  // security invariant unchanged
    #expect(script.showInToolbar == true)  // new field survives normalization
    #expect(script.systemImage == "bolt.fill")
  }

  @Test func decodeMissingMaxPinnedToolbarButtonsUsesDefault() throws {
    let json = try baseGlobalSettingsJSON()
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: Data(json.utf8))
    #expect(settings.maxPinnedToolbarButtons == GlobalSettings.default.maxPinnedToolbarButtons)
  }

  @Test func decodeClampsOutOfRangeMaxPinnedToolbarButtons() throws {
    var dict = baseGlobalSettingsDict()
    dict["maxPinnedToolbarButtons"] = 999
    let high = try JSONDecoder().decode(
      GlobalSettings.self, from: try JSONSerialization.data(withJSONObject: dict))
    #expect(high.maxPinnedToolbarButtons == GlobalSettings.pinnedToolbarButtonRange.upperBound)

    dict["maxPinnedToolbarButtons"] = 0
    let low = try JSONDecoder().decode(
      GlobalSettings.self, from: try JSONSerialization.data(withJSONObject: dict))
    #expect(low.maxPinnedToolbarButtons == GlobalSettings.pinnedToolbarButtonRange.lowerBound)
  }

  // MARK: - Helpers.

  private func baseGlobalSettingsDict() -> [String: Any] {
    [
      "appearanceMode": "dark",
      "defaultEditorID": "automatic",
      "updateChannel": "stable",
      "updatesAutomaticallyCheckForUpdates": true,
      "updatesAutomaticallyDownloadUpdates": false,
      "inAppNotificationsEnabled": true,
      "notificationSoundEnabled": true,
      "systemNotificationsEnabled": false,
      "moveNotifiedWorktreeToTop": true,
      "analyticsEnabled": true,
      "crashReportsEnabled": true,
      "githubIntegrationEnabled": true,
      "deleteBranchOnDeleteWorktree": true,
      "promptForWorktreeCreation": true,
    ]
  }

  private func baseGlobalSettingsJSON() throws -> String {
    let data = try JSONSerialization.data(withJSONObject: baseGlobalSettingsDict())
    return String(bytes: data, encoding: .utf8) ?? ""
  }
}

/// Lightweight type-erased wrapper for JSON inspection in tests.
private struct AnyCodable: Decodable {
  let value: Any

  var stringValue: String? { value as? String }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let string = try? container.decode(String.self) {
      value = string
    } else if let int = try? container.decode(Int.self) {
      value = int
    } else if let bool = try? container.decode(Bool.self) {
      value = bool
    } else if let array = try? container.decode([AnyCodable].self) {
      value = array.map(\.value)
    } else if let dict = try? container.decode([String: AnyCodable].self) {
      value = dict.mapValues(\.value)
    } else {
      value = NSNull()
    }
  }
}

// MARK: - Feature tests.

@MainActor
struct RepositorySettingsScriptTests {
  private static let rootURL = URL(filePath: "/tmp/test-repo")

  private func makeStore(
    scripts: [ScriptDefinition] = []
  ) -> TestStore<RepositorySettingsFeature.State, RepositorySettingsFeature.Action> {
    var settings = RepositorySettings.default
    settings.scripts = scripts
    return TestStore(
      initialState: RepositorySettingsFeature.State(
        rootURL: Self.rootURL,
        settings: settings,
      ),
    ) {
      RepositorySettingsFeature()
    }
  }

  @Test(.dependencies) func addScriptAppendsCustomScript() async {
    let store = makeStore()
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.addScript(.custom)) {
      #expect($0.settings.scripts.count == 1)
      #expect($0.settings.scripts.first?.kind == .custom)
      #expect($0.settings.scripts.first?.name == "Custom")
    }
  }

  @Test(.dependencies) func addScriptRejectsDuplicatePredefinedKind() async {
    let store = makeStore(scripts: [ScriptDefinition(kind: .lint, command: "swiftlint")])
    store.exhaustivity = .off(showSkippedAssertions: false)

    // Second .lint is silently rejected.
    await store.send(.addScript(.lint))
    #expect(store.state.settings.scripts.count == 1)
  }

  @Test(.dependencies) func addScriptAllowsMultipleCustomKinds() async {
    let store = makeStore(scripts: [ScriptDefinition(kind: .custom, name: "A", command: "a")])
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.addScript(.custom)) {
      #expect($0.settings.scripts.count == 2)
    }
  }

  @Test(.dependencies) func removeScriptShowsConfirmationAndRemovesByID() async {
    let script1 = ScriptDefinition(kind: .run, command: "npm run dev")
    let script2 = ScriptDefinition(kind: .test, command: "npm test")
    let script3 = ScriptDefinition(kind: .deploy, command: "deploy.sh")
    let store = makeStore(scripts: [script1, script2, script3])
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.removeScript(script2.id)) {
      $0.alert = AlertState {
        TextState("Remove \"\(script2.displayName)\" script?")
      } actions: {
        ButtonState(role: .destructive, action: .confirmRemoveScript(script2.id)) {
          TextState("Remove")
        }
        ButtonState(role: .cancel) {
          TextState("Cancel")
        }
      } message: {
        TextState(
          "This action cannot be undone. Any running instance keeps running in its terminal "
            + "tab until you close it manually."
        )
      }
    }

    await store.send(.alert(.presented(.confirmRemoveScript(script2.id)))) {
      $0.alert = nil
      $0.settings.scripts = [script1, script3]
    }
  }

  @Test(.dependencies) func removeScriptCancelDoesNotRemove() async {
    let script = ScriptDefinition(kind: .run, command: "npm run dev")
    let store = makeStore(scripts: [script])
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.removeScript(script.id)) {
      $0.alert = AlertState {
        TextState("Remove \"\(script.displayName)\" script?")
      } actions: {
        ButtonState(role: .destructive, action: .confirmRemoveScript(script.id)) {
          TextState("Remove")
        }
        ButtonState(role: .cancel) {
          TextState("Cancel")
        }
      } message: {
        TextState(
          "This action cannot be undone. Any running instance keeps running in its terminal "
            + "tab until you close it manually."
        )
      }
    }

    await store.send(.alert(.dismiss)) {
      $0.alert = nil
    }

    #expect(store.state.settings.scripts.count == 1)
  }

  @Test(.dependencies) func togglingShowInToolbarPersists() async {
    // A `.run` script also exercises "predefined kinds are pinnable".
    let script = ScriptDefinition(kind: .run, command: "npm run dev")
    let store = makeStore(scripts: [script])
    store.exhaustivity = .off(showSkippedAssertions: false)

    var pinned = script
    pinned.showInToolbar = true
    await store.send(.binding(.set(\.settings.scripts, [pinned]))) {
      $0.settings.scripts = [pinned]
    }
    await store.receive(\.delegate.settingsChanged)

    @Shared(.repositorySettings(Self.rootURL, host: nil)) var persisted
    #expect(persisted.scripts.first?.showInToolbar == true)
  }

}
