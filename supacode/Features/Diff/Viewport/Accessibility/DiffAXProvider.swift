import AppKit

/// An on-demand read of everything the AX element set projects: the live tree, the
/// current render mode, and the two side caches the tree deliberately does NOT hold
/// (rich comment models + file-header models are resolved by key, per Phase 6 D3).
/// Read fresh on every VoiceOver query so the labels survive a re-diff for free.
@MainActor
struct DiffAXSnapshot {
  let tree: ChunkTree
  let mode: DiffViewMode
  /// The thread of comments anchored at `anchorID` (head first). Empty when the
  /// side cache has no entry (a mid-flight tree ahead of the reducer's comments).
  let comments: (UUID) -> [ReviewComment]
  /// The resolved header model for a file id — the SAME `FileHeaderWidget.Model`
  /// the in-flow header + sticky overlay render, so the spoken file matches.
  let fileHeader: (FileID) -> FileHeaderWidget.Model?

  init(
    tree: ChunkTree,
    mode: DiffViewMode,
    comments: @escaping (UUID) -> [ReviewComment] = { _ in [] },
    fileHeader: @escaping (FileID) -> FileHeaderWidget.Model? = { _ in nil }
  ) {
    self.tree = tree
    self.mode = mode
    self.comments = comments
    self.fileHeader = fileHeader
  }
}

/// Which of the three custom rotors a membership / result query is for.
enum DiffAXRotorKind: String, CaseIterable {
  case changes = "Changes"
  case files = "Files"
  case comments = "Comments"
}

/// The single `@MainActor` owner of the diff viewport's accessibility tree. It
/// installs an explicit `accessibilityChildren` array on the Phase-2 `documentView`
/// (the AX **parent**) — one `DiffLineAXElement` per **materialized** row — plus the
/// three custom rotors, and it is rebuilt only when the materialized row COUNT
/// changes (expand / collapse / re-diff / mode toggle) — **never on scroll, never on
/// recycle**. Every per-row projection is a tree seek, so element identity for a
/// `rowIndex` is stable across a scroll while the label/frame track the live tree.
///
/// Setting (not overriding) `documentView.accessibilityChildren` is enough: an
/// explicit array **replaces** NSView's default subview-derived children, so the
/// recycled `LineRowView`s — which set `isAccessibilityElement = false` — never
/// surface as competing AX identities. No override lands in a sibling phase's file.
@MainActor
final class DiffAXProvider: NSObject {
  /// The flipped Phase-2 documentView == the AX parent (parent-space coordinates).
  unowned let documentView: NSView

  private let snapshotProvider: () -> DiffAXSnapshot
  private let revealRow: (Int) -> Void
  private let setKeyboardFocus: (Int) -> Void
  private let addComment: (DiffSide, Int) -> Void
  private let expandGap: (GapKey) -> Void
  /// The live widget host view for a materialized `.widget` chunk (a11y-native
  /// SwiftUI content), or `nil` when the row is offscreen / not a widget. Lets the
  /// Comments rotor target the rich hosting view when it exists and the synthesized
  /// fallback otherwise — exactly one is live per query (no double read).
  private let liveWidgetView: (ChunkID) -> NSView?
  /// `NSAccessibility.post(element:notification:)`, injectable so tests spy the posts.
  private let post: (Any, NSAccessibility.Notification) -> Void

  /// index == rowIndex; identity stable across recycle. Empty in the huge-file
  /// `NSAccessibilityElementLoading` hatch (§F) — the tree is then reachable purely
  /// through the three rotors + windowed `windowCache` realization.
  private var elements: [DiffLineAXElement] = []
  /// Breaks the VO⇄keyboard focus feedback loop (§G).
  private var suppressFocusPost = false
  /// Bounded LRU of rows realized on demand in the huge-file hatch.
  private var windowCache: [Int: DiffLineAXElement] = [:]
  private var windowOrder: [Int] = []

  private lazy var rotors = DiffAXRotors(provider: self)

  /// Above this materialized-row count, eagerly allocating one element per row is
  /// wasteful → adopt `NSAccessibilityElementLoading` windowing (§F).
  static let hugeFileRowThreshold = 20_000
  /// The realized-row window kept live in the hatch (O(1) navigation without
  /// materializing all N).
  static let windowCacheLimit = 256

