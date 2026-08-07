import AppKit
import QuartzCore

/// Coalesces widget height reports into ONE per-frame layout pass on
/// `NSView.displayLink` (D1 — `CVDisplayLink*` is deprecated in macOS 15 and its
/// own `deprecationSummary` recommends `NSView.displayLink(target:selector:)`,
/// which also delivers on the main run loop and is occlusion-aware). Each pass
/// captures the scroll anchor ONCE, applies every ≥ `epsilon` height change
/// (`host.setMeasuredHeight` → O(log n) tree re-aggregate), and restores the
/// anchor ONCE so the viewport never jumps — even for a widget ABOVE the fold.
///
/// A left/right split pair reports twice for one aligned row; the taller side
/// wins (`max`). A measure↔layout feedback loop is bounded by a 5-pass guard
/// (CM6 / C7). Heights are retina-snapped so a sub-pixel wobble can't oscillate.
@MainActor
final class LayoutCoalescer {
  private unowned let host: WidgetLayoutHost
  private var link: CADisplayLink?
  private var pending: [WidgetKey: (width: CGFloat, height: CGFloat)] = [:]

  /// Consecutive passes that changed a height — the measure↔layout loop guard.
  private(set) var passesSinceSettle = 0
  /// Whether the coalescer is currently idle (its display link paused). Exposed so
  /// a headless test can assert the loop guard actually stopped the pump.
  private(set) var isPaused = true

  /// Whether a live `NSView.displayLink` drives the pump (F#14). `false` in headless
  /// tests that pass no `displayLinkView`; a test seam so the viewport wiring can
  /// assert the production coalescer is actually link-driven, not tick-only.
  var isDisplayLinkInstalled: Bool { link != nil }

  /// 0.5pt height-delta threshold below which a report is a no-op (plan §399).
  static let epsilon: CGFloat = 0.5
  /// Measure↔layout loop guard cap (CM6, C7): a persistent oscillation halts here.
  static let maxPasses = 5

  /// - Parameter displayLinkView: the view whose `displayLink` drives the pump in
  ///   production. `nil` in headless tests — they call `tick()` directly (there is
  ///   no live display link off-screen; C §CI note).
  init(host: WidgetLayoutHost, displayLinkView: NSView? = nil) {
    self.host = host
    if let displayLinkView {
      let link = displayLinkView.displayLink(target: self, selector: #selector(displayLinkFired))
      link.add(to: .main, forMode: .common)
      link.isPaused = true
      self.link = link
    }
  }

  deinit { link?.invalidate() }

  /// Enqueue a measured height for `key` at `width`. When a second report for the
  /// SAME key+width arrives before the pass runs (a split left/right pair), the
  /// taller height is retained (`max`). Un-pauses the pump.
  func enqueueMeasuredHeight(key: WidgetKey, width: CGFloat, height: CGFloat) {
    let snapped = host.retinaSnap(height)
    if let existing = pending[key], existing.width == width {
      pending[key] = (width, max(existing.height, snapped))
    } else {
      pending[key] = (width, snapped)
    }
    resume()
  }

  /// The coalesced-but-not-yet-applied height for `key` (test seam for the
  /// `max`-paired assertion).
  func pendingHeight(for key: WidgetKey) -> CGFloat? { pending[key]?.height }

  @objc private func displayLinkFired(_ link: CADisplayLink) { tick() }

  /// One coalesced pass. Public so a headless test can drive it without a live
  /// display link.
  func tick() {
    guard !pending.isEmpty else {
      pause()
      passesSinceSettle = 0
      return
    }
    let batch = pending
    pending.removeAll(keepingCapacity: true)
    let anchor = host.captureScrollAnchor()  // ONCE per frame
    var changed = false
    for (key, measured) in batch {
      guard let current = host.measuredHeight(forWidget: key), current.width == measured.width else {
        host.setMeasuredHeight(key, width: measured.width, height: measured.height)
        changed = true
        continue
      }
      if abs(current.height - measured.height) > Self.epsilon {  // 0.5pt epsilon
        host.setMeasuredHeight(key, width: measured.width, height: measured.height)  // O(log n) reaggregate
        changed = true
      }
    }
    host.restoreScrollAnchor(anchor)  // ONCE per frame (anti-jump)
    passesSinceSettle = changed ? passesSinceSettle + 1 : 0
    if !changed || passesSinceSettle >= Self.maxPasses {  // loop guard
      pending.removeAll()
      pause()
      passesSinceSettle = 0
    }
  }

  private func resume() {
    isPaused = false
    link?.isPaused = false
  }

  private func pause() {
    isPaused = true
    link?.isPaused = true
  }
}
