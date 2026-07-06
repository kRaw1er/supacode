import Foundation

/// Pure, side-effect-free translation of a file's hunks into the flat `[DiffRow]`
/// the virtualized viewer renders. Static methods on a caseless `enum` (no
/// top-level funcs). Determinism is the contract: the same inputs always yield
/// `==` rows, so two builds of an unchanged file produce an empty
/// `CollectionDifference` (a no-op apply).
enum DiffRowBuilder {
  /// Collapse tuning for a build.
  struct Options: Equatable, Sendable {
    /// A context run longer than this collapses.
    var collapseThreshold: Int
    /// Context lines kept on each side of a collapsed run.
    var edgeContext: Int
    /// New-file line count when known (enables the trailing-gap expander). `nil`
    /// in production today (`FileChange` carries no total), so the trailing gap
    /// is simply not surfaced — a best-effort affordance.
    var totalNewLines: Int?

    init(collapseThreshold: Int = 10, edgeContext: Int = 3, totalNewLines: Int? = nil) {
      self.collapseThreshold = collapseThreshold
      self.edgeContext = edgeContext
      self.totalNewLines = totalNewLines
    }
  }

  /// The `mode` + collapse inputs threaded through the hunk walk (keeps the
  /// per-helper parameter lists small).
  private struct Context {
    let mode: DiffViewMode
    let expanded: Set<Int>
    let collapseThreshold: Int
    let edgeContext: Int
  }

  /// Builds the row list. `comments` (Phase 5) are inserted as `.commentThread`
  /// rows immediately below their anchored line via a post-pass.
  static func build(
    file: FileChange,
    hunks: [DiffHunk],
    mode: DiffViewMode,
    expanded: Set<Int>,
    options: Options = Options(),
    comments: [ReviewComment] = []
  ) -> [DiffRow] {
    // 1. Cap / placeholder short-circuits (before any hunk walk).
    if file.isLargeFileCapped {
      return plainFallbackRows(hunks)
    }
    if file.isBinary || file.status == .binary {
      return [.placeholder(.binaryFile)]
    }
    if file.status == .submodule {
      return [.placeholder(.submodule(oldSHA: "", newSHA: ""))]
    }

    let hasContent = hunks.contains { !$0.lines.isEmpty }
    if !hasContent {
      switch file.status {
      case .deleted:
        return [.placeholder(.deletedFile)]
      case .modeChanged:
        return [.placeholder(.modeChangeOnly(oldMode: "", newMode: ""))]
      case .added, .untracked:
        return [.placeholder(.addedEmpty)]
      default:
        return [.placeholder(.noChanges)]
      }
    }

    let context = Context(
      mode: mode,
      expanded: expanded,
      collapseThreshold: options.collapseThreshold,
      edgeContext: options.edgeContext
    )
    var rows: [DiffRow] = []
    var pairSeq = PairSequencer()

    // 2. Leading gap: unshown region before the first hunk.
    if let first = hunks.first, first.newStart > 1 {
      appendGapExpander(&rows, anchor: 1, range: 1..<first.newStart, expanded: expanded)
    }

    for (index, hunk) in hunks.enumerated() {
      // 4. Between-hunk gap.
      if index > 0 {
        let prev = hunks[index - 1]
        let prevEnd = prev.newStart + prev.newCount
        if hunk.newStart > prevEnd {
          appendGapExpander(&rows, anchor: prevEnd, range: prevEnd..<hunk.newStart, expanded: expanded)
        }
      }

      // 3. Per hunk.
      rows.append(.hunkHeader(anchor: hunk.newStart, text: hunk.header))
      appendHunkBody(&rows, hunk: hunk, context: context, pairSeq: &pairSeq)
    }

    // 4. Trailing gap (only when the new-file line count is known).
    if let last = hunks.last, let total = options.totalNewLines {
      let lastEnd = last.newStart + last.newCount
      if total >= lastEnd {
        appendGapExpander(&rows, anchor: lastEnd, range: lastEnd..<(total + 1), expanded: expanded)
      }
    }

    return insertCommentThreads(rows, comments: comments)
  }

  // MARK: - Comment threads (Phase 5)

