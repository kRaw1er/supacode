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

  /// Mount `widget`'s host view and connect its height reports to `coalescer`. The host is
  /// pinned to FILL us via Auto Layout (all four edges) so the layout engine proposes our
  /// size to SwiftUI (a plain `frame` set on an `NSHostingView(sizingOptions: [])` does not).
  ///
  /// KNOWN-STILL-BROKEN (handoff note): the hunk-header / expander SwiftUI content still
  /// renders collapsed at the LEFT. ROOT (proven by `[wframe]` logging): on the FIRST layout
  /// after `apply`, the scroll view is not yet sized, so `DiffViewportController.place` frames
  /// THIS container at `documentView.bounds.width == 0` → container=(x,y,0,h). The hosting
  /// view lays its content out at width 0, and does NOT re-flow when the container later
  /// grows to full width (confirmed: it never recovers on a later render). Line rows survive
  /// because `LineRowView.draw` re-runs at the real width; a hosted SwiftUI view does not.
  /// FIX DIRECTIONS for the next pass: (a) don't materialize / skip `place` while
  /// `documentView.bounds.width == 0` so the first render is already full-width; or (b) force
  /// the hosted view to re-flow when the container width changes (re-mount / swap `rootView`
  /// in `configureWidget` when `width` differs from the mounted width).
  func mount(_ widget: some DiffWidget, key: WidgetKey, width: CGFloat, coalescer: LayoutCoalescer) {
    hosted?.removeFromSuperview()
    self.coalescer = coalescer
    let reporter = HeightReporter(key: key, coalescer: coalescer)
    let host = widget.makeHostView(reporter: reporter)
    if let hostingView = host as? NSHostingView<AnyView> { hostingView.sizingOptions = [] }  // size is 100% ours
    host.translatesAutoresizingMaskIntoConstraints = false
    addSubview(host)
    NSLayoutConstraint.activate([
      host.leadingAnchor.constraint(equalTo: leadingAnchor),
      host.trailingAnchor.constraint(equalTo: trailingAnchor),
      host.topAnchor.constraint(equalTo: topAnchor),
      host.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
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
    guard widget.update(hostView: hosted, width: width) else { return false }  // width is held by constraints
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
