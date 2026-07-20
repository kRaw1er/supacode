import AppKit
import SwiftUI

/// The per-file header widget: the file path + a status badge + a "Comment on
/// file" affordance + a trailing slot for future actions. Static content, so a
/// recycled host accepts an identity swap (`update` returns `true`).
/// `estimatedHeight = 44` (pierre `diffHeaderHeight`, brainstorm §378).
@MainActor
final class FileHeaderWidget: DiffWidget {
  /// The resolved-by-`WidgetKey` model. Scalars only — the rich model lives here,
  /// not on the tree chunk (D3). `path` already carries the rename arrow
  /// (`old → new`); `addedLines` / `removedLines` mirror pierre's
  /// `createFileHeaderElement` +/- counts. The Phase-10 sticky overlay renders the
  /// **same** `Model`, so the pinned copy is a faithful 1:1 mirror.
  struct Model: Equatable {
    var path: String
    var statusText: String
    var addedLines: Int
    var removedLines: Int
    var canCommentOnFile: Bool

    init(
      path: String,
      statusText: String,
      addedLines: Int = 0,
      removedLines: Int = 0,
      canCommentOnFile: Bool = true
    ) {
      self.path = path
      self.statusText = statusText
      self.addedLines = addedLines
      self.removedLines = removedLines
      self.canCommentOnFile = canCommentOnFile
    }

    /// Build the header model from a `FileChange` — the single canonical mapping
    /// shared by the in-flow header widget AND the Phase-10 sticky overlay, so the
    /// two never drift (ports pierre `createFileHeaderElement`: name / rename arrow /
    /// +/- counts).
    static func make(from file: FileChange, canCommentOnFile: Bool = true) -> Model {
      let path: String
      if file.status == .renamed, let old = file.oldPath, let new = file.newPath, old != new {
        path = "\(old) → \(new)"
      } else {
        path = file.newPath ?? file.oldPath ?? ""
      }
      return Model(
        path: path,
        statusText: Self.statusText(for: file.status),
        addedLines: file.addedLines,
        removedLines: file.removedLines,
        canCommentOnFile: canCommentOnFile
      )
    }

    /// A non-interactive copy for the pinned sticky header (a static header renders
    /// no buttons → no tooltip obligation; the in-flow header keeps its affordance).
    var staticMirror: Model {
      var copy = self
      copy.canCommentOnFile = false
      return copy
    }

    private static func statusText(for status: FileStatus) -> String {
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

  let key: WidgetKey
  var model: Model
  private unowned let coalescer: LayoutCoalescer
  private let onCommentOnFile: () -> Void

  var estimatedHeight: CGFloat { ChunkLayoutMetrics.production.diffHeaderHeight }

  init(key: WidgetKey, model: Model, coalescer: LayoutCoalescer, onCommentOnFile: @escaping () -> Void = {}) {
    self.key = key
    self.model = model
    self.coalescer = coalescer
    self.onCommentOnFile = onCommentOnFile
  }

  func makeHostView(reporter: HeightReporter) -> NSView {
    let host = NSHostingView(rootView: AnyView(content(reporter: reporter)))
    host.sizingOptions = []
    return host
  }

  func update(hostView: NSView, width: CGFloat) -> Bool {
    guard let hosting = hostView as? NSHostingView<AnyView> else { return false }
    hosting.rootView = AnyView(content(reporter: HeightReporter(key: key, coalescer: coalescer)))
    return true
  }

  private func content(reporter: HeightReporter) -> some View {
    FileHeaderView(model: model, onCommentOnFile: onCommentOnFile)
      .onGeometryChange(for: CGSize.self) {
        $0.size
      } action: { size in
        reporter.report(width: size.width, height: size.height)
      }
  }
}

/// The file-header row body (path, status badge, +/- counts, "Comment on file").
/// Layout-agnostic; the parent host owns the width. Internal (not `private`) so the
/// Phase-10 sticky overlay renders the identical body from the same `Model` (a
/// pixel-faithful pinned mirror).
struct FileHeaderView: View {
  let model: FileHeaderWidget.Model
  let onCommentOnFile: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "doc.text")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(model.path)
        .font(.callout.monospaced())
        .lineLimit(1)
        .truncationMode(.middle)
      Text(model.statusText)
        .font(.caption2)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
        .foregroundStyle(.secondary)
      if model.addedLines > 0 || model.removedLines > 0 {
        HStack(spacing: 4) {
          Text("+\(model.addedLines)").foregroundStyle(.green)
          Text("−\(model.removedLines)").foregroundStyle(.red)
        }
        .font(.caption.monospaced())
        .help("\(model.addedLines) added, \(model.removedLines) removed")
        .accessibilityLabel("\(model.addedLines) added, \(model.removedLines) removed")
      }
      Spacer(minLength: 8)
      if model.canCommentOnFile {
        Button(action: onCommentOnFile) {
          Image(systemName: "text.bubble")
        }
        .buttonStyle(.borderless)
        .help("Comment on this file")
        .accessibilityLabel("Comment on this file")
      }
    }
    .padding(.horizontal, 12)
    .frame(minHeight: ChunkLayoutMetrics.production.diffHeaderHeight)
  }
}

/// The pinned file-header body rendered into the Phase-10 `StickyHeaderOverlay`
/// floating subview. A thin wrapper over the **same** `FileHeaderView` + `Model` the
/// in-flow header uses, so the pinned copy is pixel-identical (minus interactive
/// affordances — a static header carries no buttons). A `.bar` material backing
/// keeps scrolled content from bleeding through.
struct StickyFileHeaderView: View {
  let model: FileHeaderWidget.Model?

  var body: some View {
    Group {
      if let model {
        FileHeaderView(model: model.staticMirror, onCommentOnFile: {})
          .frame(maxWidth: .infinity, alignment: .leading)
          .frame(height: ChunkLayoutMetrics.production.diffHeaderHeight)
          .background(.bar)
          .overlay(alignment: .bottom) { Divider() }
      } else {
        Color.clear
      }
    }
    .accessibilityHidden(true)
  }
}
