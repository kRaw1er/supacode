import AppKit

/// The AppKit engine behind the diff viewer: a view-based `NSTableView` in an
/// `NSScrollView` with strict viewport virtualization (cell recycling via
/// `makeView(withIdentifier:owner:)`) and O(1) fixed row heights from the
/// `heightOfRow` delegate — never `usesAutomaticRowHeights`, never a retain-all
/// `LazyVStack`. A single full-width column carries every row kind; split mode
/// draws its two panes *inside* the `.splitLine` cell (structural, pixel-exact
/// alignment) rather than fighting two column geometries for full-width headers.
///
/// `@MainActor` per CLAUDE.md (`@Observable`/UI-owning types are main-actor).
@MainActor
final class DiffTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  let scrollView: NSScrollView
  private let tableView: NSTableView
  private var rows: [DiffRow] = []
  private var mode: DiffViewMode = .unified
  private var metrics: DiffMetrics
  private nonisolated(unsafe) var boundsObserver: NSObjectProtocol?
  private var lastVisibleRange: Range<Int> = 0..<0

  /// Syntax foreground spans keyed by new-side (1-based) line number. Populated
  /// asynchronously by the highlighter; a re-diff or mode switch keeps it (spans
  /// are re-requested for the fresh viewport).
  private var syntaxByLine: [Int: [SyntaxHighlighter.HighlightSpan]] = [:]
  /// Unified word-diff pairing: for a change `.line` row, the counterpart side's
  /// content. Recomputed on every `apply` (cheap — it stores references, no diff).
  private var counterpartByRow: [Int: String] = [:]
  /// Lazily computed, per-row word-diff spans (keyed by row index; cleared on
  /// `apply`). Computed on demand as rows become visible.
  private var wordDiffCache: [Int: (old: [WordDiff.Span], new: [WordDiff.Span])] = [:]

  /// Fired on every clip-view bounds change so Phase 4 can style only the rows
  /// currently on screen.
  var onVisibleRangeChanged: ((Range<Int>) -> Void)?
  /// Fired when the user clicks an expander (anchor of the collapsed region).
  var onExpandGap: ((Int) -> Void)?
  /// Fired when the user clicks an inline comment thread row (opens it to edit).
  var onCommentTap: ((UUID) -> Void)?
  /// Fired when the gutter ribbon resolves a click / drag range to comment on.
  var onOpenComposer:
    ((_ side: DiffSide, _ startLine: Int, _ endLine: Int, _ snippet: String, _ contextBefore: String) -> Void)?

  /// The transparent gutter overlay owning the "+"/drag interaction (Phase 5).
  private let ribbon = DiffGutterRibbonView()

  private static let cellIdentifier = NSUserInterfaceItemIdentifier("diff.cell")
  private static let columnIdentifier = NSUserInterfaceItemIdentifier("diff.code")

  override init() {
    metrics = DiffMetrics.resolve()
    let table = NSTableView()
    let scroll = NSScrollView()
    tableView = table
    scrollView = scroll
    super.init()

    table.headerView = nil
    table.style = .plain
    table.selectionHighlightStyle = .none
    table.gridStyleMask = []
    table.intercellSpacing = .zero
    table.usesAutomaticRowHeights = false
    table.rowSizeStyle = .custom
    table.allowsColumnReordering = false
    table.allowsColumnResizing = false
    table.allowsColumnSelection = false
    table.backgroundColor = .textBackgroundColor
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

    let column = NSTableColumn(identifier: Self.columnIdentifier)
    column.resizingMask = .autoresizingMask
    column.minWidth = 40
    table.addTableColumn(column)

    table.dataSource = self
    table.delegate = self

    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.drawsBackground = true
    scroll.backgroundColor = .textBackgroundColor
    scroll.contentView.postsBoundsChangedNotifications = true

    // The comment ribbon floats over the viewport. It resolves hits through the
    // controller and passes through non-gutter points to the diff cells.
    ribbon.controller = self
    ribbon.frame = scroll.bounds
    ribbon.autoresizingMask = [.width, .height]
    ribbon.onOpenComposer = { [weak self] side, start, end, snippet, context in
      self?.onOpenComposer?(side, start, end, snippet, context)
    }
    scroll.addSubview(ribbon, positioned: .above, relativeTo: nil)

    boundsObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: scroll.contentView,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.fireVisibleRange() }
    }
  }

  deinit {
    if let boundsObserver {
      NotificationCenter.default.removeObserver(boundsObserver)
    }
  }

  // MARK: - Applying rows

  /// The incremental applier. Mode switch or heavy churn (>40%) reloads (with
  /// the scroll anchor preserved); otherwise a `CollectionDifference` row delta
  /// is applied through `beginUpdates`/`insertRows`/`removeRows` with
  /// `.effectNone` so a live re-diff never jitters.
  func apply(rows new: [DiffRow], mode newMode: DiffViewMode, scrollPreserving: Bool) {
    let modeChanged = newMode != mode
    mode = newMode

    let churnThreshold = max(1, rows.count * 4 / 10)
    if modeChanged || rows.isEmpty || new.isEmpty || abs(new.count - rows.count) > churnThreshold {
      let anchor = scrollPreserving ? captureAnchor() : nil
      rows = new
      rebuildStylingCaches()
      metrics = metrics.withGutter(for: new)
      tableView.reloadData()
      tableView.layoutSubtreeIfNeeded()
      if let anchor { restore(anchor) }
      fireVisibleRange()
      return
    }

    let anchor = scrollPreserving ? captureAnchor() : nil
    let difference = new.difference(from: rows)
    metrics = metrics.withGutter(for: new)
    tableView.beginUpdates()
    for case .remove(let offset, _, _) in difference.removals.reversed() {
      tableView.removeRows(at: IndexSet(integer: offset), withAnimation: [])
    }
    for case .insert(let offset, _, _) in difference.insertions {
      tableView.insertRows(at: IndexSet(integer: offset), withAnimation: [])
    }
    rows = new
    rebuildStylingCaches()
    tableView.endUpdates()
    // Gutter width may have grown/shrunk with new line numbers; redraw survivors.
    tableView.enumerateAvailableRowViews { rowView, _ in
      rowView.needsDisplay = true
    }
    if let anchor { restore(anchor) }
    fireVisibleRange()
  }

  // MARK: - NSTableViewDataSource

  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

  // MARK: - NSTableViewDelegate

  func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
    guard rows.indices.contains(row) else { return metrics.lineHeight }
    switch rows[row] {
    case .placeholder:
      return metrics.lineHeight * 3
    case .commentThread(let comment):
      return DiffCellView.commentThreadHeight(comment, metrics: metrics)
    default:
      return metrics.lineHeight
    }
  }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard rows.indices.contains(row) else { return nil }
    let cell =
      tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? DiffCellView
      ?? {
        let created = DiffCellView()
        created.identifier = Self.cellIdentifier
        return created
      }()
    cell.configure(
      row: rows[row],
      metrics: metrics,
      mode: mode,
      highlight: rowHighlight(at: row),
      callbacks: DiffCellView.Callbacks(
        onExpand: { [weak self] anchor in self?.onExpandGap?(anchor) },
        onCommentTap: { [weak self] id in self?.onCommentTap?(id) },
        onAddComment: { [weak self] side, line in self?.openComposer(side: side, line: line) }
      )
    )
    return cell
  }

  // MARK: - Syntax highlighting + word-diff styling (Phase 4)

  /// Replaces the syntax spans and re-styles the on-screen rows in place (no row
  /// rebuild) so highlights hydrate progressively as the actor returns them.
  func applySyntax(_ byLine: [Int: [SyntaxHighlighter.HighlightSpan]]) {
    syntaxByLine = byLine
    refreshVisibleHighlights()
  }

  /// Clears syntax spans (e.g. unbundled / capped file) and repaints plain.
  func clearSyntax() {
    guard !syntaxByLine.isEmpty else { return }
    syntaxByLine = [:]
    refreshVisibleHighlights()
  }

  /// The span of new-side (1-based) line numbers currently on screen, for scoping
  /// the highlighter's query to the viewport. `nil` when no line-bearing rows show.
  func visibleNewLineRange() -> Range<Int>? {
    var lower = Int.max
    var upper = Int.min
    for index in visibleRowRange() where rows.indices.contains(index) {
      guard let line = Self.newLineNumber(of: rows[index]) else { continue }
      lower = min(lower, line)
      upper = max(upper, line)
    }
    guard lower <= upper else { return nil }
    return lower..<(upper + 1)
  }

  private func refreshVisibleHighlights() {
    for index in visibleRowRange() where rows.indices.contains(index) {
      guard let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? DiffCellView
      else { continue }
      cell.updateHighlight(rowHighlight(at: index))
    }
  }

  private func rowHighlight(at index: Int) -> RowHighlight {
    guard rows.indices.contains(index) else { return .empty }
    switch rows[index] {
    case .line(let line):
      var highlight = RowHighlight()
      if line.origin != .deletion, let number = line.newLineNumber {
        highlight.syntaxNew = syntaxByLine[number] ?? []
      }
      let wordDiff = wordDiff(at: index)
      highlight.wordOld = wordDiff.old
      highlight.wordNew = wordDiff.new
      return highlight
    case .splitLine(_, _, let new):
      var highlight = RowHighlight()
      if let new, let number = new.newLineNumber {
        highlight.syntaxNew = syntaxByLine[number] ?? []
      }
      let wordDiff = wordDiff(at: index)
      highlight.wordOld = wordDiff.old
      highlight.wordNew = wordDiff.new
      return highlight
    default:
      return .empty
    }
  }

  /// Lazily computes (and caches) the word-diff spans for one row.
  private func wordDiff(at index: Int) -> (old: [WordDiff.Span], new: [WordDiff.Span]) {
    if let cached = wordDiffCache[index] { return cached }
    var result: (old: [WordDiff.Span], new: [WordDiff.Span]) = ([], [])
    switch rows[index] {
    case .line(let line):
      if line.origin == .deletion, let counterpart = counterpartByRow[index] {
        result.old = WordDiff.diff(old: line.content, new: counterpart).oldSpans
      } else if line.origin == .addition, let counterpart = counterpartByRow[index] {
        result.new = WordDiff.diff(old: counterpart, new: line.content).newSpans
      }
    case .splitLine(_, let old, let new):
      if let old, let new, Self.isChange(old), Self.isChange(new) {
        let difference = WordDiff.diff(old: old.content, new: new.content)
        result.old = difference.oldSpans
        result.new = difference.newSpans
      }
    default:
      break
    }
    wordDiffCache[index] = result
    return result
  }

  /// Rebuilds the per-row styling caches after `rows` changes: recomputes the
  /// unified deletion↔addition pairing and drops stale word-diff results. Syntax
  /// spans are kept (re-requested for the new viewport by the driver).
  private func rebuildStylingCaches() {
    wordDiffCache.removeAll(keepingCapacity: true)
    counterpartByRow.removeAll(keepingCapacity: true)
    var index = 0
    while index < rows.count {
      guard case .line(let line) = rows[index], line.origin == .deletion else {
        index += 1
        continue
      }
      var deletions: [Int] = []
      while index < rows.count, case .line(let candidate) = rows[index], candidate.origin == .deletion {
        deletions.append(index)
        index += 1
      }
      var additions: [Int] = []
      while index < rows.count, case .line(let candidate) = rows[index], candidate.origin == .addition {
        additions.append(index)
        index += 1
      }
      for pair in 0..<min(deletions.count, additions.count) {
        guard case .line(let deletion) = rows[deletions[pair]], case .line(let addition) = rows[additions[pair]]
        else { continue }
        counterpartByRow[deletions[pair]] = addition.content
        counterpartByRow[additions[pair]] = deletion.content
      }
    }
  }

  private static func isChange(_ line: DiffLine) -> Bool {
    line.origin == .addition || line.origin == .deletion
  }

  private static func newLineNumber(of row: DiffRow) -> Int? {
    switch row {
    case .line(let line): return line.newLineNumber
    case .splitLine(_, _, let new): return new?.newLineNumber
    default: return nil
    }
  }

  // MARK: - Geometry API (Phase 5)

  /// Maps a point in the table's coordinate space to a row index, or nil.
  func rowIndex(atContentPoint point: NSPoint) -> Int? {
    let row = tableView.row(at: point)
    return row >= 0 ? row : nil
  }

  /// The rect of `row` converted into `view`'s coordinate space.
  func rect(ofRow row: Int, in view: NSView) -> NSRect {
    guard rows.indices.contains(row) else { return .zero }
    return tableView.convert(tableView.rect(ofRow: row), to: view)
  }

  /// The currently on-screen row range.
  func visibleRowRange() -> Range<Int> {
    let range = tableView.rows(in: tableView.visibleRect)
    guard range.length > 0 else { return 0..<0 }
    return range.location..<(range.location + range.length)
  }

  func rowView(atRow row: Int) -> NSTableRowView? {
    guard rows.indices.contains(row) else { return nil }
    return tableView.rowView(atRow: row, makeIfNecessary: false)
  }

  // MARK: - Comment-ribbon geometry API (Phase 5)

  /// A resolved single-line comment target: the row, the side its gutter was on,
  /// and the git line number on that side.
  struct CommentTarget: Equatable {
    let rowIndex: Int
    let side: DiffSide
    let line: Int
  }

  var isSplitMode: Bool { mode == .split }

  /// Converts a point in `sourceView`'s coordinate space to the row + side +
  /// line under it, but only when it lands on a real content line inside the
  /// gutter band. `nil` for non-line rows, gap cells, marker rows, or a point
  /// outside the gutter — so the ribbon's "+" never shows there.
  func commentTarget(at point: NSPoint, from sourceView: NSView) -> CommentTarget? {
    let tablePoint = tableView.convert(point, from: sourceView)
    guard let index = rowIndex(atContentPoint: tablePoint), rows.indices.contains(index) else { return nil }
    guard let side = gutterSide(at: tablePoint) else { return nil }
    guard let line = lineNumber(atRow: index, side: side) else { return nil }
    return CommentTarget(rowIndex: index, side: side, line: line)
  }

  /// Line number on `side` for the row under `point` (drag continuation: the
  /// side stays fixed to the anchor's, only the row varies). `nil` off a line.
  func commentTarget(at point: NSPoint, from sourceView: NSView, side: DiffSide) -> CommentTarget? {
    let tablePoint = tableView.convert(point, from: sourceView)
    guard let index = rowIndex(atContentPoint: tablePoint), rows.indices.contains(index) else { return nil }
    guard let line = lineNumber(atRow: index, side: side) else { return nil }
    return CommentTarget(rowIndex: index, side: side, line: line)
  }

  /// The on-screen rect of `row` converted into `view`'s space — the ribbon uses
  /// it to center the "+" and paint the drag band.
  func rowRect(_ row: Int, in view: NSView) -> NSRect { rect(ofRow: row, in: view) }

  /// The gutter band width (both line-number columns) used to gate ribbon hits
  /// so a click on the code body falls through to the cell.
  var gutterBandWidth: CGFloat { metrics.gutterWidth }

  /// Builds the anchor snippet + preceding context (up to 3 lines) for a
  /// resolved `side` range, read from the rendered rows so relocation keys off
  /// exactly what the user saw.
  func anchorPayload(side: DiffSide, startLine: Int, endLine: Int) -> (snippet: String, contextBefore: String) {
    var covered: [String] = []
    var preceding: [String] = []
    for row in rows {
      guard let (line, content) = lineOnSide(row, side: side) else { continue }
      if line >= startLine, line <= endLine {
        covered.append(content)
      } else if line < startLine {
        preceding.append(content)
      }
    }
    let contextBefore = preceding.suffix(3).joined(separator: "\n")
    return (covered.joined(separator: "\n"), contextBefore)
  }

  /// Opens the comment composer for a single line (the VoiceOver "Add comment"
  /// custom action path). Builds the same snippet/context payload the hover-driven
  /// ribbon produces so relocation keys off identical anchor text.
  func openComposer(side: DiffSide, line: Int) {
    let payload = anchorPayload(side: side, startLine: line, endLine: line)
    onOpenComposer?(side, line, line, payload.snippet, payload.contextBefore)
  }

  /// The side whose gutter `point.x` falls in (unified stacks old|new on the
  /// left; split puts each pane's gutter at its left edge). `nil` outside a gutter.
  private func gutterSide(at point: NSPoint) -> DiffSide? {
    let gutter = metrics.gutterWidth
    if mode == .unified {
      if point.x < gutter { return .old }
      if point.x < gutter * 2 { return .new }
      return nil
    }
    let half = (tableView.bounds.width / 2).rounded()
    if point.x < gutter { return .old }
    if point.x >= half, point.x < half + gutter { return .new }
    return nil
  }

  private func lineNumber(atRow index: Int, side: DiffSide) -> Int? {
    guard rows.indices.contains(index) else { return nil }
    guard let (line, _) = lineOnSide(rows[index], side: side) else { return nil }
    return line
  }

  /// The git line number + content a row carries on `side`, or nil when the row
  /// isn't a real content line on that side (gap cell, marker, header, expander).
  private func lineOnSide(_ row: DiffRow, side: DiffSide) -> (line: Int, content: String)? {
    switch row {
    case .line(let diffLine):
      guard diffLine.origin != .noNewlineMarker, let line = diffLine.lineNumber(on: side) else { return nil }
      return (line, diffLine.content)
    case .splitLine(_, let old, let new):
      let candidate = side == .old ? old : new
      guard let candidate, candidate.origin != .noNewlineMarker, let line = candidate.lineNumber(on: side)
      else { return nil }
      return (line, candidate.content)
    default:
      return nil
    }
  }

  private func fireVisibleRange() {
    // Keep the gutter overlay's "+"/drag band aligned as the viewport moves.
    ribbon.needsDisplay = true
    let range = visibleRowRange()
    guard range != lastVisibleRange else { return }
    lastVisibleRange = range
    onVisibleRangeChanged?(range)
  }

  // MARK: - Scroll anchoring

  private struct ScrollAnchor {
    let rowID: RowID
    let offsetFromViewportTop: CGFloat
  }

  private func captureAnchor() -> ScrollAnchor? {
    let clip = scrollView.contentView
    let visible = clip.bounds
    let topRow = tableView.row(at: NSPoint(x: 0, y: visible.minY + 1))
    guard topRow >= 0, rows.indices.contains(topRow) else { return nil }
    let rowRect = tableView.rect(ofRow: topRow)
    return ScrollAnchor(rowID: rows[topRow].id, offsetFromViewportTop: visible.minY - rowRect.minY)
  }

  private func restore(_ anchor: ScrollAnchor) {
    guard let index = rows.firstIndex(where: { $0.id == anchor.rowID }) ?? nearestSurvivingIndex(anchor.rowID)
    else { return }
    let clip = scrollView.contentView
    let targetY = tableView.rect(ofRow: index).minY + anchor.offsetFromViewportTop
    let maxY = max(0, tableView.bounds.height - clip.bounds.height)
    clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: min(max(0, targetY), maxY)))
    scrollView.reflectScrolledClipView(clip)
  }

  /// When the exact anchored row vanished (its region collapsed), fall back to
  /// the surviving row with the closest new-side line number.
  private func nearestSurvivingIndex(_ target: RowID) -> Int? {
    guard let targetLine = target.newLineNumber else { return nil }
    var best: (index: Int, distance: Int)?
    for (index, row) in rows.enumerated() {
      guard let line = row.id.newLineNumber else { continue }
      let distance = abs(line - targetLine)
      if best == nil || distance < best!.distance {
        best = (index, distance)
      }
    }
    return best?.index
  }
}

extension RowID {
  /// The new-side line number this row anchors to, for nearest-row fallback.
  fileprivate var newLineNumber: Int? {
    switch self {
    case .line(_, let new, _): return new
    case .hunkHeader(let anchor), .expander(let anchor): return anchor
    case .splitLine(let pairID): return pairID / 2
    case .plainFallback(let line): return line
    case .placeholder, .commentThread: return nil
    }
  }
}
