import Foundation

// MARK: - Widget constructors & placeholders

extension ChunkTreeBuilder {
  static func fileHeaderWidget(_ fileID: FileID, _ options: Options) -> Chunk {
    .widget(
      Widget(
        key: .fileHeader(fileID: fileID),
        estimatedHeight: options.metrics.diffHeaderHeight,
        payload: .fileHeader(fileID: fileID)
      )
    )
  }

  static func hunkHeaderWidget(_ fileID: FileID, _ index: Int, _ hunk: DiffHunk, _ options: Options) -> Chunk {
    .widget(
      Widget(
        key: .hunkHeader(hunkID: HunkID(fileID: fileID, index: index)),
        estimatedHeight: options.metrics.separatorHeight,
        payload: .hunkHeader(anchor: hunk.newStart, text: hunk.header)
      )
    )
  }

  static func expanderWidget(
    hunkIndex: Int,
    anchor: Int,
    range: Range<Int>,
    hidden: Int,
    _ options: Options
  ) -> Chunk {
    .widget(
      Widget(
        key: .expander(GapKey(hunkIndex: hunkIndex)),
        estimatedHeight: options.metrics.expanderHeight,
        payload: .expander(anchor: anchor, range: range, hidden: hidden)
      )
    )
  }

  static func placeholderWidget(_ placeholder: FilePlaceholder, _ fileID: FileID, _ options: Options) -> Chunk {
    .widget(
      Widget(
        key: .placeholder(fileID: fileID),
        estimatedHeight: options.metrics.placeholderHeight,
        payload: .placeholder(placeholder)
      )
    )
  }

  static func plainFallbackChunks(_ hunks: [DiffHunk], fileID: FileID, _ options: Options) -> [Chunk] {
    var chunks: [Chunk] = []
    var run = 0
    for hunk in hunks {
      for line in hunk.lines {
        let number = line.newLineNumber ?? line.oldLineNumber ?? 0
        chunks.append(
          .widget(
            Widget(
              key: .plainFallback(fileID: fileID, run: run),
              estimatedHeight: options.metrics.lineHeight,
              payload: .plainFallback(lineNumber: number, text: line.content)
            )
          )
        )
        run += 1
      }
    }
    return chunks
  }

  /// Whether the file's path carries a raster-image extension — the classifier
  /// routes such a binary to the `ImageCompareWidget` (⚠️ note 1) instead of the
  /// plain binary summary. Case-insensitive; keyed on the new path (falling back to
  /// the old for a deletion).
  static let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "ico", "icns",
  ]

  static func isImagePath(_ file: FileChange) -> Bool {
    let path = file.newPath ?? file.oldPath ?? file.id
    guard let dot = path.lastIndex(of: ".") else { return false }
    let ext = path[path.index(after: dot)...].lowercased()
    return imageExtensions.contains(ext)
  }

  /// The empty-content placeholder for a file with no hunk lines (`ChunkTreeBuilder`
  /// legacy `:57-69`).
  static func emptyPlaceholder(for status: FileStatus) -> FilePlaceholder {
    switch status {
    case .deleted: .deletedFile
    case .modeChanged: .modeChangeOnly(oldMode: "", newMode: "")
    case .added, .untracked: .addedEmpty
    default: .noChanges
    }
  }
}

// MARK: - Comment post-pass (splits after the anchor row, S/Phase-6)

extension ChunkTreeBuilder {
  /// Insert each comment as a `.widget(commentThread)` immediately after its
  /// anchor row: split the anchor's segment after the anchored line and slot the
  /// widget between. A comment whose anchor isn't present appends at the end
  /// (never silently dropped). Older comments insert first (createdAt order).
  static func insertComments(into tree: ChunkTree, comments: [ReviewComment], options: Options) {
    guard !comments.isEmpty else { return }
    for comment in comments.sorted(by: { $0.createdAt < $1.createdAt }) {
      insertComment(into: tree, comment: comment, options: options)
    }
  }

