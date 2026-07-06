import Foundation

/// Pure translation of a file's hunks into a dual-mode `ChunkTree`. Ports every
/// `DiffRowBuilder` case (cap / placeholders / gap-collapse / nullable split
/// pairs / no-newline marker / comment post-pass) but emits dense tree leaves +
/// dual-mode summaries instead of a flat `[DiffRow]`, and with **edgeContext = 1**
/// (C1). Determinism is the contract: the same inputs yield a structurally-equal
/// tree. Static methods on a caseless `enum` — no free functions.
enum ChunkTreeBuilder {
  /// Collapse + layout tuning for a build.
  nonisolated struct Options: Equatable, Sendable {
    var metrics: ChunkLayoutMetrics
    /// A context run longer than this collapses.
    var collapseThreshold: Int
    /// Context lines kept each side of a collapsed run. **C1: default 1.**
    var edgeContext: Int
    /// New-file line count when known (enables the trailing-gap expander).
    var totalNewLines: Int?
    /// Hunk-separator style used by the estimate (reduced 2-style set).
    var separatorStyle: HunkSeparatorStyle
    /// `ExpansionState.full` — render all context as rows, no separators.
    var expandUnchanged: Bool
    /// Suppress the leading `.widget(fileHeader)` leaf (top-region-only estimate).
    var disableFileHeader: Bool

    init(
      metrics: ChunkLayoutMetrics = .production,
      collapseThreshold: Int = 10,
      edgeContext: Int = 1,
      totalNewLines: Int? = nil,
      separatorStyle: HunkSeparatorStyle = .lineInfo,
      expandUnchanged: Bool = false,
      disableFileHeader: Bool = false
    ) {
      self.metrics = metrics
      self.collapseThreshold = collapseThreshold
      self.edgeContext = edgeContext
      self.totalNewLines = totalNewLines
      self.separatorStyle = separatorStyle
      self.expandUnchanged = expandUnchanged
      self.disableFileHeader = disableFileHeader
    }
  }

  /// Per-hunk rendered counts (pierre `unifiedLineCount` / `splitLineCount`, C6):
  /// `unified == deletions + additions + context`, `split == max(del,add) + context`.
  nonisolated struct HunkCounts: Equatable, Sendable {
    var context: Int
    var additions: Int
    var deletions: Int
    var unified: Int
    var split: Int
  }

  // MARK: - Build

  /// Build a single-file tree, then run the comment post-pass. `mode` is accepted
  /// for API fidelity but does NOT change the structure — the tree is dual-mode
  /// and answers seeks in either mode without a rebuild.
  static func build(
    file: FileChange,
    hunks: [DiffHunk],
    mode: DiffViewMode,
    expanded: Set<Int> = [],
    options: Options = Options(),
    comments: [ReviewComment] = []
  ) -> ChunkTree {
    let tree = ChunkTree(metrics: options.metrics)
    tree.diagnostics.buildRowsCallCount += 1
    appendFile(into: tree, file: file, hunks: hunks, expanded: expanded, options: options, comments: comments)
    insertComments(into: tree, comments: comments, options: options)
    return tree
  }

  /// Append one file's classified chunks (fileHeader → hunks) to an existing tree
  /// in document order — the multi-file assembly primitive. `comments` pins any
  /// commented line visible: a context run covering one is never folded into an
  /// expander (Phase 7 collapse guard).
  static func appendFile(
    into tree: ChunkTree,
    file: FileChange,
    hunks: [DiffHunk],
    expanded: Set<Int>,
    options: Options = Options(),
    comments: [ReviewComment] = []
  ) {
    var after: ChunkID? = tree.inorderNodes().last?.id
    for chunk in classify(file: file, hunks: hunks, expanded: expanded, options: options, comments: comments) {
      after = tree.insert(chunk, after: after)
    }
  }

