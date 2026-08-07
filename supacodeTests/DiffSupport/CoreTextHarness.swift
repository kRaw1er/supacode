import AppKit
import CoreText

@testable import supacode

/// I3 — the CoreText test harness (CT-HEADLESS). A pinned
/// `monospacedSystemFont(13)` + `DiffMetrics.resolve()`, deterministic bitmap
/// contexts at explicit 1× / 2× / 1.5× backing scale, single-line and wrapped
/// `CTLine` builders, and `RecordingContext` — which captures `fill` /
/// `setFillColor` so a test asserts **rects + tokens, not pixels**. Consumed by
/// P3/P4/P5/P8/P11/P13.
@MainActor
enum CoreTextHarness {
  /// pierre `font-size: 13px` (style.css:81). `DiffMetrics.resolve()` resolves the
  /// same `monospacedSystemFont(NSFont.systemFontSize)` (== 13 on macOS).
  static let fontSize: CGFloat = 13
  static let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

  /// pierre `line-height: 20px` (style.css:82) — the tree's row height.
  static let lineHeight: CGFloat = 20

  static var metrics: DiffMetrics { .resolve() }

  /// The monospace advance (== the value the paragraph tab interval is built on).
  static var advance: CGFloat { max(1, ("0" as NSString).size(withAttributes: [.font: font]).width) }

  /// A deterministic offscreen bitmap `CGContext` at an explicit backing `scale`
  /// (1× / 2× / 1.5×). The CTM is pre-scaled so points map to backing pixels.
  static func context(width: CGFloat, height: CGFloat, scale: CGFloat) -> CGContext {
    let pixelsWide = max(1, Int((width * scale).rounded()))
    let pixelsHigh = max(1, Int((height * scale).rounded()))
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
      data: nil,
      width: pixelsWide,
      height: pixelsHigh,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: space,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.scaleBy(x: scale, y: scale)
    return ctx
  }

  static func paragraphStyle() -> NSParagraphStyle { LineTypesetter.paragraphStyle(advance: advance) }

  static func attributed(_ content: NSString) -> NSAttributedString {
    LineTypesetter.attributed(content, font: font, style: paragraphStyle())
  }

  /// Soft-wrap a plain content string at `width` (the I3 `wrapped(_:width:)`).
  static func wrapped(_ content: NSString, width: CGFloat, lineHeight: CGFloat = lineHeight) -> LineTypesetter.Wrapped {
    LineTypesetter.wrap(attributed(content), width: width, lineHeight: lineHeight)
  }

  /// One unwrapped `CTLine` of `content` — the offset↔x round-trip surface.
  static func ctLine(_ content: NSString) -> CTLine {
    CTLineCreateWithAttributedString(attributed(content))
  }
}

/// Records the `fill` / `setFillColor` calls a `GutterRenderer` (or any
/// `DiffGraphics` drawer) makes, so a headless test asserts the substrate as
/// **rects + color tokens** instead of sampling pixels (TEST-STRATEGY I3: "what
/// turns 'draws N rects behind glyphs' into an assertion").
@MainActor
final class RecordingContext: DiffGraphics {
  enum Event {
    case setFillColor(CGColor)
    case fill(CGRect)
  }

  private(set) var events: [Event] = []
  private var currentColor: CGColor?

  func setFillColor(_ color: CGColor) {
    currentColor = color
    events.append(.setFillColor(color))
  }

  func fill(_ rect: CGRect) {
    events.append(.fill(rect))
  }

  /// Every filled rect, in order.
  var fills: [CGRect] {
    events.compactMap { if case .fill(let rect) = $0 { return rect } else { return nil } }
  }

  /// Every filled rect paired with the fill color active when it was drawn.
  var filledRects: [(rect: CGRect, color: CGColor)] {
    var color: CGColor?
    var out: [(rect: CGRect, color: CGColor)] = []
    for event in events {
      switch event {
      case .setFillColor(let value): color = value
      case .fill(let rect): if let color { out.append((rect, color)) }
      }
    }
    return out
  }
}
