import AppKit
import ComposableArchitecture
import SwiftUI

/// Resolves a tree `.widget` leaf's scalar payload into the concrete `DiffWidget`
/// MODEL the Phase-6 harness hosts (`WidgetHostChunkView.mount`). This is the
/// production factory the Phase-13 seam swap wires into `DiffViewportController`:
/// the tree stays "scalars only", and the rich content (a `FileChange`, the
/// review `comments`, the expand / edit callbacks) is a side context injected by
/// `DiffViewerRepresentable`. A default-constructed resolver still renders every
/// widget from its payload alone (degraded — a header shows the raw path), so the
/// headless controller tests that apply a tree without a representable keep
/// rendering real hosts.
///
/// Edge diffs (⚠️ notes 1 / 2) route here too: an image-extension binary →
/// `ImageCompareWidget`; a `.conflict` file → `ConflictWidget`. The image
/// blob-bytes read and the conflict accept-WRITE are gated follow-ups (documented
/// in the PR body); the widgets render and parse today.
@MainActor
struct DiffWidgetResolver {
  var file: FileChange?
  var hunks: [DiffHunk] = []
  var comments: [ReviewComment] = []
  var viewportHeight: CGFloat = 600
  /// File-level "Comment on file" affordance. Off by default (viewport-side comment
  /// creation is a gated follow-up — see the PR body); editing an existing thread
  /// still works through the comment widget's `onEdit`.
  var canCommentOnFile = false
  var onCommentOnFile: (_ fileID: FileID) -> Void = { _ in }
  var onExpand: (GapKey, ExpansionState.Step, ExpansionState.Direction) -> Void = { _, _, _ in }
  var onEditComment: (UUID) -> Void = { _ in }
  var onResolveConflictInEditor: () -> Void = {}
  /// The live inline-composer store for an anchor being composed / edited, or `nil`
  /// when this anchor's thread is in display mode. Injected by the viewport seam
  /// (`DiffViewerRepresentable.makeResolver`) from the reducer's presented
  /// `\.composer` child store, so opening the composer flips the widget to `.editing`
  /// (pierre/GitHub inline comment — NO modal sheet).
  var composerStore: (UUID) -> StoreOf<CommentComposer>? = { _ in nil }

  func resolve(_ widget: Widget, coalescer: LayoutCoalescer) -> (any DiffWidget)? {
    switch widget.payload {
    case .fileHeader(let fileID):
      let model =
        file.map { FileHeaderWidget.Model.make(from: $0, canCommentOnFile: canCommentOnFile) }
        ?? FileHeaderWidget.Model(path: fileID, statusText: "", canCommentOnFile: canCommentOnFile)
      return FileHeaderWidget(
        key: widget.key, model: model, coalescer: coalescer,
        onCommentOnFile: { onCommentOnFile(fileID) })

    case .hunkHeader(_, let text):
      return HunkHeaderWidget(key: widget.key, text: text, coalescer: coalescer)

    case .expander(_, _, let hidden):
      guard case .expander(let gap) = widget.key else { return nil }
      return ExpanderWidget(
        key: widget.key, model: .init(gap: gap, hiddenCount: hidden), coalescer: coalescer, onExpand: onExpand)

    case .placeholder(let placeholder):
      switch placeholder {
      case .imageCompare:
        // Blob-bytes read is a gated follow-up (⚠️ note 1): nil/nil ⇒ the widget
        // renders the binary summary, and the widget is referenced in production.
        let model = ImageCompareModel.make(beforeData: nil, afterData: nil)
        return ImageCompareWidget(key: widget.key, model: model, coalescer: coalescer)
      case .conflict:
        let region = ConflictRegion.parse(hunks.flatMap(\.lines), straddlesHunks: hunks.count > 1)
        return ConflictWidget(
          key: widget.key, region: region, coalescer: coalescer,
          onResolve: { _ in },  // accept-WRITE-to-disk is a gated follow-up (§442)
          onResolveInEditor: onResolveConflictInEditor)
      default:
        return FilePlaceholderWidget(key: widget.key, placeholder: placeholder, coalescer: coalescer)
      }

    case .commentThread(let anchorID):
      let thread = comments.filter { $0.id == anchorID }
      return CommentThreadWidget(
        key: widget.key, model: CommentThreadModel(anchorID: anchorID, comments: thread),
        viewportHeight: viewportHeight, coalescer: coalescer, composerStore: composerStore(anchorID),
        onEdit: onEditComment)

    case .plainFallback(let lineNumber, let text):
      return PlainFallbackWidget(key: widget.key, lineNumber: lineNumber, text: text, coalescer: coalescer)

    case .noNewlineMarker:
      // The builder folds no-newline markers into the `LineRowView` projection, so a
      // standalone marker widget is never emitted; nothing to host.
      return nil
    }
  }
}

