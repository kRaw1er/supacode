import AppKit

@testable import supacode

/// Phase-6 widget-harness test scaffolding. A `WidgetLayoutHost` double that
/// records the coalescer's `capture` / `restore` / `setMeasuredHeight` calls with
/// NO live view or display link (C §CI note — the arithmetic is driven by calling
/// `tick()` directly). Optionally models the measure↔layout feedback loop by
/// re-enqueuing a changed height on every `set` (the 5-pass loop-guard fixture).
@MainActor
final class FakeWidgetLayoutHost: WidgetLayoutHost {
  private(set) var captureCount = 0
  private(set) var restoreCount = 0
  private(set) var setCount = 0
  private var heights: [WidgetKey: (width: CGFloat, height: CGFloat)] = [:]

  /// Identity retina-snap so tests reason in exact points.
  var identityRetinaSnap = true
  /// When set (with `oscillate`), a `set` re-enqueues a DIFFERENT height to model a
  /// persistent measure↔layout oscillation.
  weak var coalescer: LayoutCoalescer?
  var oscillate = false

  func seed(_ key: WidgetKey, width: CGFloat, height: CGFloat) {
    heights[key] = (width, height)
  }

  func retinaSnap(_ value: CGFloat) -> CGFloat {
    identityRetinaSnap ? value : (value * 2).rounded() / 2
  }

  func measuredHeight(forWidget key: WidgetKey) -> (width: CGFloat, height: CGFloat)? {
    heights[key]
  }

  func setMeasuredHeight(_ key: WidgetKey, width: CGFloat, height: CGFloat) {
    setCount += 1
    heights[key] = (width, height)
    if oscillate, let coalescer {
      coalescer.enqueueMeasuredHeight(key: key, width: width, height: height + 20)
    }
  }

  func captureScrollAnchor() -> ScrollAnchor? {
    captureCount += 1
    return nil
  }

  func restoreScrollAnchor(_ anchor: ScrollAnchor?) {
    restoreCount += 1
  }
}

/// Shared helpers for building comment / widget tree fixtures.
@MainActor
enum WidgetTreeFixture {
  /// A single-line context leaf carrying `line` on both sides.
  static func contextLeaf(_ line: Int) -> Chunk {
    .lineSegment(
      LineSegment(
        hunkID: HunkID(fileID: "f", index: 0),
        lines: [
          DiffLine(
            origin: .context, oldLineNumber: line, newLineNumber: line, content: "line\(line)", noNewlineAtEof: false)
        ],
        window: 0..<1,
        classification: .context
      )
    )
  }

  /// A `.commentThread` widget leaf with an explicit estimated height.
  static func commentWidget(id: UUID, estimatedHeight: CGFloat) -> Chunk {
    .widget(
      Widget(
        key: .commentThread(anchorID: id),
        estimatedHeight: estimatedHeight,
        payload: .commentThread(anchorID: id)
      )
    )
  }
}
