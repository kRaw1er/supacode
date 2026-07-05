import AppKit

@testable import supacode

/// Phase-2 viewport test scaffolding: window-less `DiffViewportController`
/// construction (NSVIEW-HEADLESS), fine-grained `ChunkTree` fixtures whose leaves
/// map 1:1 to lines (so line-level anchoring lands on chunk boundaries), and a
/// recycle-lifecycle spy view. Pure AppKit — no window, no run loop.
@MainActor
enum ViewportTestSupport {
  /// A window-less controller whose scroll view is tiled to `width × clipHeight`
  /// with overlay scrollers so the clip fills the full frame (deterministic
  /// `contentView.bounds`).
  static func controller(width: CGFloat = 800, clipHeight: CGFloat = 600) -> DiffViewportController {
    let controller = DiffViewportController()
    controller.scrollView.scrollerStyle = .overlay
    controller.scrollView.frame = NSRect(x: 0, y: 0, width: width, height: clipHeight)
    controller.scrollView.tile()
    return controller
  }

  /// A `DiffMetrics` with an explicit gutter width (deterministic x-band math).
  static func metrics(gutter: CGFloat) -> DiffMetrics {
    DiffMetrics(
      font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
      lineHeight: 20,
      charWidth: 8,
      vPad: 1,
      hPad: 6,
      gutterWidth: gutter
    )
  }

  /// One single-line context leaf per new-line number, in order — leaf `i` sits
  /// at `y = i * lineHeight` with anchor identity `.line(numbers[i], .new)`.
  static func contextLeaves(_ numbers: [Int], metrics: ChunkLayoutMetrics = .production) -> ChunkTree {
    let tree = ChunkTree(metrics: metrics)
    let hunkID = HunkID(fileID: "f", index: 0)
    let lines = numbers.map {
      DiffLine(origin: .context, oldLineNumber: $0, newLineNumber: $0, content: "line\($0)", noNewlineAtEof: false)
    }
    var after: ChunkID?
    for offset in lines.indices {
      let segment = LineSegment(
        hunkID: hunkID, lines: lines, window: offset..<(offset + 1), classification: .context)
      after = tree.insert(.lineSegment(segment), after: after)
    }
    return tree
  }

  /// `count` expander widgets, each a single `height`-tall row — the "many small
  /// chunks" fixture for the window-bounded recycle-count assertion.
  static func widgets(count: Int, height: CGFloat = 20, metrics: ChunkLayoutMetrics = .production) -> ChunkTree {
    let tree = ChunkTree(metrics: metrics)
    var after: ChunkID?
    for index in 0..<count {
      let widget = Widget(
        key: .expander(GapKey(hunkIndex: index)),
        estimatedHeight: height,
        payload: .expander(anchor: index, range: index..<(index + 1), hidden: 1)
      )
      after = tree.insert(.widget(widget), after: after)
    }
    return tree
  }

  /// A comment-thread widget leaf on a distinct anchor.
  static func commentWidget(id: UUID, height: CGFloat = 120) -> Chunk {
    .widget(
      Widget(
        key: .commentThread(anchorID: id),
        estimatedHeight: height,
        payload: .commentThread(anchorID: id)
      )
    )
  }
}

/// Ordered lifecycle log shared across spy views to assert mount / unmount order.
@MainActor
final class LifecycleLog {
  private(set) var entries: [String] = []
  func record(_ entry: String) { entries.append(entry) }
}

/// A recyclable spy view: records its unmount (`prepareForReuse`) and carries a
/// mutable `content` string that stands in for the borrowed view state a recycle
/// must reset.
@MainActor
final class SpyRecyclableView: NSView, DiffViewportRecyclable {
  let spyName: String
  var content: String?
  private let log: LifecycleLog

  init(tag: String, log: LifecycleLog) {
    self.spyName = tag
    self.log = log
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func prepareForReuse() {
    content = nil
    log.record("unmount:\(spyName)")
  }
}
