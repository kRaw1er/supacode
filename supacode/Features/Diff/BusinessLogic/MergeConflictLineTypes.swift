import Foundation

/// The role a line plays inside a git conflict region (pierre B §22
/// `getMergeConflictLineTypes`). Content lines are `.current` (ours) / `.base`
/// (the 3-way merge base) / `.incoming` (theirs); the four `.marker*` cases are the
/// literal `<<<<<<<` / `|||||||` / `=======` / `>>>>>>>` lines; `.none` is any line
/// outside a conflict.
nonisolated enum MergeConflictLineType: Equatable, Sendable {
  case markerStart  // <<<<<<<  (ours header)
  case markerBase  // |||||||  (3-way merge-base header)
  case markerSeparator  // =======
  case markerEnd  // >>>>>>>  (theirs footer)
  case current  // ours   — between <<<<<<< and (||||||| | =======)
  case base  // base   — between ||||||| and =======  (3-way only)
  case incoming  // theirs — between ======= and >>>>>>>
  case none  // outside any conflict region
}

/// Which side of a conflict to keep when resolving.
nonisolated enum MergeConflictResolution: Equatable, Sendable {
  case current  // accept ours
  case incoming  // accept theirs
  case both  // keep ours then theirs (drop the 3-way base + all markers)
}

/// Pure conflict-marker parsing + resolution. Handles 2-way (`<<<<<<< / ======= /
/// >>>>>>>`), 3-way (`|||||||` base marker), and **nested** conflicts via a phase
/// stack — a `<<<<<<<` inside a region pushes a new frame whose phase governs the
/// inner content until its own `>>>>>>>` pops it. Static methods on a caseless
/// `enum` — no free functions. Git's default `conflict-marker-size` is 7.
nonisolated enum MergeConflict {
  static let markerLength = 7
  private static let startMarker = "<<<<<<<"
  private static let baseMarker = "|||||||"
  private static let separatorMarker = "======="
  private static let endMarker = ">>>>>>>"

  /// The active section of one (possibly nested) conflict frame.
  private enum Phase {
    case current, base, incoming
  }

  /// Classify every line of `lines` into its `MergeConflictLineType`. A line is a
  /// marker ONLY in a valid position — a `|||||||` / `=======` / `>>>>>>>` outside a
  /// conflict is ordinary content (`.none`), so a diff of a file that literally
  /// contains `=======` is not misread. A `<<<<<<<` always opens a region.
  static func lineTypes(_ lines: [String]) -> [MergeConflictLineType] {
    var stack: [Phase] = []
    var out: [MergeConflictLineType] = []
    out.reserveCapacity(lines.count)
    for line in lines {
      if line.hasPrefix(startMarker) {
        out.append(.markerStart)
        stack.append(.current)
      } else if !stack.isEmpty, line.hasPrefix(baseMarker) {
        out.append(.markerBase)
        stack[stack.count - 1] = .base
      } else if !stack.isEmpty, line.hasPrefix(separatorMarker) {
        out.append(.markerSeparator)
        stack[stack.count - 1] = .incoming
      } else if !stack.isEmpty, line.hasPrefix(endMarker) {
        out.append(.markerEnd)
        stack.removeLast()
      } else {
        switch stack.last {
        case .current: out.append(.current)
        case .base: out.append(.base)
        case .incoming: out.append(.incoming)
        case nil: out.append(.none)
        }
      }
    }
    return out
  }

  /// Whether `lines` contains at least one conflict region (a `<<<<<<<` with a
  /// matching `>>>>>>>`).
  static func hasConflict(_ lines: [String]) -> Bool {
    lineTypes(lines).contains(.markerEnd)
  }

  /// Resolve every conflict in `lines` by keeping one side, stripping ALL markers
  /// (including the 3-way base section) — the context-only result. Handles multiple
  /// conflicts in one hunk and nesting: a content line survives only when EVERY
  /// enclosing frame is in a kept phase, so an inner conflict inside a dropped outer
  /// section is dropped wholesale.
  static func resolve(_ lines: [String], keeping resolution: MergeConflictResolution) -> [String] {
    var stack: [Phase] = []
    var out: [String] = []
    for line in lines {
      if line.hasPrefix(startMarker) {
        stack.append(.current)
      } else if !stack.isEmpty, line.hasPrefix(baseMarker) {
        stack[stack.count - 1] = .base
      } else if !stack.isEmpty, line.hasPrefix(separatorMarker) {
        stack[stack.count - 1] = .incoming
      } else if !stack.isEmpty, line.hasPrefix(endMarker) {
        stack.removeLast()
      } else if stack.isEmpty {
        out.append(line)  // outside a conflict → context, always kept
      } else if stack.allSatisfy({ keeps(resolution, $0) }) {
        out.append(line)
      }
    }
    return out
  }

  private static func keeps(_ resolution: MergeConflictResolution, _ phase: Phase) -> Bool {
    switch resolution {
    case .current: phase == .current
    case .incoming: phase == .incoming
    case .both: phase == .current || phase == .incoming
    }
  }

  /// Whether every `<<<<<<<` in `lines` has a matching `>>>>>>>` (balanced markers,
  /// no underflow) and at least one region exists. An unbalanced region straddles a
  /// hunk boundary such that the ours/theirs split is ambiguous — accept is gated.
  static func markersAreBalanced(_ lines: [String]) -> Bool {
    var depth = 0
    var sawRegion = false
    for line in lines {
      if line.hasPrefix(startMarker) {
        depth += 1
        sawRegion = true
      } else if depth > 0, line.hasPrefix(endMarker) {
        depth -= 1
      }
    }
    return sawRegion && depth == 0
  }
}

