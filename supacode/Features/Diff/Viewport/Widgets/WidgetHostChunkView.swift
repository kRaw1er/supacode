import AppKit
import SwiftUI

/// Hosts exactly one `DiffWidget`'s self-sizing `NSView` for a `.widget` chunk and
/// wires its height reports into the `LayoutCoalescer`. The container owns the
/// width; the hosted view reports its height (never the reverse). A recycled host
/// is offered to a new model via `reuse` — the widget accepts (identity swap) or
/// refuses (an `.editing` comment editor), in which case the harness rebuilds
/// (`NSHostingView` `rootView` swap over a live `TextEditor` has sharp edges).
@MainActor
final class WidgetHostChunkView: NSView, DiffViewportRecyclable {
  override var isFlipped: Bool { true }

  /// The mounted widget's self-sizing view.
  private(set) var hosted: NSView?
  /// The identity currently mounted — proves a recycled host resolves the RIGHT
  /// model after a pool reuse (keyed by `WidgetKey`, not `ChunkID`).
  private(set) var mountedKey: WidgetKey?
  /// Whether the mounted widget owns an app-managed subview (a live comment
  /// editor) — while set, this host refuses recycle to another chunk (B §3).
  private(set) var isOccupied = false
  private var coalescer: LayoutCoalescer?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// Lay the hosted view out to fill us, computed relative to our OWN bounds — the
  /// designated place to position subviews (runs on every layout pass, so there is no
  /// window in which the host is stale). The viewport sets this container's frame in
  /// `place`; the container owns the width, so the host tracks it here. Without this a
  /// host mounted while the document was still 0-wide (applied before the scroll view was
  /// sized) would stay 0-wide — a same-model re-layout early-outs before `reuse` and never
  /// resizes it — and the widget renders collapsed / off to the side.
  override func layout() {
    super.layout()
    guard let hosted, hosted.frame != bounds else { return }
    hosted.frame = bounds
    hosted.needsLayout = true
    hosted.layoutSubtreeIfNeeded()  // force the NSHostingView to re-flow SwiftUI content to the new width
  }

  /// Invalidate layout when the viewport resizes us in `place`. In AppKit (unlike UIKit) a
  /// manual `frame` set on a non-Auto-Layout `NSView` does NOT schedule `layout()` on its
  /// own — verified live: without this the FIRST placement leaves the host at its mount-time
  /// (possibly 0) width until some later relayout. The positioning math stays in `layout()`.
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    needsLayout = true
  }

  /// Mount `widget`'s host view at `width × estimatedHeight` (the offscreen
  /// reservation) and connect its height reports to `coalescer`.
  func mount(_ widget: some DiffWidget, key: WidgetKey, width: CGFloat, coalescer: LayoutCoalescer) {
    hosted?.removeFromSuperview()
    self.coalescer = coalescer
    let reporter = HeightReporter(key: key, coalescer: coalescer)
    let host = widget.makeHostView(reporter: reporter)
    if let hostingView = host as? NSHostingView<AnyView> { hostingView.sizingOptions = [] }  // container owns sizing
    host.frame = CGRect(x: 0, y: 0, width: width, height: widget.estimatedHeight)
    addSubview(host)
    hosted = host
    mountedKey = key
    isOccupied = widget.occupiesHostExclusively
    frame.size.height = widget.estimatedHeight
  }

  /// Offer this already-mounted host to `widget` (a pool recycle). Returns whether
  /// the widget accepted the identity swap; `false` ⇒ the harness must
  /// `prepareForReuse` + `mount` a fresh host.
  func reuse(_ widget: some DiffWidget, key: WidgetKey, width: CGFloat) -> Bool {
    // An occupied host (a live comment editor) is not eligible for recycle until
    // it is drained — never handed to another chunk (B §3).
    guard !isOccupied else { return false }
    guard let hosted, mountedKey?.reuseKind == key.reuseKind else { return false }
    guard widget.update(hostView: hosted, width: width) else { return false }
    hosted.frame.size.width = width
    mountedKey = key
    isOccupied = widget.occupiesHostExclusively
    return true
  }

  /// Unmount hook — tears the hosted view down before the recycled host is handed
  /// to another chunk (pierre `onPostRenderPhase`, B §20). The autoscroller /
  /// display-link ownership lives on the coalescer, not here.
  override func prepareForReuse() {
    hosted?.removeFromSuperview()
    hosted = nil
    mountedKey = nil
    isOccupied = false
    coalescer = nil
  }
}
