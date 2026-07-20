import Foundation
import Synchronization

// MARK: - Stable identities

/// The KEPT file identity — `FileChange.ID` (the new path, falling back to the
/// old path for a deletion). Used by `WidgetKey.fileHeader` / `.placeholder` /
/// `.plainFallback` and by the tree's `offsetForFile(_:mode:)` file-nav seek.
typealias FileID = FileChange.ID

/// Stable per-hunk identity — `(fileID, index)`. A re-diff shifts a hunk's line
/// numbers but not its position among the file's hunks, so the index is the
/// reconcile-safe key (used by `LineSegment.hunkID`, `WidgetKey.hunkHeader`,
/// `WidgetKey.noNewlineMarker`). NOT the raw line numbers (those move on edit).
nonisolated struct HunkID: Hashable, Sendable {
  var fileID: FileID
  var index: Int
}

/// Per-node identity, unique for the lifetime of the process. NOT `WidgetKey` —
/// `WidgetKey` resolves the MODEL, `ChunkID` addresses a NODE.
///
/// **A `ChunkID` must never outlive the tree that minted it.** It answers "which
/// node", not "which content", so it is meaningless against any other tree —
/// anything that has to survive a re-projection (a scroll anchor, a measured
/// height, a gap's revealed nodes) keys off a domain identity instead:
/// `WidgetKey`, `HunkID`, `GapKey`, or a `(lineNumber, side)` pair.
///
/// Ids are allocated from ONE process-wide counter rather than per-tree, so that
/// rule is enforced by construction: an id from a stale tree can never collide
/// with a live node, it simply misses. (Per-tree numbering made every stale id
/// address an unrelated node, which is how re-applying an expansion after a
/// rebuild silently deleted whatever had inherited those ids.) There is
/// deliberately no public initializer — `allocate()` is the only source, so an id
/// can never be conjured to match something.
nonisolated struct ChunkID: Hashable, Sendable {
  let raw: UInt64

  private init(raw: UInt64) {
    self.raw = raw
  }

  private static let counter = Atomic<UInt64>(0)

  /// Mint a fresh id. Monotonic and never reused within the process.
  static func allocate() -> ChunkID {
    ChunkID(raw: counter.wrappingAdd(1, ordering: .relaxed).newValue)
  }
}

// MARK: - Chunk (C3 descriptor #2 — render / chunk kind)

/// One tree leaf. Two kinds only; everything sparse is a `.widget` (S12: there
/// is NO `.commentThread` Chunk case — a comment IS a `.widget`).
nonisolated enum Chunk: Equatable, Sendable {
  case lineSegment(LineSegment)  // dense run of a hunk's diff lines (≤ maxLeafSpan)
  case widget(Widget)  // singleton: fileHeader / hunkHeader / expander / comment / placeholder

  /// Unified recycling-pool selector (Phase 2 keys one `ViewReuseQueue` per case).
  /// This is the `DiffReuseKind` Phase 2 reads off `hit.chunk.reuseKind`.
  var reuseKind: DiffReuseKind {
    switch self {
    case .lineSegment: .line
    case .widget(let widget): .widget(widget.reuseKind)
    }
  }

  /// The dense run, when this leaf is a line segment.
  var lineSegment: LineSegment? {
    if case .lineSegment(let segment) = self { return segment }
    return nil
  }

  /// The sparse singleton, when this leaf is a widget.
  var widget: Widget? {
    if case .widget(let widget) = self { return widget }
    return nil
  }

  /// The document region this leaf belongs to, when it belongs to one. A gap's
  /// expander is part of its gap, so removing the region takes the expander with it.
  var region: RegionKey? {
    switch self {
    case .lineSegment(let segment): segment.region
    case .widget(let widget): if case .expander(let gap) = widget.key { .gap(gap) } else { nil }
    }
  }
}

/// The viewport's pool selector = `.line` (dense code rows) ∪ every
/// `WidgetReuseKind`. **Phase 1 OWNS this**; Phase 2's `DiffReuseKind` IS this.
/// The per-pool key is the hit's `ChunkID` (`hit.id`), NOT `WidgetKey`.
nonisolated enum DiffReuseKind: Hashable, Sendable {
  case line
  case widget(WidgetReuseKind)
}

// MARK: - LineSegment (C3 descriptor #1 lives here as `classification`)

/// Which region of the document a leaf belongs to: a hunk's own lines, or the
/// revealed slice of a collapsed gap.
///
/// This is what lets the tree answer "which nodes make up gap G" on demand. The
/// alternative — caching the gap's `ChunkID`s outside the tree — cannot survive a
/// re-projection and goes stale silently, so the region is carried BY the leaf and
/// indexed BY the tree, and the two can never disagree.
nonisolated enum RegionKey: Hashable, Sendable {
  case hunk(HunkID)
  case gap(GapKey)

  var fileID: FileID {
    switch self {
    case .hunk(let hunkID): hunkID.fileID
    case .gap(let gap): gap.fileID
    }
  }
}