/// A parsed conflict region ready for the `ConflictWidget`: the raw content lines
/// (markers included), whether the region straddles hunk boundaries (the "can't
/// anchor" guard reused from `CommentAnchor`), and the derived accept-eligibility.
/// Pure / `Sendable` — the widget renders it and the resolve is a `MergeConflict`
/// call.
nonisolated struct ConflictRegion: Equatable, Sendable {
  /// The region's content lines (each `DiffLine.content`), markers included.
  var lines: [String]
  /// The region's `DiffLine`s straddle more than one hunk, so the ours/theirs split
  /// is ambiguous — accept is disabled, "resolve in editor" is offered (gate, don't
  /// guess).
  var straddlesHunks: Bool

  /// Per-line classification (`MergeConflict.lineTypes`).
  var types: [MergeConflictLineType] { MergeConflict.lineTypes(lines) }

  /// A real, well-formed conflict is present.
  var hasConflict: Bool { MergeConflict.hasConflict(lines) }

  /// Accept-ours/theirs/both is offered ONLY when the region is a balanced conflict
  /// that does NOT straddle hunks (otherwise the split can't be anchored).
  var canAutoResolve: Bool { hasConflict && MergeConflict.markersAreBalanced(lines) && !straddlesHunks }

  /// The "ours" content lines (top-level `.current`).
  var currentLines: [String] { pick(.current) }
  /// The 3-way merge-base content lines (top-level `.base`), empty for a 2-way conflict.
  var baseLines: [String] { pick(.base) }
  /// The "theirs" content lines (top-level `.incoming`).
  var incomingLines: [String] { pick(.incoming) }

  /// The resolved, marker-stripped content for a resolution choice.
  func resolved(keeping resolution: MergeConflictResolution) -> [String] {
    MergeConflict.resolve(lines, keeping: resolution)
  }

  private func pick(_ type: MergeConflictLineType) -> [String] {
    zip(lines, types).compactMap { $1 == type ? $0 : nil }
  }

  /// Parse a hunk's `DiffLine`s into a region. `straddlesHunks` is supplied by the
  /// caller (the chunk-builder knows the hunk geometry).
  static func parse(_ diffLines: [DiffLine], straddlesHunks: Bool = false) -> ConflictRegion {
    ConflictRegion(lines: diffLines.map(\.content), straddlesHunks: straddlesHunks)
  }
}
