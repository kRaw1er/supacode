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
        ContentUnavailableView(
          "No Changes", systemImage: "checkmark.circle",
          description: Text("This worktree has no uncommitted changes."))
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

  @ViewBuilder
  private func fileList(updating: Bool) -> some View {
    List {
      if updating {
        Label("Updating…", systemImage: "arrow.triangle.2.circlepath")
          .font(.caption).foregroundStyle(.secondary)
          .listRowSeparator(.hidden)
      }
      ForEach(store.files) { file in
        FileChangeRow(file: file)
          .contentShape(Rectangle())
          .onTapGesture { store.send(.openFile(path: file.id)) }  // file.id = newPath ?? oldPath ?? ""
          .accessibilityAddTraits(.isButton)
          .accessibilityHint("Opens the diff in a new tab")
      }
    }
    .listStyle(.inset)
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
    return "\(lead), \(detail)\(unmerged)"
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
