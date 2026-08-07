import Foundation

/// A side-by-side aligned pair: one source line per side, each independently
/// nullable. A `nil` side is a *gap* (rendered as the 45° empty-side buffer, C5).
/// pierre emits exactly this from its single diff iterator
/// (`iterateOverDiff.ts:28-44`); in-project this is the shape of
/// `DiffRow.splitLine(pairID:old:new:)` (`DiffRow.swift:13`) and of the tree's
/// `LineSegment` split projection (`SegmentProjection.splitChangeRows`).
nonisolated struct AlignedPair: Equatable, Sendable {
  let left: DiffLine?  // deletion / unchanged-left; nil ⇒ pure addition (right-only)
  let right: DiffLine?  // addition / unchanged-right; nil ⇒ pure deletion (left-only)
  let pairID: Int  // stable identity (scroll anchor), minted by PairSequencer

  var isPureDeletion: Bool { left != nil && right == nil }
  var isPureAddition: Bool { left == nil && right != nil }
  var isContext: Bool { left != nil && right != nil }

  /// The `DiffLine` on `side`, or `nil` when that side is a gap/buffer.
  func line(on side: DiffSide) -> DiffLine? {
    side == .old ? left : right
  }
}

/// One split-mode chunk leaf: the aligned pairs for a single change block or a
/// context run. Carries BOTH mode counts so the dual-mode tree can seek by either
/// dimension with no reproject (C6).
///
/// Note: `unifiedLineCount` for a change block is `del + add` (unpaired), while
/// `splitLineCount` is `max(del, add)` — the divergence that makes the toggle a
/// *re-seek* and not an identity map. No-newline metadata rows are counted by the
/// leaf separately (`LineSegment.noNewlineCounts`) so they never drift either mode.
nonisolated struct AlignedPairChunk: Equatable, Sendable {
  private(set) var pairs: [AlignedPair]
  /// C6: contribution to the UNIFIED row index — deletions + additions never fold
  /// in unified, so it is the count of non-nil sides across the pairs.
  let unifiedLineCount: Int

  init(pairs: [AlignedPair], unifiedLineCount: Int) {
    self.pairs = pairs
    self.unifiedLineCount = unifiedLineCount
  }

  /// C6: this leaf's contribution to the SPLIT row index (`splitLineCount`).
  var splitLineCount: Int { pairs.count }

  /// The number of gap/buffer cells on `side` — the surplus of the OTHER side.
  /// For a change block where `del > add`, `emptyCount(on: .new) == del − add`
  /// (the additions column shows a buffer for each unpaired deletion). Pure-add /
  /// pure-delete collapse to one column, so the present side has zero buffers.
  func emptyCount(on side: DiffSide) -> Int {
    pairs.reduce(0) { $0 + ($1.line(on: side) == nil ? 1 : 0) }
  }

  /// Whether the leaf renders any content on `side` at all (a fully pure-add block
  /// has no old-side content, so the old column collapses to a single buffer band).
  func hasContent(on side: DiffSide) -> Bool {
    pairs.contains { $0.line(on: side) != nil }
  }
}

/// Pure pairing helpers (no free functions — caseless enum namespace). The pairing
/// *policy* is IDENTICAL to `DiffRowBuilder.appendChanges:255-291` (the current,
/// tested behavior: git emits deletions then additions; align by index; leftovers
/// become one-sided gaps) so the unified↔split projections agree line-for-line.
/// IDs are minted through the shared `PairSequencer`, so a mode toggle keeps the
/// scroll anchor stable.
nonisolated enum AlignedPairing {
  /// Pair a change block. `max(del,add)` walk; leftover deletion ⇒ `(del,nil)`;
  /// leftover addition ⇒ `(nil,add)`.
  static func pairChange(
    deletions: [DiffLine],
    additions: [DiffLine],
    seq: inout PairSequencer
  ) -> AlignedPairChunk {
    let count = max(deletions.count, additions.count)
    var pairs: [AlignedPair] = []
    pairs.reserveCapacity(count)
    var index = 0
    while index < count {
      let left = index < deletions.count ? deletions[index] : nil
      let right = index < additions.count ? additions[index] : nil
      let id = seq.changeID(newLine: right?.newLineNumber, oldLine: left?.oldLineNumber)
      pairs.append(AlignedPair(left: left, right: right, pairID: id))
      index += 1
    }
    return AlignedPairChunk(pairs: pairs, unifiedLineCount: deletions.count + additions.count)
  }

  /// A context run: each line occupies BOTH sides — `(ctx, ctx)`.
  static func pairContext(_ lines: [DiffLine], seq: inout PairSequencer) -> AlignedPairChunk {
    let pairs = lines.map { line in
      AlignedPair(
        left: line, right: line,
        pairID: seq.contextID(newLine: line.newLineNumber, oldLine: line.oldLineNumber))
    }
    return AlignedPairChunk(pairs: pairs, unifiedLineCount: lines.count)
  }
}

extension LineSegment {
  /// The canonical aligned-pair projection of THIS tree leaf's window — the same
  /// nullable-pair shape the viewport renders, derived through `AlignedPairing`
  /// (change ⇒ `pairChange` over the window's deletions/additions; context ⇒
  /// `pairContext`). `splitLineCount == baseSummary().splitCount − noNewlineSplit`
  /// (markers are counted additively by `noNewlineCounts`, not as pairs), and
  /// `unifiedLineCount == baseSummary().unifiedCount − noNewlineUnified`.
  func alignedPairChunk(seq: inout PairSequencer) -> AlignedPairChunk {
    switch classification {
    case .context, .contextExpanded:
      return AlignedPairing.pairContext(Array(windowedLines), seq: &seq)
    case .change:
      return AlignedPairing.pairChange(deletions: windowDeletions, additions: windowAdditions, seq: &seq)
    }
  }
}
