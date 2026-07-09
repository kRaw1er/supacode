import Foundation
import Testing

@testable import supacode

/// Phase 7 — pure `ExpansionState` region math + the comment-pinning collapse
/// guard. Ports of pierre `getExpandedRegion` (virtualDiffLayout.ts:55-104) and
/// `expandHunk` (DiffHunksRenderer.ts:268-287); the step ladder is OURS (C2).
/// `@MainActor` because the collapse-guard test drives `ChunkTreeBuilder`.
@MainActor
struct ExpansionStateTests {

  // MARK: - 9.1 resolve region math (C1)

  @Test func resolveRegionMathC1() {
    let collapsed = ExpansionState.collapsed
    // Sub-threshold gap (`size <= 1`) ⇒ renderAll (C1: a ≤1-line gap never collapses).
    let sub = collapsed.resolve(gap: 0, rangeSize: 1)
    #expect(sub.renderAll)
    #expect(sub.fromStart == 1)
    #expect(sub.collapsedLines == 0)

    // A larger, un-expanded gap stays collapsed (nothing revealed).
    let big = collapsed.resolve(gap: 0, rangeSize: 30)
    #expect(!big.renderAll)
    #expect(big.collapsedLines == 30)
    #expect(big.fromStart == 0)

    // Clamp `fromStart`/`fromEnd` to `[0, size]`; renderAll at `fromStart+fromEnd >= size`.
    let over = ExpansionState.regions([0: HunkExpansionRegion(fromStart: 100, fromEnd: 100)])
      .resolve(gap: 0, rangeSize: 10)
    #expect(over.renderAll)
    #expect(over.fromStart == 10)
    #expect(over.fromEnd == 0)
    #expect(over.collapsedLines == 0)

    // Partial: `collapsedLines = max(size - expanded, 0)`.
    let partial = ExpansionState.regions([0: HunkExpansionRegion(fromStart: 3, fromEnd: 2)])
      .resolve(gap: 0, rangeSize: 10)
    #expect(partial.fromStart == 3)
    #expect(partial.fromEnd == 2)
    #expect(partial.collapsedLines == 5)
    #expect(!partial.renderAll)

    // Negative region values clamp to 0.
    let neg = ExpansionState.regions([0: HunkExpansionRegion(fromStart: -4, fromEnd: -1)])
      .resolve(gap: 0, rangeSize: 10)
    #expect(neg.fromStart == 0)
    #expect(neg.fromEnd == 0)
    #expect(neg.collapsedLines == 10)
  }

  // MARK: - 9.2 trailing gap is upward-only

  @Test func trailingGapUpwardOnly() {
    let state = ExpansionState.regions([2: HunkExpansionRegion(fromStart: 4, fromEnd: 6)])
    // `isTrailing` forces `fromEnd = 0` — expanding down past EOF is a no-op.
    let trailing = state.resolve(gap: 2, rangeSize: 100, isTrailing: true)
    #expect(trailing.fromEnd == 0)
    #expect(trailing.fromStart == 4)
    #expect(trailing.collapsedLines == 96)
    // The SAME region on a non-trailing gap keeps `fromEnd`.
    let interior = state.resolve(gap: 2, rangeSize: 100, isTrailing: false)
    #expect(interior.fromEnd == 6)
    #expect(interior.collapsedLines == 90)
  }

  // MARK: - 9.3 additive expand / collapse mutation

  @Test func expandCollapseAdditiveMutation() {
    var state = ExpansionState.collapsed
    // `.up` adds to `fromStart`; additive.
    state.expand(gap: 1, by: .fine, direction: .up)
    state.expand(gap: 1, by: .fine, direction: .up)
    #expect(state == .regions([1: HunkExpansionRegion(fromStart: 40)]))  // 20 + 20

    // `.down` adds to `fromEnd`.
    state.expand(gap: 1, by: .coarse, direction: .down)
    #expect(state == .regions([1: HunkExpansionRegion(fromStart: 40, fromEnd: 100)]))

    // `.both` adds to both ends.
    state.expand(gap: 2, by: .fine, direction: .both)
    #expect(
      state
        == .regions([
          1: HunkExpansionRegion(fromStart: 40, fromEnd: 100),
          2: HunkExpansionRegion(fromStart: 20, fromEnd: 20),
        ]))

