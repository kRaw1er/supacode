import AppKit
import SwiftUI

/// The collapsed-gap expander. Renders a full-width bar that reveals hidden
/// unchanged lines **incrementally** (Phase 7): a tap dispatches the expand action
/// keyed by the gap's `GapKey` (Phase 1 S13) with a step + direction from OUR
/// granularity ladder (`ExpansionState.Step` — ±20 / ±100 / whole; C2, NOT a pierre
/// constant). The reducer mutates `ExpansionState` and reads only the newly-revealed
/// blob slice; the viewport does the O(log n) `tree.insert`. Static, so a recycled
/// host accepts an identity swap.
@MainActor
final class ExpanderWidget: DiffWidget {
  struct Model: Equatable {
    var gap: GapKey
    var hiddenCount: Int
  }

  let key: WidgetKey
  var model: Model
  private unowned let coalescer: LayoutCoalescer
  private let onExpand: (GapKey, ExpansionState.Step, ExpansionState.Direction) -> Void

  /// Matches the tree's reserved gap height (`ChunkLayoutMetrics.expanderHeight`)
  /// so the estimate the builder reserves and the widget's self-estimate agree.
  var estimatedHeight: CGFloat { ChunkLayoutMetrics.production.expanderHeight }

  init(
    key: WidgetKey,
    model: Model,
    coalescer: LayoutCoalescer,
    onExpand: @escaping (GapKey, ExpansionState.Step, ExpansionState.Direction) -> Void = { _, _, _ in }
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
    return ExpanderView(hiddenCount: model.hiddenCount) { step, direction in
      expand(gap, step, direction)
    }
    .onGeometryChange(for: CGSize.self) {
      $0.size
    } action: { size in
      reporter.report(width: size.width, height: size.height)
    }
  }
}

/// The full-width expander bar: reveal-up / reveal-all / reveal-down. Reveal-up
/// (`.up` → `fromStart`) and reveal-down (`.down` → `fromEnd`) grow the region by
/// the fine step; the central action reveals the whole gap. The coarse (±100) rung
/// exists in `ExpansionState.Step` for a future affordance; the tests cover all
/// three rungs at the model level.
private struct ExpanderView: View {
  let hiddenCount: Int
  let onExpand: (ExpansionState.Step, ExpansionState.Direction) -> Void

  private var fineCount: Int { ExpansionState.Step.fine.lineCount ?? 20 }

  var body: some View {
    HStack(spacing: 4) {
      Button {
        onExpand(.fine, .up)
      } label: {
        Image(systemName: "chevron.up")
          .font(.caption)
      }
      .help("Reveal \(fineCount) more lines above (e)")
      .accessibilityLabel("Reveal \(fineCount) lines above")

      Button {
        onExpand(.whole, .both)
      } label: {
        Label(label, systemImage: "arrow.up.and.down.text.horizontal")
          .font(.caption)
          .frame(maxWidth: .infinity)
      }
      .help("Reveal all \(hiddenCount) hidden line\(hiddenCount == 1 ? "" : "s") (⇧E)")
      .accessibilityLabel("Reveal all \(hiddenCount) hidden lines")

      Button {
        onExpand(.fine, .down)
      } label: {
        Image(systemName: "chevron.down")
          .font(.caption)
      }
      .help("Reveal \(fineCount) more lines below")
      .accessibilityLabel("Reveal \(fineCount) lines below")
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 8)
    .frame(maxWidth: .infinity, minHeight: ChunkLayoutMetrics.production.expanderHeight)
    .background(.quaternary.opacity(0.4))
  }

  private var label: String {
    "Expand \(hiddenCount) line\(hiddenCount == 1 ? "" : "s")"
  }
}