  /// Inserts a `.commentThread` row immediately after the last row whose
  /// `(side, gitLineNumber)` matches the comment's `endLine`. Following rows
  /// flow down natively (the table's per-row heights push content). A comment
  /// whose anchor row isn't present (e.g. collapsed) renders at the end so it
  /// is never silently dropped.
  private static func insertCommentThreads(_ rows: [DiffRow], comments: [ReviewComment]) -> [DiffRow] {
    guard !comments.isEmpty else { return rows }
    var byAnchor: [Int: [ReviewComment]] = [:]
    var trailing: [ReviewComment] = []
    for comment in comments.sorted(by: { $0.createdAt < $1.createdAt }) {
      if let index = lastRowIndex(in: rows, side: comment.side, line: comment.endLine) {
        byAnchor[index, default: []].append(comment)
      } else {
        trailing.append(comment)
      }
    }
    var result: [DiffRow] = []
    result.reserveCapacity(rows.count + comments.count)
    for (index, row) in rows.enumerated() {
      result.append(row)
      for comment in byAnchor[index] ?? [] {
        result.append(.commentThread(comment))
      }
    }
    for comment in trailing {
      result.append(.commentThread(comment))
    }
    return result
  }

  private static func lastRowIndex(in rows: [DiffRow], side: DiffSide, line: Int) -> Int? {
    var found: Int?
    for (index, row) in rows.enumerated() {
      switch row {
      case .line(let diffLine):
        if diffLine.lineNumber(on: side) == line { found = index }
      case .splitLine(_, let old, let new):
        let sideLine = side == .old ? old?.oldLineNumber : new?.newLineNumber
        if sideLine == line { found = index }
      default:
        break
      }
    }
    return found
  }

  // MARK: - Hunk body

  private static func appendHunkBody(
    _ rows: inout [DiffRow],
    hunk: DiffHunk,
    context: Context,
    pairSeq: inout PairSequencer
  ) {
    var contextBuffer: [DiffLine] = []
    var index = 0
    let lines = hunk.lines

    while index < lines.count {
      let line = lines[index]
      if line.origin == .context {
        contextBuffer.append(line)
        index += 1
        continue
      }
      // Flush any pending context run before the change block.
      flushContext(&rows, buffer: &contextBuffer, context: context, pairSeq: &pairSeq)
      // Gather a maximal change run (git emits deletions then additions).
      var deletions: [DiffLine] = []
      var additions: [DiffLine] = []
      while index < lines.count, lines[index].origin != .context {
        switch lines[index].origin {
        case .deletion: deletions.append(lines[index])
        case .addition: additions.append(lines[index])
        default: break
        }
        index += 1
      }
      appendChanges(&rows, deletions: deletions, additions: additions, mode: context.mode, pairSeq: &pairSeq)
    }

    flushContext(&rows, buffer: &contextBuffer, context: context, pairSeq: &pairSeq)
  }

  /// Emits a buffered context run, collapsing it into edge lines + an expander
  /// when it exceeds `collapseThreshold` and its anchor is not expanded.
  private static func flushContext(
    _ rows: inout [DiffRow],
    buffer: inout [DiffLine],
    context: Context,
    pairSeq: inout PairSequencer
  ) {
    defer { buffer.removeAll(keepingCapacity: true) }
    guard !buffer.isEmpty else { return }

    let edgeContext = context.edgeContext
    let anchor = buffer[edgeContext < buffer.count ? edgeContext : 0].newLineNumber ?? buffer[0].newLineNumber
    let shouldCollapse =
      buffer.count > context.collapseThreshold
      && (anchor.map { !context.expanded.contains($0) } ?? false)

    guard shouldCollapse, let anchor else {
      for line in buffer {
        appendContextLine(&rows, line: line, mode: context.mode, pairSeq: &pairSeq)
      }
      return
    }

    let head = buffer.prefix(edgeContext)
    let tail = buffer.suffix(edgeContext)
    let hiddenCount = buffer.count - 2 * edgeContext
    for line in head {
      appendContextLine(&rows, line: line, mode: context.mode, pairSeq: &pairSeq)
    }
    let hidden = buffer[edgeContext..<(buffer.count - edgeContext)]
    let firstHidden = hidden.first?.newLineNumber ?? anchor
    let lastHidden = hidden.last?.newLineNumber ?? anchor
    rows.append(
      .expander(anchor: anchor, collapsedRange: firstHidden..<(lastHidden + 1), hiddenCount: hiddenCount)
    )
    for line in tail {
      appendContextLine(&rows, line: line, mode: context.mode, pairSeq: &pairSeq)
    }
  }

