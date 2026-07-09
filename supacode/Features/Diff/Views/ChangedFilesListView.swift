import ComposableArchitecture
import SwiftUI

/// The right inspector panel: the selected worktree's changed-file list, with
/// lifecycle / empty / unsupported / error states. A recycling `List` (never
/// `LazyVStack`) keeps giant change sets smooth. Row taps open a center diff tab
/// via `.openFile(path:)`.
struct ChangedFilesListView: View {
  @Bindable var store: StoreOf<DiffReviewFeature>

  var body: some View {
    VStack(spacing: 0) {
      if let message = store.repositoryOperation.bannerMessage {
        DiffOperationBanner(message: message)
        Divider()
      }
      content
    }
    .navigationTitle("Changes")
  }

  @ViewBuilder
  private var content: some View {
    Group {
      switch store.loadState {
      case .idle:
        ContentUnavailableView(
          "No Worktree Selected", systemImage: "sidebar.right",
          description: Text("Select a worktree to review its changes."))
      case .loading:
        ProgressView("Loading changes…").controlSize(.small)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .loaded, .refreshing:
        fileList(updating: store.loadState == .refreshing)
      case .empty:
        // Zero uncommitted changes: when a base section is present, render the
        // two-section list (a compact "no uncommitted changes" row + the base
        // section) rather than swallowing the base changes behind a full-screen
        // placeholder. Only a whole-panel empty (no base) keeps the placeholder.
        if store.baseSectionTitle != nil {
          fileList(updating: false)
        } else {
          ContentUnavailableView(
            "No Changes", systemImage: "checkmark.circle",
            description: Text("This worktree has no uncommitted changes."))
        }
      case .unsupported(.folder):
        ContentUnavailableView(
          "Not a Git Repository", systemImage: "folder",
          description: Text("Diff review is only available for git worktrees."))
      case .unsupported(.remote):
        ContentUnavailableView(
          "Remote Worktree", systemImage: "network",
          description: Text("Diff review isn't available for remote worktrees yet."))
      case .error(let error):
        ContentUnavailableView(
          "Couldn't Load Changes", systemImage: "exclamationmark.triangle",
          description: Text(Self.message(for: error)))
      }
    }
  }

  /// Two Orca-style sections: "Uncommitted" (working tree vs HEAD) and, when a
  /// base ref resolved, "vs `<base>`" (committed `merge-base..HEAD` changes).
  ///
  /// Wrapped in a `ScrollViewReader` so a scroll-spy move in the diff body
  /// (`.diffActiveFileChanged` → `store.activeFileID`) keeps the highlighted file
  /// visible in the inspector (body → list). The reverse link (list → body) is a tap
  /// sending `.diffJumpToFile`, which the diff viewport drains as a one-shot scroll.
  @ViewBuilder
  private func fileList(updating: Bool) -> some View {
    ScrollViewReader { proxy in
      List {
        Section {
          uncommittedSection(updating: updating)
        } header: {
          Text("Uncommitted")
        }
        if let title = store.baseSectionTitle, let baseRef = store.baseRef {
          Section {
            baseSection(baseRef: baseRef)
          } header: {
            Text(title)
          }
        }
      }
      .listStyle(.inset)
      .onChange(of: store.activeFileID) { _, id in
        guard let id else { return }
        withAnimation { proxy.scrollTo(id, anchor: .center) }
      }
    }
  }

  /// Working-tree (uncommitted) rows. Empty here only ever shows when a base
  /// section is present (the whole-panel empty case keeps its placeholder).
  @ViewBuilder
  private func uncommittedSection(updating: Bool) -> some View {
    if updating {
      Label("Updating…", systemImage: "arrow.triangle.2.circlepath")
        .font(.caption).foregroundStyle(.secondary)
        .listRowSeparator(.hidden)
    }
    if store.files.isEmpty {
      Label("No uncommitted changes", systemImage: "checkmark.circle")
        .font(.caption).foregroundStyle(.secondary)
        .listRowSeparator(.hidden)
        .accessibilityAddTraits(.isStaticText)
    } else {
      ForEach(store.files) { file in
        // file.id = newPath ?? oldPath ?? ""
        fileRow(file, source: .workingTree, axPrefix: nil, scrollSpy: true)
      }
    }
  }

