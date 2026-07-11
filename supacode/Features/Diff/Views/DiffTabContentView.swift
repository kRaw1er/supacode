import ComposableArchitecture
import SwiftUI

/// Center diff tab content: a header (path + status + unified/split toggle), an
/// optional "no longer changed" stale banner, and the virtualized viewer. Reads
/// the per-file `DiffDocument` from `openDiffs[DiffDocumentKey(path, source)]`;
/// all mutations go through actions (`store_state_mutation_in_views`).
struct DiffTabContentView: View {
  @Bindable var store: StoreOf<DiffReviewFeature>
  let filePath: String
  /// Which diff this tab renders; scopes the `openDiffs` read, the comment
  /// composer, and the tab title so a working-tree tab and a base-branch tab of
  /// the same file stay distinct.
  let source: DiffSource

  /// The measured viewer width, fed to `SplitColumnLayout.effectiveMode` so a stored
  /// `.split` coerces to inline (unified) below the ~900pt breakpoint — view-only, the
  /// stored `diffViewMode` flag is untouched (widening restores split). Seeded at the
  /// breakpoint so the first frame (pre-measure) renders the stored mode, not a flash of
  /// inline. Read GeometryReader-free via `onGeometryChange`.
  @State private var availableWidth: CGFloat = SplitColumnLayout.inlineBreakpoint

