import AppKit
import CoreGraphics

/// The 45° diagonal hatch drawn behind an empty split pane (C5) — the nil side of a
/// pure-addition / pure-deletion aligned pair. Replaces the FLAT muted fill the two
/// viewers drew before (`DiffCellView.drawPane` / `LineRowView.drawPane`,
/// `quaternaryLabelColor.withAlphaComponent(0.06)`). Ports pierre
/// `createEmptyRowBuffer.ts` + `style.css:950-962`
/// `repeating-linear-gradient(45deg, … 1.414 …)`; the `1.414` (√2) keeps the stripe
/// pitch constant at a true 45°.
///
/// Drawn through `some DiffGraphics` (the I3 seam `GutterRenderer` uses) so a
/// headless `RecordingContext` captures the base-wash + stripe rects as **tokens,
/// not pixels**. A `CGContext` diagonal *stroke* would be crisper but is not
/// capturable, so — exactly like `GutterRenderer.drawDashedBar` — each 45° stripe
/// is a staircase of `stripeWidth`-square steps (dx == dy per step ⇒ true 45°).
@MainActor
enum EmptySideHatch {
  static let stripeWidth: CGFloat = 3
  /// √2 spacing between adjacent 45° stripes → the perpendicular gap stays constant
  /// (`stripeWidth*2*√2` x-step ⇒ `stripeWidth*2` perpendicular pitch: a
  /// `stripeWidth` stripe + `stripeWidth` gap, a 50%-coverage hatch).
  static var pitch: CGFloat { stripeWidth * 2 * 1.414 }
  /// Base wash alpha (matches the prior flat-fill tone so the change is a hatch, not
  /// a darker pane).
  static let baseWashAlpha: CGFloat = 0.05
  /// Stripe alpha (a hair stronger than the wash so the diagonal reads).
  static let stripeAlpha: CGFloat = 0.12

  /// The x-origins (top-edge intersections) of every 45° stripe covering `rect`.
  /// Stripes march bottom-left → top-right; a stripe that enters through the bottom
  /// edge starts `rect.height` to the LEFT of the rect so its diagonal reaches the
  /// top edge inside the rect. Consecutive origins differ by exactly `pitch` — the
  /// pure surface the pitch assertion pins.
  static func stripeOriginXs(in rect: CGRect) -> [CGFloat] {
    guard rect.width > 0, rect.height > 0, pitch > 0 else { return [] }
    var origins: [CGFloat] = []
    var originX = rect.minX - rect.height
    let limit = rect.maxX + rect.height
    while originX < limit {
      origins.append(originX)
      originX += pitch
    }
    return origins
  }

  /// Draw the base wash + 45° stripes into `ctx`, clipped to `rect`. The base wash
  /// is one full-rect fill; each stripe is a staircase of `stripeWidth`-square steps
  /// intersected with `rect` (so overhanging stripes are trimmed, never spill).
  static func draw(in rect: CGRect, tint: NSColor = .quaternaryLabelColor, into ctx: some DiffGraphics) {
    guard rect.width > 0, rect.height > 0 else { return }
    ctx.setFillColor(tint.withAlphaComponent(baseWashAlpha).cgColor)
    ctx.fill(rect)
    ctx.setFillColor(tint.withAlphaComponent(stripeAlpha).cgColor)
    let step = stripeWidth
    for originX in stripeOriginXs(in: rect) {
      var offsetY: CGFloat = 0
      while offsetY < rect.height {
        let stepRect = CGRect(
          x: originX + offsetY, y: rect.minY + offsetY, width: stripeWidth, height: min(step, rect.height - offsetY))
        let clipped = stepRect.intersection(rect)
        if !clipped.isNull, !clipped.isEmpty { ctx.fill(clipped) }
        offsetY += step
      }
    }
  }
}
