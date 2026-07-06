import AppKit

/// The embedded-widget contract: **width-in → intrinsic-height-out**. The
/// container (the viewport / `WidgetHostChunkView`) owns the width; the widget
/// owns its height AT that width, and that height is **observed, not declared**
/// (brainstorm §"Embedded-widget subsystem"). The lingua franca is `NSView`; a
/// widget MAY wrap SwiftUI via `NSHostingView` (fine for the sparse, rich comment
/// composer) while simple / hot widgets stay plain AppKit — the two-tier model
/// that mirrors diffs.com (`.lineSegment` chunks stay CoreText; only sparse
/// `.widget` chunks are hosting views).
///
/// `WidgetReuseKind` / `WidgetKey` / `GapKey` are DEFINED IN PHASE 1
/// (`Chunk.swift` — Phase 1 owns the tree types) and CONSUMED here (D3 / S1). The
/// harness resolves a widget's MODEL by `WidgetKey`:
///   `.fileHeader(fileID:)`      → `FileHeaderWidget`
///   `.commentThread(anchorID:)` → `CommentThreadWidget` (`anchorID == head comment id`)
///   `.expander(GapKey)`         → `ExpanderWidget` (Phase 7 wires the expansion)
@MainActor
protocol DiffWidget: AnyObject {
  /// Offscreen placement height before real measurement. **Required** — a missing
  /// estimate mis-places everything below it while the widget is off-window, so
  /// the scrollbar is wrong (CM6 rule, brainstorm §176 / plan §419). Cheap; must
  /// NOT build a hosting view.
  var estimatedHeight: CGFloat { get }

  /// The self-sizing `NSView` the harness hosts. The container sets its width; the
  /// view reports its height back through `reporter` (SwiftUI `.onGeometryChange`
  /// or a plain `NSView.layout()`). `NSHostingView`s must set `sizingOptions = []`
  /// so the container — not SwiftUI — owns sizing.
  func makeHostView(reporter: HeightReporter) -> NSView

  /// Push this widget's model into an already-mounted, recycled `hostView`
  /// (identity swap). Returns `false` when the host can NOT be reused for this
  /// model, so the harness discards + rebuilds instead of swapping — an
  /// `NSHostingView` `rootView` swap over a live `TextEditor` loses the cursor /
  /// selection, so a comment editor returns `false` while `.editing`.
  func update(hostView: NSView, width: CGFloat) -> Bool
}
