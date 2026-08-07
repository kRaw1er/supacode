import AppKit
import SwiftUI

/// The collapsed-gap expander — which is also the hunk **separator**: it carries
/// the `"@@ … @@"` header of the hunk it introduces, exactly like pierre's
/// `createSeparator` (the expand buttons live inside the separator). There is no
/// standalone header leaf, so when a gap is fully revealed the header goes away
/// with the bar instead of being stranded in contiguous code.
///
/// Renders a full-width bar that reveals hidden unchanged lines **incrementally**
/// (Phase 7): a tap dispatches the expand action keyed by the gap's `GapKey`
/// (Phase 1 S13) with a step + direction from OUR granularity ladder
/// (`ExpansionState.Step` — ±20 / ±100 / whole; C2, NOT a pierre constant). The
/// reducer mutates `ExpansionState` and reads only the newly-revealed blob slice;
/// the viewport does the O(log n) `tree.insert`. Static, so a recycled host accepts
/// an identity swap.
@MainActor
final class ExpanderWidget: DiffWidget {
  struct Model: Hashable {
    /// The blob-backed gap this bar reveals, or `nil` for an in-hunk collapsed run —
    /// those lines came in with the hunk, so the Phase-7 gap expand does not address
    /// them and the bar renders without buttons (pierre's non-expandable separator,
    /// `createSeparator` with `expandIndex == nil`).
    var gap: GapKey?
    var hiddenCount: Int
    /// The introduced hunk's raw `"@@ … @@"` header, or `nil` for the trailing gap
    /// / an in-hunk collapsed run (neither introduces a hunk).
    var header: String?
  }

  /// The hidden-line count is what the label renders and it changes under the same
  /// `WidgetKey` on a partial expand, so it has to be in the token.
  var modelToken: AnyHashable { AnyHashable(model) }

  let key: WidgetKey
  var model: Model
  private unowned let coalescer: LayoutCoalescer
  private let onExpand: (GapKey, ExpansionState.Step, ExpansionState.Direction) -> Void

  /// The SAME constant the builder reserves per collapsed gap
  /// (`ChunkLayoutMetrics.separatorHeight`), so the up-front estimate and the row the
  /// widget actually renders cannot disagree.
  var estimatedHeight: CGFloat { ChunkLayoutMetrics.production.separatorHeight }

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
    let onExpand = self.onExpand
    let expand = model.gap.map { gap in
      { (step: ExpansionState.Step, direction: ExpansionState.Direction) in
        onExpand(gap, step, direction)
      }
    }
    return ExpanderView(hiddenCount: model.hiddenCount, header: model.header, onExpand: expand)
      .onGeometryChange(for: CGSize.self) {
        $0.size
      } action: { size in
        reporter.report(width: size.width, height: size.height)
      }
  }
}

/// The full-width separator bar: reveal-up / reveal-all / reveal-down, followed by
/// the introduced hunk's `"@@ … @@"` header. Reveal-up (`.up` → `fromStart`) and
/// reveal-down (`.down` → `fromEnd`) grow the region by the fine step; the central
/// action reveals the whole gap. The coarse (±100) rung exists in
/// `ExpansionState.Step` for a future affordance; the tests cover all three rungs at
/// the model level.
///
/// `onExpand == nil` ⇒ the non-expandable bar (pierre `createSeparator` with
/// `expandIndex == nil`): the hidden-line count with no buttons. That is the in-hunk
/// collapsed run, whose lines arrived with the hunk and which the gap expand cannot
/// address — a button there would reveal the neighbouring gap's lines instead.
private struct ExpanderView: View {
  let hiddenCount: Int
  let header: String?
  let onExpand: ((ExpansionState.Step, ExpansionState.Direction) -> Void)?

  private var fineCount: Int { ExpansionState.Step.fine.lineCount ?? 20 }

  var body: some View {
    HStack(spacing: 4) {
      if let onExpand {
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
      } else {
        Label(DiffAXText.collapsedRunLabel(hiddenCount: hiddenCount), systemImage: "text.alignleft")
          .font(.caption)
      }

      if let header, !header.isEmpty {
        Text(header)
          .font(.caption.monospaced())
          .lineLimit(1)
          .truncationMode(.middle)
          .padding(.leading, 4)
          .accessibilityHidden(true)  // the bar's own AX label already carries it
      }
      Spacer(minLength: 0)
    }
    .buttonStyle(.borderless)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 8)
    .frame(maxWidth: .infinity, minHeight: ChunkLayoutMetrics.production.separatorHeight)
    .background(.quaternary.opacity(0.4))
  }

  private var label: String {
    "Expand \(hiddenCount) line\(hiddenCount == 1 ? "" : "s")"
  }
}
