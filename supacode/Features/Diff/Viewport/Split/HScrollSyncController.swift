import CoreGraphics
import SupacodeSettingsShared

/// Mirrors the horizontal scroll offset between the two no-wrap split columns
/// (C4). pierre's `ScrollSyncManager` mirrors `scrollLeft` ONLY (never `scrollTop`)
/// and guards the echo with a 300ms time lock (`ScrollSyncManager.ts:83`). We use a
/// deterministic boolean guard instead (testable without a clock — CLAUDE.md bans
/// `Task.sleep` in tests): applying the mirrored offset to the sibling column
/// re-enters `columnDidScroll` synchronously (an `NSView` bounds-change posts
/// synchronously), and the guard drops that echo.
///
/// Only reachable in `.noWrapTwoColumns`; in `.wrapSingleRow` there is no
/// controller (single vertical scroll, no sync).
@MainActor
final class HScrollSyncController {
  enum Column: Equatable, Sendable { case left, right }

  private(set) var hScrollOffset: CGFloat = 0
  private var isApplying = false
  private let apply: (Column, CGFloat) -> Void
  private static let logger = SupaLogger("Split")

  /// `apply(column, offset)` sets that column's clip origin; it may synchronously
  /// re-fire `columnDidScroll` (NSView bounds-change is posted synchronously) — the
  /// guard absorbs it.
  init(apply: @escaping (Column, CGFloat) -> Void) { self.apply = apply }

  /// A column scrolled to `offset`. Mirror it to the sibling exactly once, dropping
  /// the mirrored echo and any no-op (offset unchanged). The guard is a plain bool,
  /// not a counter: one synchronous echo is the only re-entrancy case.
  func columnDidScroll(_ source: Column, to offset: CGFloat) {
    guard !isApplying else { return }  // drop the mirrored echo
    guard offset != hScrollOffset else { return }  // no-op when unchanged
    hScrollOffset = offset
    isApplying = true
    apply(source == .left ? .right : .left, offset)
    isApplying = false
    Self.logger.debug("hscroll mirror \(source == .left ? "L->R" : "R->L") @ \(offset)")
  }

  /// Programmatically set BOTH columns to `offset` (a wheel/gesture drives one edge;
  /// this seeds the shared offset and applies to both). Re-entrancy-guarded like the
  /// event path so a bounds echo from either `apply` is dropped.
  func setOffset(_ offset: CGFloat) {
    guard !isApplying, offset != hScrollOffset else { return }
    hScrollOffset = offset
    isApplying = true
    apply(.left, offset)
    apply(.right, offset)
    isApplying = false
  }
}
