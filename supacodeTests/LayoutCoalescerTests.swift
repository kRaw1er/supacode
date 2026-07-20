import AppKit
import Testing

@testable import supacode

/// Phase 6 — the widget height-coalescer (`NSView.displayLink`, capture anchor
/// once → apply all → restore once, `max`-paired, 0.5pt epsilon + 5-pass loop
/// guard, retina snap). Driven headless by calling `tick()` directly against a
/// `FakeWidgetLayoutHost` — no live display link (C §CI note).
@MainActor
struct LayoutCoalescerTests {
  private func key() -> WidgetKey { .commentThread(anchorID: UUID()) }

  // MARK: - C 6.1 — a sub-epsilon delta is a no-op

  @Test func coalescerSubEpsilonIsNoop() {
    let host = FakeWidgetLayoutHost()
    let coalescer = LayoutCoalescer(host: host)
    let widgetKey = key()
    host.seed(widgetKey, width: 400, height: 100)
    coalescer.enqueueMeasuredHeight(key: widgetKey, width: 400, height: 100.3)  // < 0.5pt delta
    coalescer.tick()
    #expect(host.setCount == 0)  // no write-back for a sub-epsilon wobble
  }

  // MARK: - C 6.2 — 5-pass measure↔layout loop guard stops

  @Test func coalescerFivePassLoopGuardStops() {
    let host = FakeWidgetLayoutHost()
    let coalescer = LayoutCoalescer(host: host)
    host.coalescer = coalescer
    host.oscillate = true  // every `set` re-enqueues a changed height (perpetual oscillation)
    let widgetKey = key()
    coalescer.enqueueMeasuredHeight(key: widgetKey, width: 400, height: 100)
    var pumps = 0
    while !coalescer.isPaused, pumps < 100 {
      coalescer.tick()
      pumps += 1
    }
    #expect(host.setCount == LayoutCoalescer.maxPasses)  // halted at the guard, not unbounded
    #expect(coalescer.isPaused)
  }

  // MARK: - C 6.3 — a split left/right pair collapses via max

  @Test func coalescerSplitPairReportsMax() {
    let host = FakeWidgetLayoutHost()
    let coalescer = LayoutCoalescer(host: host)
    let widgetKey = key()
    coalescer.enqueueMeasuredHeight(key: widgetKey, width: 400, height: 100)  // left side
    coalescer.enqueueMeasuredHeight(key: widgetKey, width: 400, height: 80)  // right side of the same paired row
    #expect(coalescer.pendingHeight(for: widgetKey) == 100)  // the taller side is authoritative
  }

  // MARK: - C 6.4 — one capture / restore per frame, any batch size

  @Test func coalescerCapturesAnchorOncePerFrame() {
    let host = FakeWidgetLayoutHost()
    let coalescer = LayoutCoalescer(host: host)
    for _ in 0..<5 {
      coalescer.enqueueMeasuredHeight(key: key(), width: 400, height: 100)
    }
    coalescer.tick()
    #expect(host.captureCount == 1)  // anchored ONCE (anti-jump), regardless of batch size
    #expect(host.restoreCount == 1)
    #expect(host.setCount == 5)  // every distinct widget applied in the one pass
  }

  // MARK: - C 6.7 — a missing estimate mis-places offscreen (the estimate is required)

  @Test func missingEstimateBreaksScrollbar() {
    func totalHeight(estimate: CGFloat) -> CGFloat {
      let tree = ChunkTree(metrics: .production)
      let id = UUID()
      let after = tree.insert(WidgetTreeFixture.commentWidget(id: id, estimatedHeight: estimate), after: nil)
      _ = tree.insert(WidgetTreeFixture.contextLeaf(5), after: after)
      return tree.totalHeight(.unified)
    }
    let lineHeight = ChunkLayoutMetrics.production.lineHeight
    // A zero estimate reserves nothing, so the line below sits where the widget
    // should be — the scrollbar / offscreen placement is wrong (CM6).
    #expect(totalHeight(estimate: 0) == lineHeight)
    // A real estimate is load-bearing: it reserves the widget's height off-window.
    #expect(totalHeight(estimate: 44) == 44 + lineHeight)
  }
}