  init(
    documentView: NSView,
    snapshot: @escaping () -> DiffAXSnapshot,
    reveal: @escaping (Int) -> Void,
    setKeyboardFocus: @escaping (Int) -> Void,
    addComment: @escaping (DiffSide, Int) -> Void,
    expand: @escaping (GapKey) -> Void,
    liveWidgetView: @escaping (ChunkID) -> NSView? = { _ in nil },
    post: @escaping (Any, NSAccessibility.Notification) -> Void = {
      NSAccessibility.post(element: $0, notification: $1)
    }
  ) {
    self.documentView = documentView
    self.snapshotProvider = snapshot
    self.revealRow = reveal
    self.setKeyboardFocus = setKeyboardFocus
    self.addComment = addComment
    self.expandGap = expand
    self.liveWidgetView = liveWidgetView
    self.post = post
    super.init()
  }

  func snapshot() -> DiffAXSnapshot { snapshotProvider() }

  // MARK: - Reload (structural change only — O(materialized rows), off the hot path)

  /// Rebuild the element set + rotors after a structural change (expand / collapse /
  /// re-diff / mode toggle). Below the huge-file threshold this eagerly maps one
  /// element per materialized row; above it, the windowed loading hatch installs.
  func reload() {
    let snap = snapshot()
    let count = snap.tree.rowCount(snap.mode)
    guard count <= Self.hugeFileRowThreshold else {
      installLoadingHatch()
      return
    }
    elements = (0..<count).map { DiffLineAXElement(rowIndex: $0, provider: self) }
    windowCache.removeAll(keepingCapacity: true)
    windowOrder.removeAll(keepingCapacity: true)
    documentView.setAccessibilityChildren(elements as [Any])
    documentView.setAccessibilityCustomRotors(rotors.make())
    post(documentView, .layoutChanged)
  }

  /// Huge-file hatch: leave `accessibilityChildren` empty (the tree is reachable via
  /// the three rotors), so navigation realizes exactly the row it lands on.
  private func installLoadingHatch() {
    elements = []
    windowCache.removeAll(keepingCapacity: true)
    windowOrder.removeAll(keepingCapacity: true)
    documentView.setAccessibilityChildren([])
    documentView.setAccessibilityCustomRotors(rotors.make())
    post(documentView, .layoutChanged)
  }

  /// Whether the huge-file hatch is active (no eager element array).
  var isWindowedHatchActive: Bool { elements.isEmpty && snapshot().tree.rowCount(snapshot().mode) > 0 }

  // MARK: - Element lookup

  /// The eagerly-materialized element for `row`, or `nil` (out of range, or the
  /// hatch is active so no eager array exists).
  func element(_ row: Int) -> DiffLineAXElement? {
    elements.indices.contains(row) ? elements[row] : nil
  }

  /// The realized-row count currently held by the windowed hatch (spied by tests).
  var windowedRealizedCount: Int { windowCache.count }

  /// The eagerly-materialized element count — the published AX child count below
  /// the huge-file threshold, `0` in the windowed hatch (spied by tests).
  var eagerElementCount: Int { elements.count }

  // MARK: - Tree-backed projections (lazy getters for `DiffLineAXElement`)

  /// A collapsed run is a single expander widget row → a press-button; every other
  /// row reads as static text.
  func role(_ row: Int) -> NSAccessibility.Role {
    guard let hit = snapshot().tree.seek(index: row, mode: snapshot().mode) else { return .staticText }
    if case .widget(let widget) = hit.chunk, case .expander = widget.payload { return .button }
    return .staticText
  }

  func label(_ row: Int) -> String {
    let snap = snapshot()
    guard let hit = snap.tree.seek(index: row, mode: snap.mode) else { return "" }
    switch hit.chunk {
    case .lineSegment(let segment):
      guard let diffRow = DiffAXRowProjection.diffRow(segment: segment, localRow: hit.localRow, mode: snap.mode) else {
        return ""
      }
      return DiffAXText.label(for: diffRow, mode: snap.mode)
    case .widget(let widget):
      return widgetLabel(widget, snapshot: snap)
    }
  }

