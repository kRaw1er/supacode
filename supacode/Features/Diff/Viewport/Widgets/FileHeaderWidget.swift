import AppKit
import SwiftUI

/// The per-file header widget: the file path + a status badge + a "Comment on
/// file" affordance + a trailing slot for future actions. Static content, so a
/// recycled host accepts an identity swap (`update` returns `true`).
/// `estimatedHeight = 44` (pierre `diffHeaderHeight`, brainstorm §378).
@MainActor
final class FileHeaderWidget: DiffWidget {
  /// The resolved-by-`WidgetKey` model. Scalars only — the rich model lives here,
  /// not on the tree chunk (D3).
  struct Model: Equatable {
    var path: String
    var statusText: String
    var canCommentOnFile: Bool

    init(path: String, statusText: String, canCommentOnFile: Bool = true) {
      self.path = path
      self.statusText = statusText
      self.canCommentOnFile = canCommentOnFile
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

/// The file-header row body (path, status badge, "Comment on file"). Layout-
/// agnostic; the parent host owns the width.
private struct FileHeaderView: View {
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
