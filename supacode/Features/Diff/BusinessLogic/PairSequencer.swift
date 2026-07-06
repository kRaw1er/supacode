import Foundation

/// Derives stable, collision-free `splitLine` pair IDs from line numbers so a
/// content-only edit keeps IDs stable (small `CollectionDifference` delta), and so
/// the split-view scroll anchor re-lands the same pair across a mode toggle.
///
/// New-side rows encode `new * 2` (even); deletion-only rows encode `old * 2 + 1`
/// (odd); markers use a private descending counter so they never collide with real
/// line-derived IDs.
///
/// **Single source of truth** (Phase 8): both `DiffRowBuilder.appendChanges` (the
/// legacy `[DiffRow]` builder) and `AlignedPairing.pairChange` (the chunk-tree
/// aligned-pair leaf) mint IDs through THIS type, so the unified↔split projections
/// agree line-for-line and the anchor identity is stable across the toggle.
///
/// `nonisolated` (the app target defaults to `@MainActor` isolation) so the
/// nonisolated `LineSegment.alignedPairChunk` / `AlignedPairing` off-main pairing
/// can mint IDs without a hop.
nonisolated struct PairSequencer {
  private var markerCounter = -1

  init() {}

  func contextID(newLine: Int?, oldLine: Int?) -> Int {
    if let newLine { return newLine * 2 }
    if let oldLine { return oldLine * 2 + 1 }
    return 0
  }

  func changeID(newLine: Int?, oldLine: Int?) -> Int {
    if let newLine { return newLine * 2 }
    if let oldLine { return oldLine * 2 + 1 }
    return 0
  }

  mutating func markerID() -> Int {
    defer { markerCounter -= 1 }
    return markerCounter
  }
}