  /// The raw code text for a line / split / plain-fallback row (`nil` for widgets +
  /// markers) so VoiceOver's "read text" surfaces the contents.
  func value(_ row: Int) -> String? {
    let snap = snapshot()
    guard let hit = snap.tree.seek(index: row, mode: snap.mode), case .lineSegment(let segment) = hit.chunk,
      let diffRow = DiffAXRowProjection.diffRow(segment: segment, localRow: hit.localRow, mode: snap.mode)
    else { return nil }
    switch diffRow {
    case .line(let line): return line.origin == .noNewlineMarker ? nil : line.content
    case .splitLine(_, let old, let new): return new?.content ?? old?.content
    case .plainFallback(_, let text): return text
    default: return nil
    }
  }

  /// The row's document-space rect in AX-parent (documentView) coordinates. VALID
  /// OFFSCREEN — a pure O(log n) tree seek, independent of any live view.
  func frameInParent(_ row: Int) -> NSRect {
    let snap = snapshot()
    return snap.tree.rowFrameInDocument(row, mode: snap.mode, width: max(documentView.bounds.width, 1))
  }

  /// The row's rect in SCREEN space — the parent-space rect projected through the
  /// documentView / window chain. Falls back to the parent-space rect when there is
  /// no window (headless / detached), which is exactly what tests read.
  func screenFrame(_ row: Int) -> NSRect {
    let rectInDocument = frameInParent(row)
    guard let window = documentView.window else { return rectInDocument }
    let rectInWindow = documentView.convert(rectInDocument, to: nil)
    return window.convertToScreen(rectInWindow)
  }

  func customActions(_ row: Int) -> [NSAccessibilityCustomAction]? {
    let snap = snapshot()
    guard let hit = snap.tree.seek(index: row, mode: snap.mode), case .lineSegment(let segment) = hit.chunk,
      let diffRow = DiffAXRowProjection.diffRow(segment: segment, localRow: hit.localRow, mode: snap.mode),
      let anchor = DiffAXText.commentAnchor(for: diffRow)
    else { return nil }
    return [
      NSAccessibilityCustomAction(name: "Add comment on line \(anchor.line)") { [weak self] in
        self?.addComment(anchor.side, anchor.line)
        return true
      }
    ]
  }

  /// Press an expander → Phase-7 expand for its gap (a `reload()` + `.layoutChanged`
  /// post follows the tree grow). Any other row ignores the press.
  func performPress(_ row: Int) -> Bool {
    guard let hit = snapshot().tree.seek(index: row, mode: snapshot().mode), case .widget(let widget) = hit.chunk,
      case .expander = widget.payload, case .expander(let gap) = widget.key
    else { return false }
    expandGap(gap)
    return true
  }

  private func widgetLabel(_ widget: Widget, snapshot snap: DiffAXSnapshot) -> String {
    switch widget.payload {
    case .fileHeader(let fileID):
      guard let model = snap.fileHeader(fileID) else { return "File" }
      return DiffAXText.fileHeaderLabel(model)
    case .hunkHeader(let anchor, let text):
      return DiffAXText.label(for: .hunkHeader(anchor: anchor, text: text), mode: snap.mode)
    case .expander(let anchor, let range, let hidden):
      return DiffAXText.label(
        for: .expander(anchor: anchor, collapsedRange: range, hiddenCount: hidden), mode: snap.mode)
    case .placeholder(let placeholder):
      return DiffAXText.label(for: .placeholder(placeholder), mode: snap.mode)
    case .commentThread(let anchorID):
      // The orphaned prefix is never dropped: an orphaned comment still reads.
      guard let head = snap.comments(anchorID).first else { return "Comment" }
      return DiffAXText.label(for: .commentThread(head), mode: snap.mode)
    case .noNewlineMarker:
      return "No newline at end of file"
    case .plainFallback(let lineNumber, let text):
      return DiffAXText.label(for: .plainFallback(lineNumber: lineNumber, text: text), mode: snap.mode)
    }
  }

  // MARK: - Rotor membership (tree-derived — never a retained array)

  /// The materialized row indices a rotor hops between, seeked from the tree once
  /// per query so membership survives a re-diff for free.
  func rotorRows(for kind: DiffAXRotorKind) -> [Int] {
    let snap = snapshot()
    switch kind {
    case .changes: return changeRunStartRows(snap)
    case .files: return fileHeaderRows(snap)
    case .comments: return commentRows(snap)
    }
  }

