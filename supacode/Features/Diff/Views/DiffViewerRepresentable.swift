import AppKit
import SupacodeSettingsShared
import SwiftUI

/// SwiftUI bridge to the AppKit `DiffTableController`. Mirrors the
/// `CommandPalettePanelHost` idiom: the coordinator owns the AppKit object, the
/// representable re-enters through `updateNSView`, and teardown happens in
/// `dismantleNSView`. `revision` is bumped by the reducer on every live re-diff;
/// a change in `revision`/`mode` (not row identity) is what triggers a re-apply
/// with scroll preserved.
///
/// Phase 4: the coordinator also drives syntax highlighting — on every viewport
/// change it asks the background `SyntaxHighlighter` actor for the visible lines'
/// spans and applies them progressively (plain first, colors when they arrive).
struct DiffViewerRepresentable: NSViewRepresentable {
  let rows: [DiffRow]
  let mode: DiffViewMode
  let revision: Int
  /// New-side path of the file (used to resolve the grammar + read source).
  var filePath: String = ""
  /// Worktree root the file lives under; `nil` disables highlighting.
  var workingDirectory: URL?
  var onExpandGap: (Int) -> Void = { _ in }
  /// Handed the controller once so Phase 5 can reach the geometry API.
  var onController: (DiffTableController) -> Void = { _ in }
  var onVisibleRangeChanged: (Range<Int>) -> Void = { _ in }
  /// Gutter "+"/drag resolved a range → open the composer (Phase 5).
  var onOpenComposer:
    (_ side: DiffSide, _ startLine: Int, _ endLine: Int, _ snippet: String, _ contextBefore: String) -> Void = {
      _, _, _, _, _ in
    }
  /// An inline comment thread row was clicked → open it to edit (Phase 5).
  var onCommentTap: (UUID) -> Void = { _ in }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSScrollView {
    let controller = context.coordinator.controller
    controller.onExpandGap = { [coordinator = context.coordinator] anchor in
      coordinator.onExpandGap(anchor)
    }
    controller.onVisibleRangeChanged = { [coordinator = context.coordinator] range in
      coordinator.handleVisibleRange(range)
    }
    controller.onOpenComposer = { [coordinator = context.coordinator] side, start, end, snippet, context in
      coordinator.onOpenComposer(side, start, end, snippet, context)
    }
    controller.onCommentTap = { [coordinator = context.coordinator] id in
      coordinator.onCommentTap(id)
    }
    context.coordinator.onExpandGap = onExpandGap
    context.coordinator.onVisibleRangeChanged = onVisibleRangeChanged
    context.coordinator.onOpenComposer = onOpenComposer
    context.coordinator.onCommentTap = onCommentTap
    context.coordinator.update(filePath: filePath, workingDirectory: workingDirectory, revision: revision)
    onController(controller)
    controller.apply(rows: rows, mode: mode, scrollPreserving: false)
    context.coordinator.lastRevision = revision
    context.coordinator.lastMode = mode
    context.coordinator.scheduleHighlight()
    return controller.scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    // Refresh the callbacks so the latest closures (capturing fresh SwiftUI
    // state) are used, then apply only when something actually changed.
    context.coordinator.onExpandGap = onExpandGap
    context.coordinator.onVisibleRangeChanged = onVisibleRangeChanged
    context.coordinator.onOpenComposer = onOpenComposer
    context.coordinator.onCommentTap = onCommentTap
    let coordinator = context.coordinator
    coordinator.update(filePath: filePath, workingDirectory: workingDirectory, revision: revision)
    guard coordinator.lastRevision != revision || coordinator.lastMode != mode else { return }
    let preserve = coordinator.lastMode == mode  // mode switch reloads; re-diff preserves scroll.
    coordinator.lastRevision = revision
    coordinator.lastMode = mode
    coordinator.controller.apply(rows: rows, mode: mode, scrollPreserving: preserve)
    coordinator.scheduleHighlight()
  }

