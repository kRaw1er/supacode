import CoreGraphics

/// The height-push channel a widget's `NSView` uses to report its observed height
/// at a given width. A value type captured by the SwiftUI `.onGeometryChange`
/// closure (or called from a plain `NSView.layout()`), keyed by the widget's
/// per-instance `WidgetKey` so the coalescer can reconcile which node grew.
///
/// KVO on `NSHostingView` height is unreliable (brainstorm §Round-3), so height is
/// pushed explicitly through here and coalesced into one per-frame pass by the
/// `LayoutCoalescer` — never read back off the hosting layout.
@MainActor
struct HeightReporter {
  let key: WidgetKey
  unowned let coalescer: LayoutCoalescer

  /// Report the widget's observed `height` at `width`. Coalesced (one per-frame
  /// pass); a split left/right pair collapses via `max` inside the coalescer.
  func report(width: CGFloat, height: CGFloat) {
    coalescer.enqueueMeasuredHeight(key: key, width: width, height: height)
  }
}