  /// The first row of every contiguous `.change` run (hunk-hop, matching the `n`/`p`
  /// keyboard command — consecutive change leaves split at `maxLeafSpan` coalesce).
  private func changeRunStartRows(_ snap: DiffAXSnapshot) -> [Int] {
    var result: [Int] = []
    var previousWasChange = false
    for node in snap.tree.inorderNodes() {
      let isChange = node.chunk.lineSegment?.classification == .change
      if isChange, !previousWasChange,
        let index = snap.tree.rowIndex(for: (chunk: node.id, localRow: 0), mode: snap.mode)
      {
        result.append(index)
      }
      previousWasChange = isChange
    }
    return result
  }

  /// Each `.widget(fileHeader)` row (tree file boundaries).
  private func fileHeaderRows(_ snap: DiffAXSnapshot) -> [Int] {
    snap.tree.fileHeaderNodes.values
      .compactMap { snap.tree.rowIndex(for: (chunk: $0, localRow: 0), mode: snap.mode) }
      .sorted()
  }

  /// Each `.widget(commentThread)` row (incl. orphan group appended at the end).
  private func commentRows(_ snap: DiffAXSnapshot) -> [Int] {
    var result: [Int] = []
    for node in snap.tree.inorderNodes() {
      guard case .widget(let widget) = node.chunk, case .commentThread = widget.payload else { continue }
      if let index = snap.tree.rowIndex(for: (chunk: node.id, localRow: 0), mode: snap.mode) { result.append(index) }
    }
    return result.sorted()
  }

  /// The live, a11y-native hosting view for a `.widget` row, when materialized
  /// onscreen — the Comments-rotor merge target (rich content). `nil` when the row
  /// is offscreen (no hosting view), so the rotor falls back to the synthesized
  /// element + `reveal`.
  func liveWidgetElement(forRow row: Int) -> NSView? {
    guard let hit = snapshot().tree.seek(index: row, mode: snapshot().mode), case .widget = hit.chunk else {
      return nil
    }
    return liveWidgetView(hit.id)
  }

  // MARK: - Reveal + VO⇄keyboard focus mirror (§G)

  /// Anchored scroll-to-row (Phase-10 `reveal`), shared by the rotors and the focus
  /// mirror so keyboard nav and VoiceOver land a row through the SAME primitive.
  func reveal(_ row: Int) { revealRow(row) }

  /// VoiceOver moved its cursor here (from `setAccessibilityFocused`). Reveal, then
  /// mirror into keyboard state under `suppressFocusPost` so the mirror does not
  /// re-post `.focusedUIElementChanged` back into VoiceOver (no feedback loop).
  func voiceOverDidFocus(_ row: Int) {
    reveal(row)
    suppressFocusPost = true
    setKeyboardFocus(row)
    suppressFocusPost = false
  }

  /// Keyboard nav (Phase 10) moved `focusedRowIndex`. Drag the VoiceOver cursor
  /// along (unless VoiceOver originated the change, in which case the loop guard is
  /// set). No-op in the windowed hatch where no eager element exists.
  func keyboardDidFocus(_ row: Int) {
    guard !suppressFocusPost, let element = element(row) else { return }
    reveal(row)
    post(element, .focusedUIElementChanged)
  }

  // MARK: - Windowed realization (huge-file hatch)

  /// Realize (create-or-reuse) exactly one element for `row`, bounded by an LRU so
  /// navigation stays O(1) without materializing all N.
  func realizeWindowedElement(row: Int) -> DiffLineAXElement? {
    let snap = snapshot()
    guard row >= 0, row < snap.tree.rowCount(snap.mode) else { return nil }
    if let existing = windowCache[row] {
      touchWindow(row)
      return existing
    }
    let element = DiffLineAXElement(rowIndex: row, provider: self)
    windowCache[row] = element
    windowOrder.append(row)
    trimWindow()
    return element
  }

  private func touchWindow(_ row: Int) {
    if let index = windowOrder.firstIndex(of: row) { windowOrder.remove(at: index) }
    windowOrder.append(row)
  }

  private func trimWindow() {
    while windowOrder.count > Self.windowCacheLimit {
      let evicted = windowOrder.removeFirst()
      windowCache[evicted] = nil
    }
  }
}

// MARK: - NSAccessibilityElementLoading (huge-file windowed hatch, §F)

