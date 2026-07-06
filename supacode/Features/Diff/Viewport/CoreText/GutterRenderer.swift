import AppKit
import CoreGraphics

/// The two paint primitives the gutter substrate needs, abstracted so a headless
/// test can drive `GutterRenderer` into a `RecordingContext` and assert **rects +
/// tokens, not pixels** (TEST-STRATEGY I3). `CGContext` satisfies both already,
/// so the live path is a zero-cost conformance.
@MainActor
protocol DiffGraphics {
  func setFillColor(_ color: CGColor)
  func fill(_ rect: CGRect)
}

extension CGContext: DiffGraphics {}

/// The per-row geometry the gutter substrate is painted into: the full-width row
/// rect (for the tint) and the x of the change-bar rail's left edge. Pure data.
nonisolated struct LineRowGeometry: Equatable {
  /// Full-row rect in flipped document coordinates (top-left origin).
  var rowRect: CGRect
  /// Left edge of the 4pt change-bar rail (the `[newBar]` x-band).
  var barX: CGFloat
}

/// Draws the per-row substrate UNDER the CoreText text: full-row add/del tint and
/// the change bar (numbers-as-text are drawn separately by the row view). Paint
/// only. All x/y are snapped to backing pixels so 1pt bars don't blur at 2× / 1.5×
/// (§Round-3 Retina). Caseless statics — no free functions (CLAUDE.md).
@MainActor
struct GutterRenderer {
  let metrics: DiffMetrics
  /// `window.backingScaleFactor`, read FRESH per draw.
  let scale: CGFloat
  let palette: DiffPalette

  /// pierre change-bar affordance width.
  static let changeBarWidth: CGFloat = 4

  /// gutterWidth = `max(3, maxDigits)·advance + 2·advance + 1·advance`, per file
  /// (recomputed on expand / materialize). The `+2` reserves the two bar rails and
  /// the `+1` a hair of trailing padding (brainstorm §Round-3 hit-test / gutter).
  static func gutterWidth(maxDigits: Int, advance: CGFloat) -> CGFloat {
    (CGFloat(max(3, maxDigits)) + 2 + 1) * advance
  }

  /// Dashed-deletion-bar period = `lineHeight / round(lineHeight / 2)` (§Round-3).
  /// For the pierre 20pt grid this is exactly `2`.
  static func dashPeriod(lineHeight: CGFloat) -> CGFloat {
    let half = (lineHeight / 2).rounded()
    return half > 0 ? lineHeight / half : lineHeight
  }

  /// Snap a scalar to the backing pixel grid (correct at 1× / 2× / 1.5×).
  func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }

  /// Snap all four edges of a rect to the nearest backing pixel (the scale-driven
  /// analog of `NSView.backingAlignedRect(_:options:.alignAllEdgesNearest)`, but
  /// deterministic at an explicit `scale` so retina QA is unit-testable headless).
  func backingAligned(_ rect: CGRect) -> CGRect {
    let minX = snap(rect.minX)
    let minY = snap(rect.minY)
    return CGRect(x: minX, y: minY, width: snap(rect.maxX) - minX, height: snap(rect.maxY) - minY)
  }

  /// Paint one row's substrate: (1) full-row tint, then (2) the change bar (solid
  /// for an addition, dashed for a deletion). Context / marker rows paint nothing.
  func draw(row: LineRowGeometry, origin: DiffLineOrigin, in ctx: some DiffGraphics) {
    if let tint = palette.rowTint(for: origin) {
      ctx.setFillColor(tint.cgColor)
      ctx.fill(backingAligned(row.rowRect))
    }
    guard let barColor = palette.changeBar(for: origin) else { return }
    ctx.setFillColor(barColor.cgColor)
    let bar = CGRect(
      x: snap(row.barX),
      y: row.rowRect.minY,
      width: Self.changeBarWidth,
      height: row.rowRect.height
    )
    if origin == .deletion {
      drawDashedBar(bar, in: ctx)
    } else {
      ctx.fill(backingAligned(bar))
    }
  }

  private func drawDashedBar(_ bar: CGRect, in ctx: some DiffGraphics) {
    let period = Self.dashPeriod(lineHeight: metrics.lineHeight)
    var offsetY = bar.minY
    while offsetY < bar.maxY {
      let height = min(period, bar.maxY - offsetY)
      ctx.fill(backingAligned(CGRect(x: bar.minX, y: offsetY, width: bar.width, height: height)))
      offsetY += 2 * period  // dash on `period`, gap `period`
    }
  }
}
