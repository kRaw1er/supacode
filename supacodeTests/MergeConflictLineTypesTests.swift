import Testing

@testable import supacode

/// Phase 13 (B §22 / §23) — conflict-marker line-typing + resolution. 2-way, 3-way
/// (`|||||||` base), and nested conflicts (via a phase stack) map to the exact
/// `marker-*` / `current` / `base` / `incoming` / `none` sequence; `resolve` strips
/// ALL markers and keeps the chosen side, including multiple conflicts in one hunk.
struct MergeConflictLineTypesTests {

  // MARK: - Line typing

  @Test func twoWayConflictClassifies() {
    let lines = [
      "context above",
      "<<<<<<< ours",
      "our change",
      "=======",
      "their change",
      ">>>>>>> theirs",
      "context below",
    ]
    #expect(
      MergeConflict.lineTypes(lines) == [
        .none, .markerStart, .current, .markerSeparator, .incoming, .markerEnd, .none,
      ])
  }

  @Test func threeWayConflictClassifiesBaseSection() {
    let lines = [
      "<<<<<<< ours",
      "our change",
      "||||||| base",
      "original",
      "=======",
      "their change",
      ">>>>>>> theirs",
    ]
    #expect(
      MergeConflict.lineTypes(lines) == [
        .markerStart, .current, .markerBase, .base, .markerSeparator, .incoming, .markerEnd,
      ])
  }

  @Test func nestedConflictTrackedViaStack() {
    // An inner conflict inside the OUTER ours section: the inner content classifies
    // by the inner frame's phase; after the inner >>>>>>> pops, we return to outer.
    let lines = [
      "<<<<<<< outer",
      "outer ours",
      "<<<<<<< inner",
      "inner ours",
      "=======",
      "inner theirs",
      ">>>>>>> inner",
      "outer ours tail",
      "=======",
      "outer theirs",
      ">>>>>>> outer",
    ]
    #expect(
      MergeConflict.lineTypes(lines) == [
        .markerStart,  // outer
        .current,  // outer ours
        .markerStart,  // inner
        .current,  // inner ours
        .markerSeparator,  // inner
        .incoming,  // inner theirs
        .markerEnd,  // inner
        .current,  // back to outer ours
        .markerSeparator,  // outer
        .incoming,  // outer theirs
        .markerEnd,  // outer
      ])
  }

  @Test func markersOutsideConflictAreContent() {
    // A file that literally contains `=======` outside any conflict must not be
    // misread as a marker.
    let lines = ["title", "=======", "body"]
    #expect(MergeConflict.lineTypes(lines) == [.none, .none, .none])
    #expect(!MergeConflict.hasConflict(lines))
  }

  // MARK: - Balance guard

  @Test func balancedAndUnbalancedMarkers() {
    #expect(MergeConflict.markersAreBalanced(["<<<<<<< a", "x", "=======", "y", ">>>>>>> b"]))
    #expect(!MergeConflict.markersAreBalanced(["<<<<<<< a", "x", "=======", "y"]))  // no end → straddles
    #expect(!MergeConflict.markersAreBalanced(["no", "conflict", "here"]))
  }

  // MARK: - Resolution (strips ALL markers)

  @Test func resolveKeepsChosenSideAndStripsMarkers() {
    let lines = [
      "before",
      "<<<<<<< ours",
      "our line",
      "||||||| base",
      "base line",
      "=======",
      "their line",
      ">>>>>>> theirs",
      "after",
    ]
    #expect(MergeConflict.resolve(lines, keeping: .current) == ["before", "our line", "after"])
    #expect(MergeConflict.resolve(lines, keeping: .incoming) == ["before", "their line", "after"])
    #expect(MergeConflict.resolve(lines, keeping: .both) == ["before", "our line", "their line", "after"])
    // No marker of any kind survives any resolution.
    for resolution in [MergeConflictResolution.current, .incoming, .both] {
      let resolved = MergeConflict.resolve(lines, keeping: resolution)
      #expect(!resolved.contains { $0.hasPrefix("<<<<<<<") || $0.hasPrefix("=======") || $0.hasPrefix(">>>>>>>") })
      #expect(!resolved.contains { $0.hasPrefix("|||||||") })
    }
  }

  @Test func resolveMultipleConflictsInOneHunk() {
    let lines = [
      "a",
      "<<<<<<< ours", "ours-1", "=======", "theirs-1", ">>>>>>> theirs",
      "b",
      "<<<<<<< ours", "ours-2", "=======", "theirs-2", ">>>>>>> theirs",
      "c",
    ]
    #expect(MergeConflict.resolve(lines, keeping: .current) == ["a", "ours-1", "b", "ours-2", "c"])
    #expect(MergeConflict.resolve(lines, keeping: .incoming) == ["a", "theirs-1", "b", "theirs-2", "c"])
  }
}
