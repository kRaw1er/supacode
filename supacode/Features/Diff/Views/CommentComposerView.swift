import ComposableArchitecture
import SwiftUI

/// Inline editor for a single review comment. Binds through `.composer(...)`
/// actions (no direct `store.*` mutation) and exposes Save (⌘↩) / Cancel (⎋),
/// plus Delete when editing an existing thread.
struct CommentComposerView: View {
  @Bindable var store: StoreOf<CommentComposer>

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Image(systemName: "text.bubble")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(rangeLabel)
          .font(.callout.monospaced())
          .foregroundStyle(.secondary)
        if store.draft.orphaned {
          Label("Orphaned", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .labelStyle(.titleAndIcon)
        }
        Spacer()
      }

      TextEditor(text: $store.draft.body)
        .font(.body)
        .frame(minWidth: 320, minHeight: 120)
        .overlay(alignment: .topLeading) {
          if store.draft.body.isEmpty {
            Text("Describe what the agent should change…")
              .font(.body)
              .foregroundStyle(.tertiary)
              .padding(.horizontal, 5)
              .padding(.vertical, 8)
              .allowsHitTesting(false)
          }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

      HStack {
        if store.isEditing {
          Button(role: .destructive) {
            store.send(.deleteTapped)
          } label: {
            Label("Delete", systemImage: "trash")
          }
          .help("Delete this comment")
        }
        Spacer()
        Button("Cancel") {
          store.send(.cancelTapped)
        }
        .keyboardShortcut(.cancelAction)
        .help("Discard this comment (⎋)")

        Button("Save") {
          store.send(.saveTapped)
        }
        .keyboardShortcut(.return, modifiers: .command)
        .buttonStyle(.borderedProminent)
        .disabled(!store.canSave)
        .help("Save this comment (⌘↩)")
      }
    }
    .padding(16)
    .frame(minWidth: 360)
  }

  private var rangeLabel: String {
    let side = store.draft.side == .old ? "-L" : "L"
    return store.draft.startLine == store.draft.endLine
      ? "\(side)\(store.draft.startLine)"
      : "\(side)\(store.draft.startLine)–\(store.draft.endLine)"
  }
}
