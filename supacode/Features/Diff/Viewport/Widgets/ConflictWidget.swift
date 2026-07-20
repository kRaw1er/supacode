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
  /// Whether accept-WRITE-to-disk is available. `false` by default because the
  /// reducer/`gitClient` write is a DEFERRED follow-up (TEST-STRATEGY §4.1, §442):
  /// while gated the accept buttons render DISABLED so the UI never lies, and the
  /// working "resolve in editor" escape hatch stays enabled.
  private let acceptWriteEnabled: Bool

  init(
    key: WidgetKey,
    region: ConflictRegion,
    coalescer: LayoutCoalescer,
    onResolve: @escaping (MergeConflictResolution) -> Void = { _ in },
    onResolveInEditor: @escaping () -> Void = {},
    acceptWriteEnabled: Bool = false
  ) {
    self.key = key
    self.region = region
    self.coalescer = coalescer
    self.onResolve = onResolve
    self.onResolveInEditor = onResolveInEditor
    self.acceptWriteEnabled = acceptWriteEnabled
  }

  /// Pure description of what this widget renders — the tinted region preview (F15)
  /// above an accept row whose availability is gated (F24). The view builds STRICTLY
  /// from this, so the render can't drift from the tested model.
  var contentModel: ConflictWidgetContent {
    ConflictWidgetContent.make(region: region, acceptWriteEnabled: acceptWriteEnabled)
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
    let model = contentModel
    VStack(alignment: .leading, spacing: 0) {
      // F15: the ours / base / theirs tint reaches the screen instead of only plain
      // marker content — the preview renders ABOVE the action row.
      ConflictRegionPreview(region: region)
      ConflictActionRow(
        canAutoResolve: region.canAutoResolve,
        acceptEnabled: model.acceptAvailability.acceptButtonsEnabled,
        onResolve: onResolve,
        onResolveInEditor: onResolveInEditor
      )
    }
    .onGeometryChange(for: CGSize.self) {
      $0.size
    } action: { size in
      reporter.report(width: size.width, height: size.height)
    }
  }
}

/// Whether the conflict accept buttons may act. Accept-WRITE-to-disk is a gated
/// follow-up (§442), so the common single-hunk case is `.gated` (accept disabled,
/// resolve-in-editor offered) rather than `.enabled` — the UI must not present a
/// button whose `onResolve` is a no-op. Pure / testable.
nonisolated enum ConflictAcceptAvailability: Equatable, Sendable {
  /// Region is auto-resolvable AND accept-WRITE is wired — accept buttons act.
  case enabled
  /// Region is auto-resolvable but accept-WRITE is deferred — accept disabled,
  /// resolve-in-editor offered.
  case gated
  /// Region straddles hunks / is unbalanced — can't anchor a split here at all.
  case unresolvableHere

  static func resolve(canAutoResolve: Bool, acceptWriteEnabled: Bool) -> ConflictAcceptAvailability {
    guard canAutoResolve else { return .unresolvableHere }
    return acceptWriteEnabled ? .enabled : .gated
  }

  /// The three accept buttons act only when fully enabled.
  var acceptButtonsEnabled: Bool { self == .enabled }
  /// The "resolve in editor" escape hatch shows whenever accept can't be trusted.
  var showsResolveInEditor: Bool { self != .enabled }
}

/// Pure, testable description of the conflict widget's rendered content: the tinted
/// ours / base / theirs preview sections (F15) plus the accept availability (F24).
nonisolated struct ConflictWidgetContent: Equatable, Sendable {
  var preview: [PreviewSection]
  var acceptAvailability: ConflictAcceptAvailability

  /// One tinted section of the region preview.
  struct PreviewSection: Equatable, Sendable {
    /// The system tint a section reads with — no custom color (CLAUDE.md).
    enum Tint: Equatable, Sendable {
      case ours  // system green
      case base  // secondary (3-way merge base)
      case theirs  // system red
    }

    var label: String
    var lines: [String]
    var tint: Tint
  }

  /// The tinted ours / base / theirs sections a region contributes (empty sections
  /// dropped, so a 2-way conflict has no base band).
  static func previewSections(for region: ConflictRegion) -> [PreviewSection] {
    var sections: [PreviewSection] = []
    if !region.currentLines.isEmpty {
      sections.append(PreviewSection(label: "Ours", lines: region.currentLines, tint: .ours))
    }
    if !region.baseLines.isEmpty {
      sections.append(PreviewSection(label: "Base", lines: region.baseLines, tint: .base))
    }
    if !region.incomingLines.isEmpty {
      sections.append(PreviewSection(label: "Theirs", lines: region.incomingLines, tint: .theirs))
    }
    return sections
  }

  static func make(region: ConflictRegion, acceptWriteEnabled: Bool) -> ConflictWidgetContent {
    ConflictWidgetContent(
      preview: previewSections(for: region),
      acceptAvailability: .resolve(canAutoResolve: region.canAutoResolve, acceptWriteEnabled: acceptWriteEnabled)
    )
  }
}

/// The 3-button action row anchored just after a conflict start. The accept buttons
/// are DISABLED whenever accept-WRITE is gated (`acceptEnabled == false`, the default
/// while the reducer/`gitClient` write is deferred, §442) or the region can't be
/// safely auto-resolved — and in either case the working "resolve in editor" escape
/// hatch is offered so the UI never presents a button that silently does nothing.
struct ConflictActionRow: View {
  let canAutoResolve: Bool
  /// Accept-WRITE-to-disk is wired. `false` gates the accept buttons to disabled.
  var acceptEnabled: Bool = false
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
          .disabled(!acceptEnabled)
          .help(acceptHelp("Keep our side (accept current)"))
        Button("Accept theirs") { onResolve(.incoming) }
          .disabled(!acceptEnabled)
          .help(acceptHelp("Keep their side (accept incoming)"))
        Button("Accept both") { onResolve(.both) }
          .disabled(!acceptEnabled)
          .help(acceptHelp("Keep both sides in order"))
        if !acceptEnabled {
          Button("Resolve in editor") { onResolveInEditor() }
            .help("Accept isn't wired yet — open this conflict in your editor")
        }
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

  /// The accept button tooltip: its normal intent when wired, otherwise a pointer to
  /// the "resolve in editor" escape hatch so a disabled button explains itself.
  private func acceptHelp(_ enabledText: String) -> String {
    acceptEnabled ? enabledText : "Accept isn't wired yet — use “Resolve in editor”"
  }
}

/// A read-only tinted preview of a conflict region's ours / base / theirs sections
/// (system green for ours, red for theirs, secondary for the 3-way base) — the
/// line-type tint the widget shows above the action row.
struct ConflictRegionPreview: View {
  let region: ConflictRegion

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Render from the same pure model the tests assert against so the on-screen
      // tint can't drift from the tested ours / base / theirs classification.
      ForEach(Array(ConflictWidgetContent.previewSections(for: region).enumerated()), id: \.offset) { _, section in
        sectionView(section)
      }
    }
    .accessibilityElement(children: .contain)
  }

  private func tint(for kind: ConflictWidgetContent.PreviewSection.Tint) -> Color {
    switch kind {
    case .ours: .green
    case .base: .secondary
    case .theirs: .red
    }
  }

  @ViewBuilder
  private func sectionView(_ section: ConflictWidgetContent.PreviewSection) -> some View {
    let tint = tint(for: section.tint)
    VStack(alignment: .leading, spacing: 1) {
      Text(section.label)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
      ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
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
