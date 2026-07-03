import AppKit
import SupacodeSettingsShared
import SwiftUI

/// Prowl-style SF Symbol picker for a custom script's icon: a curated preset
/// grid, a free-text field for any system symbol, and a launcher to Apple's
/// SF Symbols app. Writes `systemImage` directly — clearing the field stores
/// `nil` so `ScriptDefinition.resolvedSystemImage` falls back to the kind default.
struct ScriptSymbolPickerRow: View {
  @Binding var systemImage: String?
  /// Resolved tint, so the preview matches the toolbar / menu / header rendering.
  let tint: RepositoryColor

  @State private var isPresented = false

  var body: some View {
    LabeledContent("Icon") {
      Button {
        isPresented = true
      } label: {
        Image.tintedSymbol(previewSymbol, color: tint.nsColor)
          .imageScale(.large)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Icon: \(previewSymbol)")
      .help("Choose an SF Symbol icon for this script.")
      .popover(isPresented: $isPresented, arrowEdge: .bottom) {
        pickerContent
      }
    }
  }

  /// The symbol shown in the preview: the user's override, or the custom-kind
  /// default when unset (the icon row only appears for `.custom` scripts).
  private var previewSymbol: String {
    let trimmed = systemImage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? ScriptKind.custom.defaultSystemImage : trimmed
  }

  /// Free-text field mapping: empty input clears the override back to `nil`.
  private var freeText: Binding<String> {
    Binding(
      get: { systemImage ?? "" },
      set: { newValue in
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        systemImage = trimmed.isEmpty ? nil : trimmed
      },
    )
  }

  private var isUnknownSymbol: Bool {
    guard let name = systemImage, !name.isEmpty else { return false }
    return NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil
  }

  private var pickerContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Pick a common symbol or enter any SF Symbol name available on your system.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(width: 300, alignment: .leading)

      TextField("SF Symbol name", text: freeText)
        .textFieldStyle(.roundedBorder)

      if isUnknownSymbol {
        Label("Unknown symbol — it may not render.", systemImage: "exclamationmark.triangle")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 30), spacing: 8)], spacing: 8) {
          ForEach(ScriptSymbolPresets.all, id: \.self) { symbol in
            Button {
              systemImage = symbol
              isPresented = false
            } label: {
              Image(systemName: symbol)
                .imageScale(.large)
                .frame(width: 30, height: 30)
                .background(
                  symbol == systemImage ? Color.accentColor.opacity(0.18) : Color.clear,
                  in: .rect(cornerRadius: 6),
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(symbol)
            .accessibilityAddTraits(symbol == systemImage ? [.isSelected] : [])
            .help(symbol)
          }
        }
        .padding(.vertical, 2)
      }
      .frame(height: 150)

      Divider()

      Button("Open SF Symbols") {
        openSFSymbolsReference()
      }
      .help("Browse every symbol in Apple's SF Symbols app.")
    }
    .padding(14)
    .frame(width: 320)
  }

  /// Launch Apple's SF Symbols app, falling back to the web reference when it
  /// isn't installed. No `LSApplicationQueriesSchemes` / entitlement needed on macOS.
  private func openSFSymbolsReference() {
    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.SFSymbols") {
      NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
    } else if let webURL = URL(string: "https://developer.apple.com/sf-symbols/") {
      NSWorkspace.shared.open(webURL)
    }
  }
}

/// Curated SF Symbols offered in the script icon picker grid. A hand-maintained
/// list is the production-safe approach — there is no public runtime API to
/// enumerate available symbols.
enum ScriptSymbolPresets {
  static let all: [String] = [
    "terminal", "terminal.fill", "play.fill", "stop.fill", "hammer.fill",
    "shippingbox.fill", "doc.text.fill", "sparkles", "bolt.fill", "flame.fill",
    "wand.and.stars", "wrench.and.screwdriver.fill", "checkmark.circle.fill",
    "xmark.circle.fill", "exclamationmark.triangle.fill", "ladybug.fill",
    "clock.fill", "repeat", "arrow.clockwise", "folder.fill", "archivebox.fill",
    "paperplane.fill", "cloud.fill", "tray.and.arrow.down.fill",
    "tray.and.arrow.up.fill", "icloud.and.arrow.up.fill", "square.and.arrow.up.fill",
    "arrow.triangle.2.circlepath", "folder.badge.plus", "doc.badge.plus",
  ]
}