extension DiffAXProvider: @MainActor NSAccessibilityElementLoading {
  /// VoiceOver hands back a token we minted in a rotor result; realize (create-or-
  /// reuse) just that one row.
  func accessibilityElement(withToken token: NSAccessibilityLoadingToken) -> (any NSAccessibilityElementProtocol)? {
    guard let rowToken = token as? DiffAXRowToken else { return nil }
    return realizeWindowedElement(row: rowToken.rowIndex)
  }
}

// MARK: - Loading token (§F)

/// The `NSAccessibilityLoadingToken` (`id<NSSecureCoding, NSObject>`) a rotor mints
/// for a not-yet-realized row in the huge-file hatch. Carries only the row index.
final class DiffAXRowToken: NSObject, NSSecureCoding {
  let rowIndex: Int

  init(rowIndex: Int) {
    self.rowIndex = rowIndex
    super.init()
  }

  static var supportsSecureCoding: Bool { true }

  func encode(with coder: NSCoder) { coder.encode(rowIndex, forKey: "row") }

  required init?(coder: NSCoder) {
    rowIndex = coder.decodeInteger(forKey: "row")
    super.init()
  }
}

// MARK: - Row reconstruction (tree row → a11y `DiffAXRow` for `DiffAXText`)

/// Reconstructs the `DiffAXRow` a materialized line-segment row displays — the bridge
/// from the tree's `(segment, localRow)` coordinate to the ported `DiffAXText`
/// strings. Mirrors `SegmentProjection.renderedRows` order + count EXACTLY (so a
/// `localRow` indexes the right row) while carrying the line CONTENT the rendered
/// projection drops. Caseless `enum` (no free functions).
enum DiffAXRowProjection {
  /// The reconstructed row for `localRow` of a line segment in `mode`, or `nil` when
  /// the offset is out of range.
  static func diffRow(segment: LineSegment, localRow: Int, mode: DiffViewMode) -> DiffAXRow? {
    let rows = rows(for: segment, mode: mode)
    guard rows.indices.contains(localRow) else { return nil }
    return rows[localRow]
  }

  /// The full projected rows for a segment — mirrors `LineSegment.renderedRows`.
  static func rows(for segment: LineSegment, mode: DiffViewMode) -> [DiffAXRow] {
    switch segment.classification {
    case .context, .contextExpanded:
      return contextRows(segment, mode: mode)
    case .change:
      return mode == .unified ? unifiedChangeRows(segment) : splitChangeRows(segment)
    }
  }

  private static func contextRows(_ segment: LineSegment, mode: DiffViewMode) -> [DiffAXRow] {
    var rows: [DiffAXRow] = []
    for line in segment.windowedLines {
      switch mode {
      case .unified: rows.append(.line(line))
      case .split: rows.append(.splitLine(pairID: 0, old: line, new: line))
      }
      if line.noNewlineAtEof {
        let marker = noNewlineLine(from: line)
        switch mode {
        case .unified: rows.append(.line(marker))
        case .split: rows.append(.splitLine(pairID: 0, old: nil, new: marker))
        }
      }
    }
    return rows
  }

  private static func unifiedChangeRows(_ segment: LineSegment) -> [DiffAXRow] {
    var rows: [DiffAXRow] = []
    for line in segment.windowDeletions + segment.windowAdditions {
      rows.append(.line(line))
      if line.noNewlineAtEof { rows.append(.line(noNewlineLine(from: line))) }
    }
    return rows
  }

  private static func splitChangeRows(_ segment: LineSegment) -> [DiffAXRow] {
    let dels = segment.windowDeletions
    let adds = segment.windowAdditions
    var rows: [DiffAXRow] = []
    for index in 0..<max(dels.count, adds.count) {
      let old = index < dels.count ? dels[index] : nil
      let new = index < adds.count ? adds[index] : nil
      rows.append(.splitLine(pairID: 0, old: old, new: new))
      if (old?.noNewlineAtEof ?? false) || (new?.noNewlineAtEof ?? false) {
        let markerOld = (old?.noNewlineAtEof ?? false) ? old.map(noNewlineLine(from:)) : nil
        let markerNew = (new?.noNewlineAtEof ?? false) ? new.map(noNewlineLine(from:)) : nil
        rows.append(.splitLine(pairID: 0, old: markerOld, new: markerNew))
      }
    }
    return rows
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
}