  /// The ordered chunk list for a file (no comment post-pass). Exposed for tests.
  static func classify(
    file: FileChange,
    hunks: [DiffHunk],
    expanded: Set<Int>,
    options: Options = Options(),
    comments: [ReviewComment] = []
  ) -> [Chunk] {
    let fileID = file.id
    var chunks: [Chunk] = []
    if !options.disableFileHeader {
      chunks.append(fileHeaderWidget(fileID, options))
    }
    if file.isLargeFileCapped {
      chunks.append(contentsOf: plainFallbackChunks(hunks, fileID: fileID, options))
      return chunks
    }
    if file.isBinary || file.status == .binary {
      chunks.append(placeholderWidget(.binaryFile, fileID, options))
      return chunks
    }
    if file.status == .submodule {
      chunks.append(placeholderWidget(.submodule(oldSHA: "", newSHA: ""), fileID, options))
      return chunks
    }
    if !hunks.contains(where: { !$0.lines.isEmpty }) {
      chunks.append(placeholderWidget(emptyPlaceholder(for: file.status), fileID, options))
      return chunks
    }
    appendHunks(
      &chunks, hunks: hunks,
      context: BuildContext(
        fileID: fileID, expanded: expanded, options: options, commented: CommentedLines.from(comments)))
    return chunks
  }

  /// The per-file inputs threaded through the hunk walk (keeps helper parameter
  /// lists small).
  private struct BuildContext {
    let fileID: FileID
    let expanded: Set<Int>
    let options: Options
    let commented: CommentedLines
  }

  /// The set of line numbers (per side) covered by a comment — the collapse guard
  /// consults it so a commented line is never folded into an expander (pinned
  /// visible; Phase 7, coordinating with Phase 6's `comments` source of truth).
  struct CommentedLines: Equatable, Sendable {
    var old: Set<Int> = []
    var new: Set<Int> = []

    var isEmpty: Bool { old.isEmpty && new.isEmpty }

    /// Whether `line` carries a comment on either side.
    func covers(_ line: DiffLine) -> Bool {
      (line.newLineNumber.map(new.contains) ?? false) || (line.oldLineNumber.map(old.contains) ?? false)
    }

    static func from(_ comments: [ReviewComment]) -> CommentedLines {
      var result = CommentedLines()
      for comment in comments {
        let lower = min(comment.startLine, comment.endLine)
        let upper = max(comment.startLine, comment.endLine)
        guard lower <= upper else { continue }
        switch comment.side {
        case .old: result.old.formUnion(lower...upper)
        case .new: result.new.formUnion(lower...upper)
        }
      }
      return result
    }
  }

  // MARK: - Hunk walk

  private static func appendHunks(_ chunks: inout [Chunk], hunks: [DiffHunk], context: BuildContext) {
    if let first = hunks.first, first.newStart > 1 {
      appendGap(&chunks, hunkIndex: 0, anchor: 1, range: 1..<first.newStart, context: context)
    }
    for (index, hunk) in hunks.enumerated() {
      if index > 0 {
        let prev = hunks[index - 1]
        let prevEnd = prev.newStart + prev.newCount
        if hunk.newStart > prevEnd {
          appendGap(&chunks, hunkIndex: index, anchor: prevEnd, range: prevEnd..<hunk.newStart, context: context)
        }
      }
      chunks.append(hunkHeaderWidget(context.fileID, index, hunk, context.options))
      appendHunkBody(&chunks, hunkIndex: index, hunk: hunk, context: context)
    }
    if let last = hunks.last, let total = context.options.totalNewLines {
      let lastEnd = last.newStart + last.newCount
      if total >= lastEnd {
        appendGap(&chunks, hunkIndex: hunks.count, anchor: lastEnd, range: lastEnd..<(total + 1), context: context)
      }
    }
  }

  private static func appendHunkBody(_ chunks: inout [Chunk], hunkIndex: Int, hunk: DiffHunk, context: BuildContext) {
    let hunkID = HunkID(fileID: context.fileID, index: hunkIndex)
    var contextBuffer: [DiffLine] = []
    var index = 0
    let lines = hunk.lines
    while index < lines.count {
      if lines[index].origin == .context {
        contextBuffer.append(lines[index])
        index += 1
        continue
      }
      flushContext(&chunks, buffer: &contextBuffer, hunkID: hunkID, context: context)
      var run: [DiffLine] = []
      while index < lines.count, lines[index].origin != .context {
        if lines[index].origin == .deletion || lines[index].origin == .addition {
          run.append(lines[index])
        }
        index += 1
      }
      appendChange(&chunks, run: run, hunkID: hunkID)
    }
    flushContext(&chunks, buffer: &contextBuffer, hunkID: hunkID, context: context)
  }

