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

  /// Fired on every clip-view bounds change so Phase 4 can style only the rows
  /// currently on screen.
  var onVisibleRangeChanged: ((Range<Int>) -> Void)?
  /// Fired when the user clicks an expander (anchor of the collapsed region).
  var onExpandGap: ((Int) -> Void)?

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
    case .commentThread:
      return 0  // Phase 5 stub — renders nothing yet.
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
    cell.configure(row: rows[row], metrics: metrics, mode: mode) { [weak self] anchor in
      self?.onExpandGap?(anchor)
    }
    return cell
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

  private func fireVisibleRange() {
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
