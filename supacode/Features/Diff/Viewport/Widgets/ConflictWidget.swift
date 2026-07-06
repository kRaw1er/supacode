import AppKit
import SwiftUI

/// The merge-conflict accept-ours/theirs/both widget hosted like every `.widget`
/// chunk. Parses the inline `<<<<<<< / ||||||| / ======= / >>>>>>>` markers of a
/// conflict region (`ConflictRegion`), tints ours vs theirs with system colors (no
/// custom color — CLAUDE.md), and offers accept actions that EMIT (the view sends,
/// never mutates — `store_state_mutation_in_views`). When the region straddles hunk
/// boundaries the split can't be anchored, so accept is disabled and a "resolve in
/// editor" affordance is shown (gate, don't guess).
///
/// Accept-WRITE-to-disk (mutating the working tree via the reducer + `gitClient`) is
/// a DEFERRED follow-up (TEST-STRATEGY §4.1) — this widget parses + renders + emits
/// the resolution intent; the reducer/`gitClient` write is the gated next step.
@MainActor
final class ConflictWidget: DiffWidget {
  let key: WidgetKey
  var region: ConflictRegion
  private unowned let coalescer: LayoutCoalescer
  private let onResolve: (MergeConflictResolution) -> Void
  private let onResolveInEditor: () -> Void

  init(
    key: WidgetKey,
    region: ConflictRegion,
    coalescer: LayoutCoalescer,
    onResolve: @escaping (MergeConflictResolution) -> Void = { _ in },
    onResolveInEditor: @escaping () -> Void = {}
  ) {
    self.key = key
    self.region = region
    self.coalescer = coalescer
    self.onResolve = onResolve
    self.onResolveInEditor = onResolveInEditor
  }

  var estimatedHeight: CGFloat { ChunkLayoutMetrics.production.expanderHeight }

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

  @ViewBuilder
  private func content(reporter: HeightReporter) -> some View {
    ConflictActionRow(
      canAutoResolve: region.canAutoResolve,
      onResolve: onResolve,
      onResolveInEditor: onResolveInEditor
    )
    .onGeometryChange(for: CGSize.self) {
      $0.size
    } action: { size in
      reporter.report(width: size.width, height: size.height)
    }
  }
}

/// The 3-button action row anchored just after a conflict start. Disabled (with a
/// "resolve in editor" escape hatch) when the region can't be safely auto-resolved.
struct ConflictActionRow: View {
  let canAutoResolve: Bool
  let onResolve: (MergeConflictResolution) -> Void
  let onResolveInEditor: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      Text("Merge conflict")
        .font(.callout.weight(.medium))
      Spacer(minLength: 8)
      if canAutoResolve {
        Button("Accept ours") { onResolve(.current) }
          .help("Keep our side (accept current)")
        Button("Accept theirs") { onResolve(.incoming) }
          .help("Keep their side (accept incoming)")
        Button("Accept both") { onResolve(.both) }
          .help("Keep both sides in order")
      } else {
        Text("Spans multiple hunks")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("Resolve in editor") { onResolveInEditor() }
          .help("This conflict can't be auto-resolved here — open it in your editor")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
  }
}

/// A read-only tinted preview of a conflict region's ours / base / theirs sections
/// (system green for ours, red for theirs, secondary for the 3-way base) — the
/// line-type tint the widget shows above the action row.
struct ConflictRegionPreview: View {
  let region: ConflictRegion

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      section(region.currentLines, label: "Ours", tint: .green)
      if !region.baseLines.isEmpty {
        section(region.baseLines, label: "Base", tint: .secondary)
      }
      section(region.incomingLines, label: "Theirs", tint: .red)
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private func section(_ lines: [String], label: String, tint: Color) -> some View {
    if !lines.isEmpty {
      VStack(alignment: .leading, spacing: 1) {
        Text(label)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(tint)
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          Text(line.isEmpty ? " " : line)
            .font(.body.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 4)
      .background(tint.opacity(0.12))
    }
  }
}