  private static func insertComment(into tree: ChunkTree, comment: ReviewComment, options: Options) {
    let widget = commentWidget(comment, options)
    guard let anchor = findAnchor(in: tree, comment: comment) else {
      tree.insert(widget, after: tree.inorderNodes().last?.id)
      return
    }
    if anchor.isLastLine {
      tree.insert(widget, after: anchor.nodeID)
    } else {
      let (left, _) = tree.split(anchor.nodeID, atLocalRow: anchor.windowOffset)
      tree.insert(widget, after: left)
    }
  }

  private struct AnchorMatch {
    var nodeID: ChunkID
    var windowOffset: Int  // split at this window offset (line index + 1)
    var isLastLine: Bool  // anchor is the last line of its segment → insert-after, no split
  }

  /// The LAST segment line matching `(side, endLine)` in document order (mirrors
  /// `DiffRowBuilder.lastRowIndex`).
  private static func findAnchor(in tree: ChunkTree, comment: ReviewComment) -> AnchorMatch? {
    var match: AnchorMatch?
    for node in tree.inorderNodes() {
      guard let segment = node.chunk.lineSegment else { continue }
      let lines = Array(segment.windowedLines)
      for (offset, line) in lines.enumerated() where line.origin != .noNewlineMarker {
        if line.lineNumber(on: comment.side) == comment.endLine {
          match = AnchorMatch(nodeID: node.id, windowOffset: offset + 1, isLastLine: offset == lines.count - 1)
        }
      }
    }
    return match
  }

  static func commentWidget(_ comment: ReviewComment, _ options: Options) -> Chunk {
    .widget(
      Widget(
        key: .commentThread(anchorID: comment.id),
        estimatedHeight: options.metrics.commentThreadHeight,
        payload: .commentThread(anchorID: comment.id)
      )
    )
  }
}

// MARK: - Estimate arithmetic & count oracle (pierre ports)

extension ChunkTreeBuilder {
  /// Per-hunk rendered counts (pierre `unifiedLineCount` / `splitLineCount`, C6).
  static func hunkCounts(_ hunk: DiffHunk) -> HunkCounts {
    let context = hunk.lines.filter { $0.origin == .context }.count
    let additions = hunk.lines.filter { $0.origin == .addition }.count
    let deletions = hunk.lines.filter { $0.origin == .deletion }.count
    return HunkCounts(
      context: context,
      additions: additions,
      deletions: deletions,
      unified: context + additions + deletions,
      split: context + max(additions, deletions)
    )
  }

  /// The no-newline metadata-row counts for a file (pierre
  /// `getNoNewlineMetadataLineCounts`): unified counts one per flagged side; split
  /// shares a single row per aligned pair with any flagged side.
  static func noNewlineMetadataCounts(_ hunks: [DiffHunk]) -> (split: Int, unified: Int) {
    var split = 0
    var unified = 0
    for hunk in hunks {
      let dels = hunk.lines.filter { $0.origin == .deletion }
      let adds = hunk.lines.filter { $0.origin == .addition }
      unified += dels.filter(\.noNewlineAtEof).count + adds.filter(\.noNewlineAtEof).count
      for index in 0..<max(dels.count, adds.count) {
        let oldFlagged = index < dels.count && dels[index].noNewlineAtEof
        let newFlagged = index < adds.count && adds[index].noNewlineAtEof
        if oldFlagged || newFlagged { split += 1 }
      }
      for line in hunk.lines where line.origin == .context && line.noNewlineAtEof {
        unified += 1
        split += 1
      }
    }
    return (split, unified)
  }

  /// Hunk-separator estimate height by position + style (the **reduced** 2-style
  /// set; GAP §4.3). `lineInfo` reserves spacing + a rule body; `simple` reserves
  /// only a thin middle rule.
  static func separatorHeight(_ position: SeparatorPosition, style: HunkSeparatorStyle, metrics: ChunkLayoutMetrics)
    -> CGFloat
  {
    switch style {
    case .lineInfo:
      switch position {
      case .first: return metrics.separatorHeight + metrics.spacing
      case .middle: return metrics.spacing + metrics.separatorHeight + metrics.spacing
      case .trailing: return metrics.spacing + metrics.separatorHeight
      }
    case .simple:
      switch position {
      case .first, .trailing: return 0
      case .middle: return metrics.simpleSeparatorHeight
      }
    }
  }