  private static func appendContextLine(
    _ rows: inout [DiffRow],
    line: DiffLine,
    mode: DiffViewMode,
    pairSeq: inout PairSequencer
  ) {
    switch mode {
    case .unified:
      rows.append(.line(line))
      appendNoNewlineMarker(&rows, for: line, mode: mode, pairSeq: &pairSeq)
    case .split:
      let pairID = pairSeq.contextID(newLine: line.newLineNumber, oldLine: line.oldLineNumber)
      rows.append(.splitLine(pairID: pairID, old: line, new: line))
      appendNoNewlineMarker(&rows, for: line, mode: mode, pairSeq: &pairSeq)
    }
  }

  private static func appendChanges(
    _ rows: inout [DiffRow],
    deletions: [DiffLine],
    additions: [DiffLine],
    mode: DiffViewMode,
    pairSeq: inout PairSequencer
  ) {
    switch mode {
    case .unified:
      for line in deletions {
        rows.append(.line(line))
        appendNoNewlineMarker(&rows, for: line, mode: mode, pairSeq: &pairSeq)
      }
      for line in additions {
        rows.append(.line(line))
        appendNoNewlineMarker(&rows, for: line, mode: mode, pairSeq: &pairSeq)
      }
    case .split:
      let count = max(deletions.count, additions.count)
      var index = 0
      while index < count {
        let old = index < deletions.count ? deletions[index] : nil
        let new = index < additions.count ? additions[index] : nil
        let pairID = pairSeq.changeID(newLine: new?.newLineNumber, oldLine: old?.oldLineNumber)
        rows.append(.splitLine(pairID: pairID, old: old, new: new))
        if let old, old.noNewlineAtEof {
          rows.append(.splitLine(pairID: pairSeq.markerID(), old: Self.noNewlineLine(from: old), new: nil))
        }
        if let new, new.noNewlineAtEof {
          rows.append(.splitLine(pairID: pairSeq.markerID(), old: nil, new: Self.noNewlineLine(from: new)))
        }
        index += 1
      }
    }
  }

  /// Emits the muted "No newline at end of file" marker row after a content line
  /// that lacked a trailing newline.
  private static func appendNoNewlineMarker(
    _ rows: inout [DiffRow],
    for line: DiffLine,
    mode: DiffViewMode,
    pairSeq: inout PairSequencer
  ) {
    guard line.noNewlineAtEof else { return }
    let marker = Self.noNewlineLine(from: line)
    switch mode {
    case .unified:
      rows.append(.line(marker))
    case .split:
      // Attach to whichever side the content line belongs to.
      if line.newLineNumber != nil {
        rows.append(.splitLine(pairID: pairSeq.markerID(), old: nil, new: marker))
      } else {
        rows.append(.splitLine(pairID: pairSeq.markerID(), old: marker, new: nil))
      }
    }
  }

  private static func noNewlineLine(from line: DiffLine) -> DiffLine {
    DiffLine(
      origin: .noNewlineMarker,
      oldLineNumber: line.oldLineNumber,
      newLineNumber: line.newLineNumber,
      content: "No newline at end of file",
      noNewlineAtEof: false
    )
  }

  // MARK: - Gaps

  /// Emits an expander for an inter-hunk / leading / trailing gap, unless the
  /// user has expanded it (in which case the reducer re-diffs with raised
  /// context to materialize the real lines, so the builder emits nothing here).
  private static func appendGapExpander(
    _ rows: inout [DiffRow],
    anchor: Int,
    range: Range<Int>,
    expanded: Set<Int>
  ) {
    guard !range.isEmpty else { return }
    guard !expanded.contains(anchor) else { return }
    rows.append(.expander(anchor: anchor, collapsedRange: range, hiddenCount: range.count))
  }

  // MARK: - Large-file cap

  private static func plainFallbackRows(_ hunks: [DiffHunk]) -> [DiffRow] {
    var rows: [DiffRow] = []
    for hunk in hunks {
      for line in hunk.lines {
        let number = line.newLineNumber ?? line.oldLineNumber ?? 0
        rows.append(.plainFallback(lineNumber: number, text: line.content))
      }
    }
    return rows
  }
}