  static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
    coordinator.tearDown()
  }

  @MainActor
  final class Coordinator {
    private static let logger = SupaLogger("DiffViewer")
    let controller = DiffTableController()
    var onExpandGap: (Int) -> Void = { _ in }
    var onVisibleRangeChanged: (Range<Int>) -> Void = { _ in }
    var onOpenComposer: (DiffSide, Int, Int, String, String) -> Void = { _, _, _, _, _ in }
    var onCommentTap: (UUID) -> Void = { _ in }
    var lastRevision = -1
    var lastMode: DiffViewMode = .unified

    private let highlighter = SyntaxHighlighter.shared
    private var highlightTask: Task<Void, Never>?
    private var filePath = ""
    private var workingDirectory: URL?
    private var revision = -1
    /// Source cache keyed by (path, revision) so a scroll doesn't re-read the file.
    private var cachedSourceKey: String?
    private var cachedSource: String?
    private var cachedHash = 0

    func update(filePath: String, workingDirectory: URL?, revision: Int) {
      if self.filePath != filePath {
        let previous = self.filePath
        if !previous.isEmpty {
          Task { [highlighter] in await highlighter.cancel(fileKey: previous) }
        }
      }
      self.filePath = filePath
      self.workingDirectory = workingDirectory
      self.revision = revision
    }

    /// Forwards the viewport change to SwiftUI and (re)issues a highlight request
    /// scoped to the freshly visible lines.
    func handleVisibleRange(_ range: Range<Int>) {
      onVisibleRangeChanged(range)
      scheduleHighlight()
    }

    /// Kicks off a viewport-scoped, cancellable highlight pass. Renders plain when
    /// there is no bundled grammar / no working directory / nothing visible.
    func scheduleHighlight() {
      highlightTask?.cancel()
      // No working directory or nothing visible yet is a legitimate plain render —
      // stay silent. Likewise a path with no bundled grammar (a plain-text
      // extension) is expected plain text, not a defect: clear and return quietly.
      // Only a *resolved* grammar that then yields zero highlights is surfaced.
      guard let workingDirectory, let visibleLines = controller.visibleNewLineRange() else {
        controller.clearSyntax()
        return
      }
      guard let grammar = GrammarRegistry.grammar(forPath: filePath) else {
        controller.clearSyntax()
        return
      }

      let cacheKey = "\(revision)\u{1}\(filePath)"
      let reusedSource = cachedSourceKey == cacheKey ? cachedSource : nil
      let fileURL = workingDirectory.appending(path: filePath)
      let language = grammar.language
      let queryName = grammar.queryName
      let fileKey = filePath
      let highlighter = highlighter
      let controller = controller

      highlightTask = Task { [weak self] in
        let source: String
        let hash: Int
        if let reusedSource {
          source = reusedSource
          hash = self?.cachedHash ?? reusedSource.hashValue
        } else {
          guard let loaded = await Self.readSource(fileURL) else { return }
          source = loaded
          hash = loaded.hashValue
          await MainActor.run { self?.cache(source: source, hash: hash, key: cacheKey) }
        }
        if Task.isCancelled { return }
        let lineHighlights = await highlighter.highlights(
          SyntaxHighlighter.Request(
            fileKey: fileKey,
            contentHash: hash,
            source: source,
            language: language,
            queryName: queryName,
            visibleLines: visibleLines
          )
        )
        if Task.isCancelled { return }
        // A grammar was resolved for this path yet the engine returned nothing for
        // the visible window: surface it (missing query, out-of-range grammar ABI,
        // or the wrong-blob defect Phase 4 fixes) instead of silently rendering plain.
        if lineHighlights.isEmpty {
          Self.logger.error(
            "resolved grammar '\(queryName)' produced no highlights for '\(fileKey)' over lines "
              + "\(visibleLines.lowerBound)..<\(visibleLines.upperBound) — plain-text fallback "
              + "(missing query, grammar ABI out of range, or stale TreeSitterGrammars build?)"
          )
        }
        var byLine: [Int: [SyntaxHighlighter.HighlightSpan]] = [:]
        for lineHighlight in lineHighlights {
          byLine[lineHighlight.line] = lineHighlight.spans
        }
        await MainActor.run { controller.applySyntax(byLine) }
      }
    }

    private func cache(source: String, hash: Int, key: String) {
      cachedSource = source
      cachedHash = hash
      cachedSourceKey = key
    }

    /// Reads + UTF-8-decodes the file off the main actor. `nil` on any failure
    /// (missing file / binary / non-UTF8) ⇒ the row stays plain.
    private static func readSource(_ url: URL) async -> String? {
      await Task.detached(priority: .userInitiated) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
      }.value
    }

    func tearDown() {
      highlightTask?.cancel()
      let fileKey = filePath
      if !fileKey.isEmpty {
        Task { [highlighter] in await highlighter.cancel(fileKey: fileKey) }
      }
      controller.onExpandGap = nil
      controller.onVisibleRangeChanged = nil
    }
  }
}
