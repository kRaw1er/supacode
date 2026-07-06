import AppKit
import SwiftUI

/// The before/after image-compare MODEL (the only genuinely new edge-diff
/// renderer). Decodes both blobs to `NSImage` (a `nil` side is an added / deleted
/// image); when NEITHER side decodes it falls back to the binary summary row
/// instead of crashing. The fitted height is computed purely (no live layout) so
/// the harness reserves the right space offscreen.
@MainActor
struct ImageCompareModel {
  var before: NSImage?
  var after: NSImage?
  /// Best-effort byte counts for the summary caption (from the blob sizes).
  var beforeByteCount: Int
  var afterByteCount: Int

  /// At least one side decoded ⇒ we can show the visual compare; otherwise the
  /// widget renders the binary summary row (undecodable / non-image blob).
  var canCompare: Bool { before != nil || after != nil }

  /// Decode a blob to an image, returning `nil` for a missing / undecodable /
  /// non-image blob (the fallback path, never a crash).
  static func decode(_ data: Data?) -> NSImage? {
    guard let data, !data.isEmpty, let image = NSImage(data: data), image.size.width > 0, image.size.height > 0
    else { return nil }
    return image
  }

  /// Build the model from the two raw image blobs (either may be `nil`).
  static func make(beforeData: Data?, afterData: Data?) -> ImageCompareModel {
    ImageCompareModel(
      before: decode(beforeData),
      after: decode(afterData),
      beforeByteCount: beforeData?.count ?? 0,
      afterByteCount: afterData?.count ?? 0
    )
  }

  /// The reserved height at `width` (deterministic, no live layout). Side-by-side
  /// reserves the taller of the two fitted panes plus the picker + captions; the
  /// summary fallback reserves a single row band.
  func fittedHeight(forWidth width: CGFloat) -> CGFloat {
    guard canCompare else { return Self.summaryHeight }
    let paneWidth = max(1, (width - Self.interPanePadding) / 2 - Self.outerPadding)
    let beforeHeight = Self.paneHeight(for: before, width: paneWidth)
    let afterHeight = Self.paneHeight(for: after, width: paneWidth)
    return Self.chromeHeight + max(beforeHeight, afterHeight)
  }

  /// One pane's fitted height at `width`, preserving the image aspect ratio and
  /// clamped so a huge image does not reserve the whole viewport.
  private static func paneHeight(for image: NSImage?, width: CGFloat) -> CGFloat {
    guard let image, image.size.width > 0 else { return placeholderPaneHeight }
    let aspect = image.size.height / image.size.width
    return min(maxPaneHeight, max(placeholderPaneHeight, width * aspect))
  }

  static let chromeHeight: CGFloat = 64  // segmented picker + dimension captions + padding
  static let summaryHeight: CGFloat = 44
  static let placeholderPaneHeight: CGFloat = 120
  static let maxPaneHeight: CGFloat = 480
  static let interPanePadding: CGFloat = 12
  static let outerPadding: CGFloat = 12
}

/// The image-compare widget hosted like every `.widget` chunk (width-in →
/// height-out). Renders side-by-side / onion (opacity) / swipe (mask) compare of a
/// binary IMAGE change; a `nil` side draws a diagonal hatch; an undecodable pair
/// falls back to the binary summary row.
@MainActor
final class ImageCompareWidget: DiffWidget {
  let key: WidgetKey
  var model: ImageCompareModel
  private unowned let coalescer: LayoutCoalescer

  init(key: WidgetKey, model: ImageCompareModel, coalescer: LayoutCoalescer) {
    self.key = key
    self.model = model
    self.coalescer = coalescer
  }

  var estimatedHeight: CGFloat { model.canCompare ? 240 : ImageCompareModel.summaryHeight }

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
    Group {
      if model.canCompare {
        ImageCompareView(model: model)
      } else {
        ImageBinarySummaryView(beforeByteCount: model.beforeByteCount, afterByteCount: model.afterByteCount)
      }
    }
    .onGeometryChange(for: CGSize.self) {
      $0.size
    } action: { size in
      reporter.report(width: size.width, height: size.height)
    }
  }
}

/// The visual compare body: a segmented mode picker over side-by-side / onion /
/// swipe. `NSImage` panes scale-to-fit; a `nil` side draws a hatch.
struct ImageCompareView: View {
  let model: ImageCompareModel
  @State private var mode: Mode = .sideBySide
  @State private var overlay: Double = 0.5

  enum Mode: Hashable, CaseIterable {
    case sideBySide, onion, swipe
    var label: String {
      switch self {
      case .sideBySide: "Side by side"
      case .onion: "Onion"
      case .swipe: "Swipe"
      }
    }
  }

  var body: some View {
    VStack(spacing: 8) {
      Picker("Compare mode", selection: $mode) {
        ForEach(Mode.allCases, id: \.self) { Text($0.label).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      Group {
        switch mode {
        case .sideBySide:
          HStack(spacing: 12) {
            pane(model.before, label: "Before")
            pane(model.after, label: "After")
          }
        case .onion, .swipe:
          overlayCompare
          Slider(value: $overlay, in: 0...1) {
            Text(mode == .onion ? "Opacity" : "Position")
          }
          .controlSize(.small)
        }
      }
    }
    .padding(12)
    .accessibilityElement(children: .contain)
  }

  private func pane(_ image: NSImage?, label: String) -> some View {
    VStack(spacing: 4) {
      ZStack {
        if let image {
          Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .accessibilityLabel("\(label) image")
        } else {
          EmptyImageHatch()
            .accessibilityLabel("\(label): none")
        }
      }
      .frame(maxWidth: .infinity)
      Text(dimensionCaption(image, label: label))
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var overlayCompare: some View {
    ZStack {
      if let before = model.before {
        Image(nsImage: before).resizable().interpolation(.high).scaledToFit()
      } else {
        EmptyImageHatch()
      }
      if let after = model.after {
        let top = Image(nsImage: after).resizable().interpolation(.high).scaledToFit()
        if mode == .onion {
          top.opacity(overlay)
        } else {
          top.mask(alignment: .leading) {
            GeometryReader { geo in
              Color.black.frame(width: geo.size.width * overlay)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityLabel(mode == .onion ? "Onion-skin compare" : "Swipe compare")
  }

  private func dimensionCaption(_ image: NSImage?, label: String) -> String {
    guard let image else { return "\(label): —" }
    return "\(label): \(Int(image.size.width))×\(Int(image.size.height))"
  }
}

/// The undecodable / non-image fallback — the binary summary row, never a crash.
struct ImageBinarySummaryView: View {
  let beforeByteCount: Int
  let afterByteCount: Int

  var body: some View {
    Label(summary, systemImage: "doc.fill")
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
  }

  private var summary: String {
    let delta = abs(afterByteCount - beforeByteCount)
    return "Binary file — \(delta) byte\(delta == 1 ? "" : "s") changed"
  }
}

/// The 45° hatch for a missing (added / deleted) image side.
struct EmptyImageHatch: View {
  var body: some View {
    Canvas { context, size in
      let step: CGFloat = 8
      var offset: CGFloat = -size.height
      var path = Path()
      while offset < size.width {
        path.move(to: CGPoint(x: offset, y: 0))
        path.addLine(to: CGPoint(x: offset + size.height, y: size.height))
        offset += step
      }
      context.stroke(path, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
    }
    .frame(minHeight: ImageCompareModel.placeholderPaneHeight)
    .background(.quaternary.opacity(0.25))
  }
}
