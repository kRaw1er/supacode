import ComposableArchitecture
import SwiftUI

/// Center diff tab content: a header (path + status + unified/split toggle), an
/// optional "no longer changed" stale banner, and the virtualized viewer. Reads
/// the per-file `DiffDocument` from `DiffReviewFeature.State.openDiffs[filePath]`;
/// all mutations go through actions (`store_state_mutation_in_views`).
struct DiffTabContentView: View {
  @Bindable var store: StoreOf<DiffReviewFeature>
  let filePath: String

  var body: some View {
    let document = store.openDiffs[filePath]
    VStack(spacing: 0) {
      header(document: document)
      Divider()
      if let message = store.repositoryOperation.bannerMessage {
        DiffOperationBanner(message: message)
        Divider()
      }
      if document?.isStale == true {
        staleBanner
        Divider()
      }
      body(document: document)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .sheet(item: $store.scope(state: \.composer, action: \.composer)) { composerStore in
      CommentComposerView(store: composerStore)
    }
    .alert($store.scope(state: \.alert, action: \.alert))
    .confirmationDialog($store.scope(state: \.discardConfirm, action: \.discardConfirm))
  }

  // MARK: - Header

  @ViewBuilder
  private func header(document: DiffDocument?) -> some View {
    HStack(spacing: 8) {
      if let status = document?.file.status {
        Image(systemName: Self.symbol(status))
          .foregroundStyle(Self.tint(status))
          .help(Self.statusLabel(status))
          .accessibilityHidden(true)
      }
      Text(title(document: document))
        .font(.callout.monospaced())
        .lineLimit(1)
        .truncationMode(.head)
      Spacer(minLength: 12)
      Picker(
        "View mode",
        selection: Binding(
          get: { store.diffViewMode },
          set: { store.send(.diffModeChanged($0)) }
        )
      ) {
        Text("Unified").tag(DiffViewMode.unified)
        Text("Split").tag(DiffViewMode.split)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
      .help("Toggle unified / split diff view")
      sendToAgentButton
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
  }

  @ViewBuilder
  private var sendToAgentButton: some View {
    let count = store.sendableCommentCount
    let oversize = ReviewPromptBuilder.build(Array(store.comments))?.isOversize == true
    HStack(spacing: 6) {
      if oversize {
        Label("Large prompt", systemImage: "exclamationmark.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .labelStyle(.titleAndIcon)
          .help("The prompt is large but will still be sent.")
      }
      Button {
        store.send(.sendBatchToAgent)
      } label: {
        Label("Send to agent\(count > 0 ? " (\(count))" : "")", systemImage: "paperplane")
      }
      .keyboardShortcut(.return, modifiers: .command)
      .disabled(count == 0 || store.batchLocked)
      .help("Send \(count) review comment\(count == 1 ? "" : "s") to the agent's terminal (⌘↩)")
    }
  }

  private var staleBanner: some View {
    Label("No longer changed", systemImage: "clock.arrow.circlepath")
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 4)
      .background(.quaternary.opacity(0.4))
  }

  // MARK: - Body

  @ViewBuilder
  private func body(document: DiffDocument?) -> some View {
    switch document?.loadState {
    case .none, .loading:
      ProgressView("Loading diff…")
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .error(let error):
      ContentUnavailableView {
        Label("Couldn't Load Diff", systemImage: "exclamationmark.triangle")
      } description: {
        Text(Self.message(for: error))
      } actions: {
        Button("Retry") { store.send(.openFile(path: filePath)) }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded:
      if let document {
        DiffViewerRepresentable(
          rows: document.rows,
          mode: store.diffViewMode,
          revision: document.revision,
          filePath: filePath,
          workingDirectory: store.selectedWorktree?.workingDirectory,
          onExpandGap: { anchor in store.send(.expandGap(path: filePath, anchor: anchor)) },
          onOpenComposer: { side, start, end, snippet, context in
            store.send(
              .openCommentComposer(
                filePath: filePath, side: side, startLine: start, endLine: end,
                anchorSnippet: snippet, contextBefore: context))
          },
          onCommentTap: { id in store.send(.editComment(id: id)) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  // MARK: - Content

  private func title(document: DiffDocument?) -> String {
    guard let file = document?.file else { return filePath }
    if file.status == .renamed, let old = file.oldPath, let new = file.newPath {
      return "\(old) → \(new)"
    }
    return file.newPath ?? file.oldPath ?? filePath
  }

  private static func message(for error: DiffError) -> String {
    switch error {
    case .notARepository: "This directory is not a git repository."
    case .indexLocked: "Git is busy. Retry in a moment."
    case .baseRefUnresolved: "The base branch could not be resolved."
    case .libgit2: "An error occurred while reading the diff."
    }
  }

  private static func symbol(_ status: FileStatus) -> String {
    switch status {
    case .added, .untracked: "plus.circle.fill"
    case .modified: "pencil.circle.fill"
    case .deleted: "minus.circle.fill"
    case .renamed: "arrow.forward.circle.fill"
    case .copied: "doc.on.doc.fill"
    case .modeChanged: "gearshape.fill"
    case .binary: "doc.fill"
    case .submodule: "shippingbox.fill"
    case .conflicted: "exclamationmark.triangle.fill"
    }
  }

  private static func tint(_ status: FileStatus) -> Color {
    switch status {
    case .added, .untracked, .copied: .green
    case .modified, .modeChanged: .blue
    case .deleted: .red
    case .renamed, .conflicted: .orange
    case .binary, .submodule: .secondary
    }
  }

  private static func statusLabel(_ status: FileStatus) -> String {
    switch status {
    case .added: "Added"
    case .untracked: "Untracked"
    case .modified: "Modified"
    case .deleted: "Deleted"
    case .renamed: "Renamed"
    case .copied: "Copied"
    case .modeChanged: "Mode Changed"
    case .binary: "Binary"
    case .submodule: "Submodule"
    case .conflicted: "Conflicted"
    }
  }
}