  /// Up-front dual-mode estimate (pierre `computeEstimatedDiffHeights`): top region
  /// + rows×lineHeight + no-newline metadata rows + collapsed-gap separators +
  /// paddingBottom (paddingBottom skipped entirely for a no-hunk diff).
  static func estimatedHeights(file: FileChange, hunks: [DiffHunk], options: Options = Options())
    -> (split: CGFloat, unified: CGFloat)
  {
    let metrics = options.metrics
    let topRegion = options.disableFileHeader ? metrics.paddingTop : metrics.diffHeaderHeight + metrics.paddingTop
    guard hunks.contains(where: { !$0.lines.isEmpty }) else { return (topRegion, topRegion) }

    var splitRows = 0
    var unifiedRows = 0
    for hunk in hunks {
      let counts = hunkCounts(hunk)
      splitRows += counts.split
      unifiedRows += counts.unified
    }
    let metadata = noNewlineMetadataCounts(hunks)
    splitRows += metadata.split
    unifiedRows += metadata.unified

    var split = topRegion + CGFloat(splitRows) * metrics.lineHeight + metrics.paddingBottom
    var unified = topRegion + CGFloat(unifiedRows) * metrics.lineHeight + metrics.paddingBottom
    if !options.expandUnchanged {
      let separators = separatorTotal(hunks: hunks, options: options)
      split += separators
      unified += separators
    }
    return (split, unified)
  }

  /// The total collapsed-gap separator reservation (leading / between / trailing).
  private static func separatorTotal(hunks: [DiffHunk], options: Options) -> CGFloat {
    guard let first = hunks.first else { return 0 }
    let metrics = options.metrics
    let style = options.separatorStyle
    var total: CGFloat = 0
    if first.newStart > 1 { total += separatorHeight(.first, style: style, metrics: metrics) }
    for index in 1..<max(hunks.count, 1) {
      let prev = hunks[index - 1]
      let prevEnd = prev.newStart + prev.newCount
      if hunks[index].newStart > prevEnd { total += separatorHeight(.middle, style: style, metrics: metrics) }
    }
    if let total2 = options.totalNewLines, let last = hunks.last {
      let lastEnd = last.newStart + last.newCount
      if total2 >= lastEnd { total += separatorHeight(.trailing, style: style, metrics: metrics) }
    }
    return total
  }

  /// A second, independent implementation of the parser's count arithmetic (pierre
  /// `verifyHunkLineValues`): `newCount == additions + context`, `oldCount ==
  /// deletions + context`, and `collapsedBefore == max(newStart − 1 − lastEnd, 0)`
  /// stays non-negative. Returns `[]` when consistent.
  static func verifyHunkLineValues(_ hunks: [DiffHunk]) -> [String] {
    var issues: [String] = []
    var lastAdditionEnd = 0
    for (index, hunk) in hunks.enumerated() {
      let counts = hunkCounts(hunk)
      if counts.additions + counts.context != hunk.newCount {
        issues.append(
          "hunk \(index): newCount \(hunk.newCount) != additions+context \(counts.additions + counts.context)")
      }
      if counts.deletions + counts.context != hunk.oldCount {
        issues.append(
          "hunk \(index): oldCount \(hunk.oldCount) != deletions+context \(counts.deletions + counts.context)")
      }
      let collapsedBefore = hunk.newStart - 1 - lastAdditionEnd
      if collapsedBefore < 0 {
        issues.append("hunk \(index): negative collapsedBefore \(collapsedBefore)")
      }
      lastAdditionEnd = hunk.newStart + hunk.newCount - 1
    }
    return issues
  }
}