  var body: some View {
    let document = store.openDiffs[DiffDocumentKey(path: filePath, source: source)]
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
      if let banner = document?.renderBannerKey {
        renderBanner(banner)
        Divider()
      }
      body(document: document)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      availableWidth = $0
    }
    .overlay(alignment: .center) {
      if store.keyboardHelpVisible {
        keyboardHelpOverlay
      }
    }
    .alert($store.scope(state: \.alert, action: \.alert))
    .confirmationDialog($store.scope(state: \.discardConfirm, action: \.discardConfirm))
    // The four "Diff" menu items (`DiffNavigationCommands`) route to the SAME nav the
    // single-letter keys drive: a menu pick sets a one-shot intent the viewport drains.
    // Enabled only while a diff is loaded here; token stays `nil` — the closures capture
    // only the store, and `FocusedAction` dedupes on `(isEnabled, token)`.
    .focusedSceneAction(\.diffNextChangeAction, enabled: isDiffLoaded(document)) {
      store.send(.diffMenuNav(.nextChange))
    }
    .focusedSceneAction(\.diffPrevChangeAction, enabled: isDiffLoaded(document)) {
      store.send(.diffMenuNav(.prevChange))
    }
    .focusedSceneAction(\.diffNextFileAction, enabled: isDiffLoaded(document)) {
      store.send(.diffMenuNav(.nextFile))
    }
    .focusedSceneAction(\.diffPrevFileAction, enabled: isDiffLoaded(document)) {
      store.send(.diffMenuNav(.prevFile))
    }
  }

  /// The menu-nav publishers are live only when this tab actually shows a loaded diff —
  /// during load / error the "Diff" menu items stay disabled (`@FocusedValue` resolves
  /// a disabled action rather than `nil`).
  private func isDiffLoaded(_ document: DiffDocument?) -> Bool {
    document?.loadState == .loaded
  }

  // MARK: - Keyboard help overlay

  /// The `?`-toggled keyboard-shortcuts cheat sheet (`store.keyboardHelpVisible`,
  /// flipped by `.diffShowKeyboardHelp`). A sheet-free centered panel over a dimmed
  /// scrim; dismisses on Esc (`onExitCommand`), a scrim tap, or its close button — all
  /// re-send `.diffShowKeyboardHelp` to toggle it back off.
  private var keyboardHelpOverlay: some View {
    ZStack {
      Button {
        store.send(.diffShowKeyboardHelp)
      } label: {
        Rectangle()
          .fill(.black.opacity(0.35))
          .ignoresSafeArea()
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss keyboard shortcuts")
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Label("Keyboard Shortcuts", systemImage: "keyboard")
            .font(.headline)
          Spacer(minLength: 24)
          Button {
            store.send(.diffShowKeyboardHelp)
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .help("Close (Esc)")
          .accessibilityLabel("Close keyboard shortcuts")
        }
        Divider()
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
          ForEach(Self.keyboardHelpRows, id: \.keys) { row in
            GridRow {
              Text(row.keys)
                .font(.callout.monospaced())
                .gridColumnAlignment(.leading)
              Text(row.label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            }
          }
        }
      }
      .padding(20)
      .frame(maxWidth: 360)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }
    .onExitCommand { store.send(.diffShowKeyboardHelp) }
    .transition(.opacity)
  }

  /// The rows shown in the `?` help overlay — the single-letter nav vocabulary
  /// `DiffKeyboardNav` maps, plus the send-batch chord.
  private static let keyboardHelpRows: [(keys: String, label: String)] = [
    ("j / k", "Move down / up one line"),
    ("n / p", "Next / previous change"),
    ("] / [", "Next / previous file"),
    ("o", "Expand the whole file"),
    ("e / ⇧E", "More / less context"),
    ("/", "Find in diff"),
    ("⌘↩", "Send review comments to the agent"),
    ("?", "Toggle this help"),
  ]

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
      Toggle(
        isOn: Binding(
          get: { store.ignoreWhitespace },
          set: { store.send(.ignoreWhitespaceToggled($0)) }
        )
      ) {
        Label("Ignore whitespace", systemImage: "pilcrow")
      }
      .toggleStyle(.button)
      .labelStyle(.iconOnly)
      .help("Ignore whitespace-only changes")
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

  /// The fully-changed-huge-file affordance — never a silent drop of highlighting /
  /// word-diff (`LargeFileRenderPolicy`).
  private func renderBanner(_ banner: LargeFileRenderPolicy.BannerKey) -> some View {
    Label(banner.headerText, systemImage: "gauge.with.dots.needle.33percent")
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
        Button("Retry") { store.send(.openFile(path: filePath, source: source)) }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .loaded:
      if let document {
        let key = DiffDocumentKey(path: filePath, source: source)
        // The presented inline-composer store, scoped to THIS tab only: a composer
        // whose draft belongs to another file's diff must not flip a widget here or
        // seed a transient editor in this tree.
        let composerBelongsHere =
          store.composer.map { $0.draft.filePath == filePath && $0.draft.source == source } ?? false
        let tabComments: [ReviewComment] = store.comments.filter { $0.filePath == filePath && $0.source == source }
        DiffViewerRepresentable(
          file: document.file,
          hunks: document.hunks,
          comments: tabComments,
          // View-only ~900pt breakpoint: a stored `.split` renders inline below it
          // (`SplitColumnLayout.effectiveMode`); the stored flag stays put so widening
          // restores split. Unified is never coerced.
          mode: SplitColumnLayout.effectiveMode(stored: store.diffViewMode, availableWidth: availableWidth),
          generation: document.generation,
          filePath: filePath,
          source: source,
          expansion: document.expansion,
          revealed: document.revealed,
          composerStore: composerBelongsHere ? $store.scope(state: \.composer, action: \.composer).wrappedValue : nil,
          composerDraft: composerBelongsHere ? store.composer?.draft : nil,
          wordDiffEnabled: !document.wordDiffDisabled,
          oldStyleRuns: document.oldStyleRuns,
          newStyleRuns: document.newStyleRuns,
          syntaxVersion: document.styleRunsVersion,
          oldBlob: document.oldBlob,
          newBlob: document.newBlob,
          highlightingDisabled: document.highlightingDisabled,
          pendingNavCommand: store.pendingNavCommand,
          send: { store.send($0) },
          onNavCommandConsumed: { store.send(.diffNavCommandConsumed) },
          onVisibleRangeChanged: { window in
            store.send(.highlightVisibleRangeChanged(key: key, window: window))
          },
          onExpandGap: { gap, step, direction in
            store.send(.expandGap(key: key, gap: gap, step: step, direction: direction))
          },
          onEditComment: { id in store.send(.editComment(id: id)) },
          collapsedThreads: store.collapsedCommentThreads.intersection(tabComments.map(\.id)),
          onToggleCommentThreadCollapsed: { id in store.send(.toggleCommentThreadCollapsed(anchorID: id)) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  // MARK: - Content

  private func title(document: DiffDocument?) -> String {
    let base: String
    if let file = document?.file {
      if file.status == .renamed, let old = file.oldPath, let new = file.newPath {
        base = "\(old) → \(new)"
      } else {
        base = file.newPath ?? file.oldPath ?? filePath
      }
    } else {
      base = filePath
    }
    // Base-branch tabs disambiguate: "file.swift — vs main".
    guard let name = source.displayName else { return base }
    return "\(base) — vs \(name)"
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