  /// Base ("vs `<base>`") rows, driven by `baseLoadState`. `.empty` is the
  /// "up to date with `<base>`" state — never an error.
  @ViewBuilder
  private func baseSection(baseRef: String) -> some View {
    let baseName = DiffSource.baseBranch(ref: baseRef).displayName ?? "base"
    switch store.baseLoadState {
    case .loaded, .refreshing:
      if store.baseLoadState == .refreshing {
        Label("Updating…", systemImage: "arrow.triangle.2.circlepath")
          .font(.caption).foregroundStyle(.secondary)
          .listRowSeparator(.hidden)
      }
      ForEach(store.baseFiles) { file in
        fileRow(file, source: .baseBranch(ref: baseRef), axPrefix: "vs \(baseName)", scrollSpy: false)
      }
    case .empty:
      Label("Up to date with \(baseName)", systemImage: "checkmark.circle")
        .font(.caption).foregroundStyle(.secondary)
        .listRowSeparator(.hidden)
        .accessibilityAddTraits(.isStaticText)
    case .loading:
      ProgressView().controlSize(.small)
        .listRowSeparator(.hidden)
    case .error(let error):
      Label(Self.message(for: error), systemImage: "exclamationmark.triangle")
        .font(.caption).foregroundStyle(.secondary)
        .listRowSeparator(.hidden)
    case .idle, .unsupported:
      EmptyView()
    }
  }

  /// A tappable changed-file row shared by both sections. `axPrefix` prefixes the
  /// VoiceOver label so a file appearing in both sections is distinguishable.
  /// `scrollSpy` rows (the working-tree section, the diff viewport's scroll-spy
  /// target) highlight when active and, on tap, also record a jump-to-file intent.
  @ViewBuilder
  private func fileRow(_ file: FileChange, source: DiffSource, axPrefix: String?, scrollSpy: Bool) -> some View {
    FileChangeRow(file: file)
      .contentShape(Rectangle())
      .onTapGesture {
        store.send(.openFile(path: file.id, source: source))
        if scrollSpy { store.send(.diffJumpToFile(file.id)) }
      }
      .accessibilityAddTraits(.isButton)
      .accessibilityHint("Opens the diff in a new tab")
      .accessibilityLabel(axPrefix.map { "\($0): \(FileChangeRow.axLabel(file))" } ?? FileChangeRow.axLabel(file))
      .listRowBackground(rowHighlight(for: file, scrollSpy: scrollSpy))
  }

  /// The active-file selection highlight for a scroll-spy row (system selection
  /// color, subdued); `nil` for inactive / non-spy rows so the default backing shows.
  private func rowHighlight(for file: FileChange, scrollSpy: Bool) -> Color? {
    guard scrollSpy, store.activeFileID == file.id else { return nil }
    return Color(nsColor: .selectedContentBackgroundColor).opacity(0.35)
  }

  private static func message(for error: DiffError) -> String {
    switch error {
    case .notARepository: "This directory is not a git repository."
    case .indexLocked: "Git is busy. Retrying…"
    case .baseRefUnresolved: "The base branch could not be resolved."
    case .libgit2: "An error occurred while reading the diff."
    }
  }
}

private struct FileChangeRow: View {
  let file: FileChange