/// A dense run. `lines` is the shared COW backing; `window` narrows it so a
/// split is O(1) (two windows) and never copies lines. Per-line numbering is
/// intrinsic to each `DiffLine`, so a mid-run split needs no renumber.
nonisolated struct LineSegment: Equatable, Sendable {
  var region: RegionKey  // which hunk / gap these lines belong to
  var lines: [DiffLine]  // KEPT DiffModels type — shared backing
  var window: Range<Int>  // sub-range of `lines` this leaf renders
  var classification: SegmentClass  // C3 descriptor #1

  init(region: RegionKey, lines: [DiffLine], window: Range<Int>, classification: SegmentClass) {
    self.region = region
    self.lines = lines
    self.window = window
    self.classification = classification
  }

  init(hunkID: HunkID, lines: [DiffLine], window: Range<Int>, classification: SegmentClass) {
    self.init(region: .hunk(hunkID), lines: lines, window: window, classification: classification)
  }

  /// Stable per-hunk identity (reconcile hook, re-diff). A revealed gap slice
  /// reports the hunk it sits before, which is the coordinate its blobs and its
  /// render keys are resolved in.
  var hunkID: HunkID {
    switch region {
    case .hunk(let hunkID): hunkID
    case .gap(let gap): HunkID(fileID: gap.fileID, index: gap.hunkIndex)
    }
  }

  /// The lines this leaf actually renders (its window slice).
  var windowedLines: ArraySlice<DiffLine> { lines[window] }
}

/// Segment classification (pierre `type: 'change' | 'context' | 'context-expanded'`).
/// One of the **three** C3 descriptors kept deliberately distinct — never folded
/// into `Chunk` kind or `ScrollTarget`.
nonisolated enum SegmentClass: Equatable, Sendable {
  case context
  case contextExpanded
  case change
}

// MARK: - Widget (sparse singleton)

/// Sparse singleton. Carries ONLY scalars/enums; rich content is a side cache
/// (comment body lives in the reducer, resolved by `key`). `estimatedHeight`
/// MUST be set (CM6 rule) or the scrollbar is wrong offscreen.
nonisolated struct Widget: Equatable, Sendable {
  var key: WidgetKey  // per-instance identity the harness resolves the MODEL with
  var estimatedHeight: CGFloat  // CM6: required or scrollbar is wrong offscreen
  var payload: WidgetPayload

  init(key: WidgetKey, estimatedHeight: CGFloat, payload: WidgetPayload) {
    self.key = key
    self.estimatedHeight = estimatedHeight
    self.payload = payload
  }

  /// Recycling-pool selector (Phase 2). Derived from `key` so it can never drift.
  var reuseKind: WidgetReuseKind { key.reuseKind }
}

/// Recycling-pool selector (shared across instances of a kind). **Phase 1 OWNS
/// this enum** — Phase 2 keys one `ViewReuseQueue` per case; Phase 6 consumes it.
nonisolated enum WidgetReuseKind: Hashable, Sendable {
  case fileHeader
  case hunkHeader
  case expander
  case commentThread
  case placeholder
  case noNewlineMarker
  case plainFallback
}

/// Per-instance identity the widget harness resolves the widget MODEL with (S1,
/// Phase-6 D3). **Phase 1 OWNS this** so every `.widget` leaf carries a stable id
/// while the tree stays "scalars only".
nonisolated enum WidgetKey: Hashable, Sendable {
  case fileHeader(fileID: FileID)
  case hunkHeader(hunkID: HunkID)
  case expander(GapKey)  // gap identity (survives re-diff)
  case commentThread(anchorID: UUID)
  case placeholder(fileID: FileID)
  case noNewlineMarker(hunkID: HunkID, side: DiffSide)
  case plainFallback(fileID: FileID, run: Int)

  var reuseKind: WidgetReuseKind {
    switch self {
    case .fileHeader: .fileHeader
    case .hunkHeader: .hunkHeader
    case .expander: .expander
    case .commentThread: .commentThread
    case .placeholder: .placeholder
    case .noNewlineMarker: .noNewlineMarker
    case .plainFallback: .plainFallback
    }
  }
}

/// Gap identity — pierre's **hunk-index** keying, which survives a re-diff (an
/// edit shifts line numbers but not a gap's index). **Phase 1 OWNS `GapKey`**
/// (S13): the collapsed gap BEFORE hunk `i` has `hunkIndex == i`; the trailing
/// gap after the last hunk has `hunkIndex == hunks.count` (upward-only). Phase 7's
/// `ExpansionState.regions` is keyed by `GapKey.hunkIndex`.
nonisolated struct GapKey: Hashable, Sendable {
  /// The file the gap belongs to. Without it two files' gaps at the same hunk
  /// index share a `WidgetKey.expander`, which collides in the widget index of a
  /// multi-file tree (the one-long-feed layout) — the expander of one file would
  /// resolve, measure and expand against the other's node.
  var fileID: FileID
  var hunkIndex: Int
}

/// The scalar payload of a `.widget` leaf. Rich content (comment body, file-header
/// model) is a side cache resolved by `Widget.key`; only identity + render-cheap
/// scalars live here so the tree stays scalars-only.
nonisolated enum WidgetPayload: Equatable, Sendable {
  case fileHeader(fileID: FileID)
  case hunkHeader(anchor: Int, text: String)
  case expander(anchor: Int, range: Range<Int>, hidden: Int)
  case placeholder(FilePlaceholder)
  case commentThread(anchorID: UUID)
  case noNewlineMarker(side: DiffSide)
  case plainFallback(lineNumber: Int, text: String)
}

// MARK: - ScrollTarget (C3 descriptor #3)

/// Scroll-target descriptor (pierre row types `position / line / range / gap`).
/// The **third** distinct C3 descriptor — a scroll intent, resolved by the tree
/// into a `y` at seek time. Never folded into `SegmentClass` or `Chunk` kind.
nonisolated enum ScrollTarget: Equatable, Sendable {
  case position(yOffset: CGFloat)
  case line(number: Int, side: DiffSide)
  case range(Range<Int>, side: DiffSide)
  case gap(GapKey)
}