// MARK: - Small widgets with no dedicated model file

/// The per-hunk `@@ … @@` separator header hosted like every `.widget` chunk.
/// Static content, so a recycled host accepts an identity swap.
@MainActor
final class HunkHeaderWidget: DiffWidget {
  let key: WidgetKey
  let text: String
  private unowned let coalescer: LayoutCoalescer

  init(key: WidgetKey, text: String, coalescer: LayoutCoalescer) {
    self.key = key
    self.text = text
    self.coalescer = coalescer
  }

  var estimatedHeight: CGFloat { ChunkLayoutMetrics.production.separatorHeight }

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
    Text(text)
      .font(.caption.monospaced())
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.middle)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .frame(minHeight: ChunkLayoutMetrics.production.separatorHeight)
      .background(.quaternary.opacity(0.25))
      .onGeometryChange(for: CGSize.self) {
        $0.size
      } action: { size in
        reporter.report(width: size.width, height: size.height)
      }
  }
}

/// A whole-file placeholder (binary / mode / deleted / submodule / empty) hosted
/// like every `.widget` chunk.
@MainActor
final class FilePlaceholderWidget: DiffWidget {
  let key: WidgetKey
  let placeholder: FilePlaceholder
  private unowned let coalescer: LayoutCoalescer

  init(key: WidgetKey, placeholder: FilePlaceholder, coalescer: LayoutCoalescer) {
    self.key = key
    self.placeholder = placeholder
    self.coalescer = coalescer
  }

  var estimatedHeight: CGFloat { ChunkLayoutMetrics.production.placeholderHeight }

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
    Label(Self.text(for: placeholder), systemImage: "doc")
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .frame(minHeight: ChunkLayoutMetrics.production.placeholderHeight)
      .onGeometryChange(for: CGSize.self) {
        $0.size
      } action: { size in
        reporter.report(width: size.width, height: size.height)
      }
  }

  static func text(for placeholder: FilePlaceholder) -> String {
    switch placeholder {
    case .binaryFile: "Binary file not shown"
    case .deletedFile: "File deleted"
    case .addedEmpty: "New empty file"
    case .noChanges: "No changes"
    case .modeChangeOnly(let oldMode, let newMode):
      oldMode.isEmpty || newMode.isEmpty ? "File mode changed" : "File mode changed \(oldMode) → \(newMode)"
    case .submodule(let oldSHA, let newSHA):
      oldSHA.isEmpty || newSHA.isEmpty ? "Submodule changed" : "Submodule \(oldSHA) → \(newSHA)"
    case .imageCompare: "Image file"
    case .conflict: "Merge conflict"
    }
  }
}

/// One plain, un-highlighted monospaced line for a large-file / long-line capped
/// file (no gutter substrate, no tint).
@MainActor
final class PlainFallbackWidget: DiffWidget {
  let key: WidgetKey
  let lineNumber: Int
  let text: String
  private unowned let coalescer: LayoutCoalescer

  init(key: WidgetKey, lineNumber: Int, text: String, coalescer: LayoutCoalescer) {
    self.key = key
    self.lineNumber = lineNumber
    self.text = text
    self.coalescer = coalescer
  }

  var estimatedHeight: CGFloat { ChunkLayoutMetrics.production.lineHeight }

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
    HStack(spacing: 8) {
      Text(String(lineNumber))
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
      Text(text)
        .font(.body.monospaced())
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .frame(minHeight: ChunkLayoutMetrics.production.lineHeight)
    .onGeometryChange(for: CGSize.self) {
      $0.size
    } action: { size in
      reporter.report(width: size.width, height: size.height)
    }
  }
}
