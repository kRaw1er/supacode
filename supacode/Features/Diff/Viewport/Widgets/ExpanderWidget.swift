import AppKit
import SwiftUI

/// Which way a collapsed gap expands. Direction is an ACTION parameter on the
/// expand dispatch, NOT part of the gap's identity (`GapKey` keys the gap;
/// Phase 1 S13) — so the same gap can expand up or down.
nonisolated enum ExpandDirection: Sendable, Equatable {
  case up
  case down
}

/// The collapsed-gap expander. A stub in Phase 6 — it renders a full-width
/// "Expand N lines" button and dispatches the Phase-7 expand action keyed by its
/// `GapKey` + a direction; Phase 7 wires the actual slice / insert. Static, so a
/// recycled host accepts an identity swap.
@MainActor
final class ExpanderWidget: DiffWidget {
  struct Model: Equatable {
    var gap: GapKey
    var hiddenCount: Int
  }

  let key: WidgetKey
  var model: Model
  private unowned let coalescer: LayoutCoalescer
  private let onExpand: (GapKey, ExpandDirection) -> Void

  /// Matches the tree's reserved gap height (`ChunkLayoutMetrics.expanderHeight`)
  /// so the estimate the builder reserves and the widget's self-estimate agree.
  var estimatedHeight: CGFloat { ChunkLayoutMetrics.production.expanderHeight }

  init(
    key: WidgetKey,
    model: Model,
    coalescer: LayoutCoalescer,
    onExpand: @escaping (GapKey, ExpandDirection) -> Void = { _, _ in }
  ) {
    self.key = key
    self.model = model
    self.coalescer = coalescer
    self.onExpand = onExpand
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
    let gap = model.gap
    let expand = onExpand
    return ExpanderView(hiddenCount: model.hiddenCount) { direction in
      expand(gap, direction)
    }
    .onGeometryChange(for: CGSize.self) {
      $0.size
    } action: { size in
      reporter.report(width: size.width, height: size.height)
    }
  }
}

private struct ExpanderView: View {
  let hiddenCount: Int
  let onExpand: (ExpandDirection) -> Void

  var body: some View {
    Button {
      onExpand(.down)
    } label: {
      Label(label, systemImage: "arrow.up.and.down.text.horizontal")
        .font(.caption)
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .help("Expand \(hiddenCount) hidden line\(hiddenCount == 1 ? "" : "s")")
    .frame(maxWidth: .infinity, minHeight: ChunkLayoutMetrics.production.expanderHeight)
    .background(.quaternary.opacity(0.4))
  }

  private var label: String {
    "Expand \(hiddenCount) line\(hiddenCount == 1 ? "" : "s")"
  }
}