  /// Emit a change block as one (or maxLeafSpan-capped) `.lineSegment(.change)`.
  /// Lines are canonicalized deletions-then-additions so the window slice rebuilds
  /// aligned pairs.
  private static func appendChange(_ chunks: inout [Chunk], run: [DiffLine], hunkID: HunkID) {
    let ordered = run.filter { $0.origin == .deletion } + run.filter { $0.origin == .addition }
    guard !ordered.isEmpty else { return }
    appendSegments(&chunks, lines: ordered, hunkID: hunkID, classification: .change)
  }

  /// Emit a buffered context run, collapsing when it exceeds `collapseThreshold`
  /// and its anchor is neither expanded nor `expandUnchanged` — keeping
  /// `edgeContext` (C1: 1) lines each side.
  private static func flushContext(
    _ chunks: inout [Chunk],
    buffer: inout [DiffLine],
    hunkID: HunkID,
    context: BuildContext
  ) {
    defer { buffer.removeAll(keepingCapacity: true) }
    guard !buffer.isEmpty else { return }
    let edge = context.options.edgeContext
    let anchorIndex = edge < buffer.count ? edge : 0
    let anchor = buffer[anchorIndex].newLineNumber ?? buffer[0].newLineNumber
    // AND-in `!hasComment(in: run)` (Phase 7): a context run covering a commented
    // line is rendered in full so the commented line is never hidden by a collapse.
    let coversComment = !context.commented.isEmpty && buffer.contains(where: context.commented.covers)
    let wouldCollapse =
      buffer.count > context.options.collapseThreshold && !context.options.expandUnchanged && !coversComment
    guard wouldCollapse, let anchor else {
      appendSegments(&chunks, lines: buffer, hunkID: hunkID, classification: .context)
      return
    }
    if context.expanded.contains(anchor) {
      appendSegments(&chunks, lines: buffer, hunkID: hunkID, classification: .contextExpanded)
      return
    }
    let head = Array(buffer.prefix(edge))
    let tail = Array(buffer.suffix(edge))
    let hidden = buffer.count - 2 * edge
    if !head.isEmpty { appendSegments(&chunks, lines: head, hunkID: hunkID, classification: .context) }
    let hiddenSlice = buffer[edge..<(buffer.count - edge)]
    let firstHidden = hiddenSlice.first?.newLineNumber ?? anchor
    let lastHidden = hiddenSlice.last?.newLineNumber ?? anchor
    chunks.append(
      expanderWidget(
        hunkIndex: hunkID.index, anchor: anchor, range: firstHidden..<(lastHidden + 1), hidden: hidden,
        context.options)
    )
    if !tail.isEmpty { appendSegments(&chunks, lines: tail, hunkID: hunkID, classification: .context) }
  }

  /// Split a dense run into `≤ maxLeafSpan` leaves over a shared COW backing.
  private static func appendSegments(
    _ chunks: inout [Chunk],
    lines: [DiffLine],
    hunkID: HunkID,
    classification: SegmentClass
  ) {
    let span = ChunkLayoutMetrics.maxLeafSpan
    var low = 0
    while low < lines.count {
      let high = min(low + span, lines.count)
      chunks.append(
        .lineSegment(LineSegment(hunkID: hunkID, lines: lines, window: low..<high, classification: classification)))
      low = high
    }
  }

  private static func appendGap(
    _ chunks: inout [Chunk],
    hunkIndex: Int,
    anchor: Int,
    range: Range<Int>,
    context: BuildContext
  ) {
    guard !range.isEmpty, !context.expanded.contains(anchor) else { return }
    chunks.append(
      expanderWidget(hunkIndex: hunkIndex, anchor: anchor, range: range, hidden: range.count, context.options))
  }
}