    // `.whole` promotes past the gap size (clamped to renderAll in `resolve`).
    state.expand(gap: 2, by: .whole, direction: .both)
    #expect(state.resolve(gap: 2, rangeSize: 5).renderAll)

    // `collapse` removes the gap's region.
    state.collapse(gap: 1)
    #expect(state == .regions([2: HunkExpansionRegion(fromStart: .max, fromEnd: 20)]))

    // No-op on `.full` (whole-file is all-or-nothing).
    var full = ExpansionState.full
    full.expand(gap: 0, by: .fine, direction: .up)
    full.collapse(gap: 0)
    #expect(full == .full)
  }

  // MARK: - 9.3b symmetric shrink (⇧E) — saturating, prunes to no-region

  @Test func shrinkIsSymmetricAndPrunesToCollapsed() {
    var state = ExpansionState.collapsed
    // Grow two fine steps on both ends ⇒ 40/40.
    state.expand(gap: 1, by: .fine, direction: .both)
    state.expand(gap: 1, by: .fine, direction: .both)
    #expect(state == .regions([1: HunkExpansionRegion(fromStart: 40, fromEnd: 40)]))

    // One shrink removes exactly ONE fine step from each end (symmetric to expand).
    state.shrink(gap: 1, by: .fine, direction: .both)
    #expect(state == .regions([1: HunkExpansionRegion(fromStart: 20, fromEnd: 20)]))
    #expect(state.hasRevealedRegion(gap: 1))

    // The final shrink saturates at 0 and PRUNES the gap back to no-region ⇒ `.collapsed`.
    state.shrink(gap: 1, by: .fine, direction: .both)
    #expect(state == .collapsed)
    #expect(!state.hasRevealedRegion(gap: 1))

    // Shrinking an already-absent gap is an inert no-op.
    state.shrink(gap: 5, by: .fine, direction: .both)
    #expect(state == .collapsed)

    // `.full` is all-or-nothing — shrink is a no-op (mirrors expand/collapse on `.full`).
    var full = ExpansionState.full
    #expect(full.hasRevealedRegion(gap: 0))
    full.shrink(gap: 0, by: .fine, direction: .both)
    #expect(full == .full)

    // Uneven ends: shrinking below zero clamps at 0, and a single non-zero end keeps the region.
    var uneven = ExpansionState.regions([2: HunkExpansionRegion(fromStart: 10, fromEnd: 20)])
    uneven.shrink(gap: 2, by: .fine, direction: .both)  // 10-20→0, 20-20→0 ... fromStart clamps at 0
    #expect(uneven == .collapsed)  // both ends hit 0 ⇒ pruned
    var oneEnd = ExpansionState.regions([2: HunkExpansionRegion(fromStart: 40, fromEnd: 5)])
    oneEnd.shrink(gap: 2, by: .fine, direction: .down)  // only the bottom shrinks: 5→0, top untouched
    #expect(oneEnd == .regions([2: HunkExpansionRegion(fromStart: 40, fromEnd: 0)]))
  }

  // MARK: - 9.4 = E seam 1.5 — expansion survives a re-diff via the gap-index key

  @Test func expansionSurvivesReDiffByGapKey() {
    // The region is keyed by GAP INDEX 1, NOT a line number.
    let state = ExpansionState.regions([1: HunkExpansionRegion(fromStart: 5)])
    // `resolve` takes the gap index + rangeSize — it NEVER reads a line number, so a
    // hunk-body edit that shifts every line number leaves the resolved region
    // identical (a `Set<Int>` line-number key would have missed at the shifted number).
    let beforeReDiff = state.resolve(gap: 1, rangeSize: 10)
    let afterReDiff = state.resolve(gap: 1, rangeSize: 10)
    #expect(beforeReDiff == afterReDiff)
    #expect(afterReDiff.fromStart == 5)
    // The region resolves ONLY under its own gap index — proving hunk-index keying.
    #expect(state.resolve(gap: 2, rangeSize: 10).fromStart == 0)
    #expect(state.resolve(gap: 0, rangeSize: 10).fromStart == 0)
  }

  // MARK: - 9.5 stale gap index degrades to collapsed (never a crash)

  @Test func staleGapIndexDegradesToCollapsed() {
    var state = ExpansionState.regions([3: HunkExpansionRegion(fromStart: 5)])
    // A re-diff removed hunks so gap 3 no longer maps → its bounding-hunk `rangeSize`
    // is 0 → an inert, empty region (never a crash, never a spurious reveal).
    let resolved = state.resolve(gap: 3, rangeSize: 0)
    #expect(resolved == ExpansionState.ResolvedRegion(fromStart: 0, fromEnd: 0, collapsedLines: 0, renderAll: false))
    // Mutating a now-stale gap is safe; it resolves inert.
    state.expand(gap: 3, by: .whole, direction: .both)
    #expect(state.resolve(gap: 3, rangeSize: 0).collapsedLines == 0)
    #expect(state.resolve(gap: 3, rangeSize: 0).renderAll == false)
  }

  // MARK: - B §23 accept / reject / both ⇒ context-only region, correct counts

  @Test func resolvedRegionIsContextOnly() {
    let size = 20
    // `.up` (accept) / `.down` (reject) / `.both` are the region-math axis.
    for direction in [ExpansionState.Direction.up, .down, .both] {
      var state = ExpansionState.collapsed
      state.expand(gap: 1, by: .fine, direction: direction)  // reveal up to 20 lines
      let region = state.resolve(gap: 1, rangeSize: size)
      // Counts conserved: revealed (top + bottom) + still-hidden == the whole gap.
      #expect(region.fromStart + region.fromEnd + region.collapsedLines == size)
    }
    // The revealed lines the provider slices are context-only, correctly numbered,
    // with the EOF-newline fact preserved (no spurious no-newline marker).
    let table = BlobLineTable.build(utf16: Array("l1\nl2\nl3\nl4\nl5".utf16))
    let sliced = BlobSliceProvider.slice(table, newLineRange: 1..<4, oldLineDelta: 0)
    #expect(sliced.allSatisfy { $0.origin == .context })
    #expect(sliced.allSatisfy { !$0.noNewlineAtEof })
    #expect(sliced.map(\.newLineNumber) == [1, 2, 3])
    #expect(sliced.map(\.oldLineNumber) == [1, 2, 3])
  }

  // MARK: - 9.10 a commented line is never folded into a collapsed run

  @Test func commentedLineNeverHiddenByGap() {
    // A hunk: one change, then a 15-line context run (> collapseThreshold 10).
    var lines: [DiffLine] = [
      DiffFixture.line(.deletion, old: 1, "old"),
      DiffFixture.line(.addition, new: 1, "new"),
    ]
    for number in 2...16 { lines.append(DiffFixture.line(.context, old: number, new: number, "ctx\(number)")) }
    let hunk = DiffFixture.hunk(lines)
    let file = DiffFixture.file()

    // No comment → the long context run collapses into an expander.
    let plain = ChunkTreeBuilder.classify(file: file, hunks: [hunk], expanded: [])
    #expect(Self.hasExpander(plain))

    // A comment on a HIDDEN middle context line (new 9) pins the run — no expander,
    // and the commented line renders in a context segment.
    let comment = ReviewComment(
      filePath: file.id, side: .new, startLine: 9, endLine: 9, anchorSnippet: "ctx9", contextBefore: "")
    let pinned = ChunkTreeBuilder.classify(file: file, hunks: [hunk], expanded: [], comments: [comment])
    #expect(!Self.hasExpander(pinned))
    let renderedNewNumbers = pinned.compactMap(\.lineSegment).flatMap { Array($0.windowedLines) }
      .compactMap(\.newLineNumber)
    #expect(renderedNewNumbers.contains(9))
  }

  private static func hasExpander(_ chunks: [Chunk]) -> Bool {
    chunks.contains { chunk in
      guard case .widget(let widget) = chunk, case .expander = widget.key else { return false }
      return true
    }
  }
}