  var body: some View {
    HStack(spacing: 8) {
      StatusBadge(status: file.status)
      VStack(alignment: .leading, spacing: 1) {
        // Rename shows old → new; otherwise just the path.
        if file.status == .renamed {
          Text("\(Self.tail(file.oldPath)) → \(Self.tail(file.newPath))")
            .lineLimit(1).truncationMode(.head)
        } else {
          Text(Self.tail(file.newPath)).lineLimit(1).truncationMode(.head)
        }
        if let dir = Self.dir(file.newPath) {
          Text(dir).font(.caption2).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.head)
        }
      }
      Spacer(minLength: 8)
      if file.isSymlink {
        // The diff content is the symlink TARGET string, not file bytes — flag it so
        // the reader doesn't mistake the target path for the linked file's contents.
        Image(systemName: "link")
          .font(.caption)
          .foregroundStyle(.secondary)
          .help("Symlink — the diff shows the link target, not file contents")
          .accessibilityHidden(true)
      }
      if file.status == .conflicted {
        Text("unmerged")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.orange)
          .accessibilityHidden(true)
      }
      if file.isBinary {
        Text("bin").font(.caption2.monospaced()).foregroundStyle(.secondary)
      } else {
        HStack(spacing: 4) {
          Text("+\(file.addedLines)").foregroundStyle(.green)
          Text("−\(file.removedLines)").foregroundStyle(.red)
        }
        .font(.caption.monospaced())
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.axLabel(file))
  }

  /// The last path component of `path`, or "" when `path` is nil / empty.
  static func tail(_ path: String?) -> String {
    guard let path, !path.isEmpty else { return "" }
    return path.split(separator: "/").last.map(String.init) ?? path
  }

  /// The leading directory of `path`, or nil for a root-level file.
  static func dir(_ path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    let components = path.split(separator: "/")
    guard components.count > 1 else { return nil }
    return components.dropLast().joined(separator: "/")
  }

  static func axLabel(_ file: FileChange) -> String {
    // Renames read "old renamed to new"; everything else is "name, statusWord".
    let lead: String =
      file.status == .renamed
      ? "\(tail(file.oldPath)) renamed to \(tail(file.newPath))"
      : "\(tail(file.newPath)), \(StatusBadge.statusWord(file.status))"
    let detail = file.isBinary ? "binary" : "\(file.addedLines) added, \(file.removedLines) removed"
    let unmerged = file.status == .conflicted ? ", unmerged" : ""
    let symlink = file.isSymlink ? ", symlink" : ""
    return "\(lead), \(detail)\(unmerged)\(symlink)"
  }
}

/// System-styled banner shown above the changed-file list and inside the diff-tab
/// header while the repository is mid-merge / mid-rebase / etc. (1.8). Announces
/// itself to VoiceOver on appear so the state change is spoken.
struct DiffOperationBanner: View {
  let message: String

  var body: some View {
    Label(message, systemImage: "exclamationmark.triangle")
      .font(.caption)
      .foregroundStyle(.orange)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(.orange.opacity(0.12))
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isStaticText)
      .accessibilityLabel(message)
  }
}

/// System-color status glyph + letter (added/modified/deleted/renamed/binary/mode/submodule/conflicted).
private struct StatusBadge: View {
  let status: FileStatus

  var body: some View {
    Image(systemName: Self.symbol(status))
      .foregroundStyle(Self.tint(status))  // system colors only: green/red/blue/orange/secondary
      .font(.caption).frame(width: 16)
      .help(Self.label(status))
      // The row combines children into a single a11y element with a status-aware
      // label, so the glyph itself is redundant to VoiceOver.
      .accessibilityHidden(true)
  }

  static func symbol(_ status: FileStatus) -> String {
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

  static func tint(_ status: FileStatus) -> Color {
    switch status {
    case .added, .untracked, .copied: .green
    case .modified, .modeChanged: .blue
    case .deleted: .red
    case .renamed: .orange
    case .conflicted: .orange
    case .binary, .submodule: .secondary
    }
  }

  static func label(_ status: FileStatus) -> String {
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

  /// Lowercase status word for the VoiceOver label (spec-mandated wording).
  static func statusWord(_ status: FileStatus) -> String {
    switch status {
    case .added: "added"
    case .untracked: "untracked"
    case .modified: "modified"
    case .deleted: "deleted"
    case .renamed: "renamed"
    case .copied: "copied"
    case .modeChanged: "mode changed"
    case .binary: "binary"
    case .submodule: "submodule"
    case .conflicted: "conflicted"
    }
  }
}
