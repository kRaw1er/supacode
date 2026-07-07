import AppKit
import SupacodeSettingsShared

/// The AppKit engine behind the world-class diff viewer: a custom flipped
/// `documentView` inside an `NSScrollView` that **seeks the chunk-tree** and
/// recycles views through per-`reuseKind` `ViewReuseQueue` pools. It replaces the
/// `NSTableView` substrate of `DiffTableController` — the table's fixed O(1) row
/// heights cannot do measured wrapping at kernel scale, so we virtualize the
/// tree directly: materialize the visible window + a 1000px overscan (pierre
/// `Virtualizer.ts:22`), recycle everything else, and preserve scroll across a
/// mutation by line identity (never by y or view).
///
/// `@MainActor` per CLAUDE.md. It owns AppKit and exposes **callbacks** out
/// (`onVisibleRangeChanged`, `onHit`) — it never mutates TCA `store.*`. The TCA
/// seam (`DiffViewerRepresentable`, Phase 3+) translates those callbacks to
/// actions, exactly as `DiffTableController`'s closures do today.
@MainActor
final class DiffViewportController: NSObject {
  let scrollView: NSScrollView
  let documentView: DiffViewportView

  private(set) var tree: ChunkTree
  private(set) var mode: DiffViewMode = .unified
  private var metrics: DiffMetrics

  /// One recycle pool per `DiffReuseKind` (`.line` and each `WidgetReuseKind`).
  /// The per-pool key is the hit's `ChunkID`.
  private(set) var pools: [DiffReuseKind: ViewReuseQueue<NSView, ChunkID>] = [:]

  /// Shared wrapped-`CTLine` LRU cache across every `LineRowView` (keyed by
  /// content identity, not position). Dropped wholesale on a style flip.
  let ctLineCache = CTLineCache()

  /// Perf instrumentation (parallel-safe, per controller — mirrors
  /// `ChunkTree.diagnostics` / `CTLineCache.buildCount`): total line-rows pushed
  /// through `LineRowView.configure` across all layout passes. A pure scroll of
  /// already-materialized chunks must not grow this once the configure early-out
  /// lands; it is the counter behind the "no O(segment) re-project per frame" test.
  private(set) var lineRowsConfigured = 0

  /// Per-line syntax runs (Phase-4 seam), pushed in from the reducer's
  /// `DiffDocument.old/newStyleRuns`. `setSyntax` re-typesets the visible window so a
  /// windowed highlight arrival paints WITHOUT a tree rebuild; `syntaxVersion` folds
  /// into the render context so the configure early-out never skips a colour change.
  private(set) var oldStyleRuns: [Int: [StyleRun]] = [:]
  private(set) var newStyleRuns: [Int: [StyleRun]] = [:]
  private(set) var syntaxVersion = 0

  /// Adopt freshly-resolved syntax runs and repaint the visible window. Content is
  /// untouched (no `apply`, no tree rebuild) — only the materialized rows re-typeset,
  /// and only the ones whose runs actually changed miss the `CTLineCache`.
  func setSyntax(old: [Int: [StyleRun]], new: [Int: [StyleRun]]) {
    oldStyleRuns = old
    newStyleRuns = new
    syntaxVersion &+= 1
    Self.logger.info("[hl] setSyntax received old=\(old.count) new=\(new.count) lines, v=\(syntaxVersion)")
    layoutVisibleChunks()
  }

  /// Resolves a `.widget` leaf's scalar payload into the concrete `DiffWidget`
  /// model the Phase-6 harness hosts. The seam (`DiffViewerRepresentable`) injects
  /// a context-rich resolver (`FileChange` / comments / callbacks); the default
  /// still renders every widget from its payload alone so headless controller
  /// tests that apply a tree without a representable keep mounting real hosts.
  var widgetResolver = DiffWidgetResolver()

  /// Whether intra-line word-diff is drawn (the upstream `WordDiffPolicy` gate,
  /// surfaced as `DiffDocument.wordDiffDisabled`). Folded into every line row's
  /// render context so `WordDiff` is never invoked for a massively-changed file.
  var wordDiffEnabled = true

  /// Per-frame widget height coalescer (Phase 6): applies `host.setMeasuredHeight`
  /// → O(log n) tree re-aggregate, anchor captured / restored once. Lazy so `self`
  /// is a valid `WidgetLayoutHost` before it binds. Constructed WITHOUT a live
  /// display link — fixed-height widgets (file / hunk header, expander, placeholder)
  /// render at their reserved height, and display-link-driven dynamic coalescing
  /// (variable comment / image widgets) is a documented follow-up.
  private lazy var coalescer = LayoutCoalescer(host: self)

  /// Phase 12 — the accessibility tree owner. Installed by the viewport seam (it
  /// needs the reducer's comment / file-header side caches + the expand / comment /
  /// keyboard-nav wiring the controller doesn't hold). `reload()` is driven from
  /// every structural mutation (re-diff / mode toggle / expand / collapse / comment
  /// insert-remove) so the synthesized element set tracks the materialized-row
  /// COUNT — never on scroll, never on recycle; per-row labels / frames re-seek the
  /// tree lazily on each VoiceOver query.
  var axProvider: DiffAXProvider?

  /// The materialized-window map: each placed chunk's anchor identity → its
  /// `yOrigin`, rebuilt every `layoutVisibleChunks`. **Bounded by window size**
  /// (Note A) — NOT a 1M-entry line→y index and NOT a widened Phase-1 API. The
  /// restore reads only this for its line-precise fix, exactly as pierre
  /// `scrollFix` queries only the rendered `[data-line-index]` elements
  /// (`Virtualizer.ts:397-421`).
  private(set) var windowMap: [ScrollAnchor.Identity: CGFloat] = [:]
  /// The placed chunks in document order (top→bottom) — the first-fully-visible
  /// anchor pick (pierre `getScrollAnchor`) and the nearest-surviving fallback.
  private var materialized: [(identity: ScrollAnchor.Identity, yOrigin: CGFloat)] = []

  /// Dedupe baseline for `fireVisibleRange` — the last per-side line window fired
  /// out. `nil` means "never fired" so the FIRST resolved window always fires, even
  /// when it is empty→populated (the initial-render highlight query that the old
  /// `0..<0 == lastVisible` guard silently swallowed until a manual scroll).
  private var lastVisibleWindow: VisibleLineWindow?
  private nonisolated(unsafe) var boundsObserver: NSObjectProtocol?

  /// Re-entrancy guard: our own `setBoundsOrigin` during a restore / clamp must
  /// not re-trigger the `boundsDidChange → relayout` feedback loop.
  private var isAdjustingScroll = false

  /// The content width each widget's height was last measured at (Phase 6
  /// `LayoutCoalescer`). A `nil` entry means "never measured" — the first report
  /// always applies; a width change re-measures (a widget wraps differently at a
  /// new width). Keyed by `WidgetKey` (per-instance identity), not `ChunkID`.
  private var widgetMeasuredWidth: [WidgetKey: CGFloat] = [:]

  /// Phase 7 — per-gap expansion bookkeeping (mutated by the `applyExpansion` /
  /// `collapseExpansion` splice in `DiffViewportExpansion.swift`, so not
  /// `private(set)`). `expansionNodes` holds the ids of the revealed-slice segments +
  /// shrunken expander currently materialized for a gap (removed + rebuilt on each
  /// expand, removed on collapse); `originalExpanders` keeps the full expander chunk
  /// so `collapseExpansion` can restore it.
  var expansionNodes: [GapKey: [ChunkID]] = [:]
  var originalExpanders: [GapKey: Chunk] = [:]

  // C7 measure↔layout guard (Phase 3 uses it; inert while heights are fixed).
  private(set) var measurePass = 0
  private let maxMeasurePasses = 5
  private let heightEpsilon: CGFloat = 0.5

  /// pierre `DEFAULT_OVERSCROLL_SIZE` (`Virtualizer.ts:22`).
  static let overscan: CGFloat = 1000

  private static let logger = SupaLogger("DiffViewport")

  // Callbacks OUT — no `store.*` mutation (`DiffTableController.swift:35` precedent).
  var onVisibleRangeChanged: ((VisibleLineWindow) -> Void)?
  var onHit: ((DiffHit) -> Void)?

  override init() {
    scrollView = NSScrollView()
    documentView = DiffViewportView()
    tree = ChunkTree()
    metrics = DiffMetrics.resolve()
    super.init()
    documentView.controller = self
    documentView.autoresizingMask = []
    scrollView.documentView = documentView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .textBackgroundColor
    scrollView.contentView.postsBoundsChangedNotifications = true
    boundsObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: scrollView.contentView,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.viewportMoved() }
    }
  }

  deinit {
    if let boundsObserver {
      NotificationCenter.default.removeObserver(boundsObserver)
    }
  }

  // MARK: - Applying a tree

  /// The single applier. Captures the anchor BEFORE mutation, grows / shrinks the
  /// document, materializes the window at the current offset (pierre order), then
  /// re-lands the anchored line against the fresh placements.
  func apply(tree newTree: ChunkTree, mode newMode: DiffViewMode, scrollPreserving: Bool) {
    let anchor = scrollPreserving ? captureAnchor() : nil
    tree = newTree
    mode = newMode
    measurePass = 0
    // Fresh content ⇒ force the next layout to re-fire its visible-line window even
    // if it coincides with the prior document's, so a newly-opened / re-diffed file
    // always issues its initial highlight query once the scroll view is sized.
    lastVisibleWindow = nil
    resizeDocument()
    clampScrollOrigin()
    layoutVisibleChunks()
    if let anchor {
      restore(anchor)
      layoutVisibleChunks()
    }
    axProvider?.reload()  // re-diff / mode change → materialized-row count may have changed
  }

  private func resizeDocument() {
    let width = scrollView.contentSize.width
    documentView.frame = CGRect(x: 0, y: 0, width: width, height: tree.totalHeight(mode))
  }

  // MARK: - The recycle loop

  /// Scroll or resize → coalesce to one layout pass (pierre `queueRender` / rAF
  /// analog; AppKit collapses many `needsLayout` to one `layout()` per frame).
  private func viewportMoved() {
    guard !isAdjustingScroll else { return }
    documentView.needsLayout = true
  }

  /// Seek the visible window (+ overscan), diff desired vs live per pool, place
  /// one view per intersecting chunk at its `yOrigin`, recycle everything that
  /// scrolled off. O(log n) seek + O(chunks-in-window) walk — the view count is
  /// bounded by the window, independent of the tree size.
  func layoutVisibleChunks() {
    let visible = visibleRect
    let minY = max(0, visible.minY - Self.overscan)
    let maxY = visible.maxY + Self.overscan
    let width = documentView.bounds.width

    windowMap.removeAll(keepingCapacity: true)
    materialized.removeAll(keepingCapacity: true)
    var live: [DiffReuseKind: Set<ChunkID>] = [:]
    var placed: [(hit: ChunkHit, reservedHeight: CGFloat)] = []

    let window = LayoutWindow(minY: minY, maxY: maxY)
    var chunkTop = firstChunkTop(atOrBelow: minY)
    while let top = chunkTop, top.yOrigin < maxY {
      let rowCount = top.chunk.baseSummary(metrics: tree.metrics).count(mode)
      let next = tree.seek(index: top.rowIndex + rowCount, mode: mode)
      let height = (next?.yOrigin ?? tree.totalHeight(mode)) - top.yOrigin
      place(top, height: height, width: width, window: window, live: &live)
      placed.append((top, height))
      chunkTop = next
    }

    for (kind, pool) in pools {
      pool.enqueueViews(notInSet: live[kind] ?? [])
    }
    runMeasureGuard(placed)
    fireVisibleRange()
  }

  /// The chunk (leaf / widget) that contains `yOffset` — we seek the row at that
  /// offset, then normalize to that chunk's row 0.
  private func firstChunkTop(atOrBelow yOffset: CGFloat) -> ChunkHit? {
    guard let hit = tree.seek(y: yOffset, mode: mode) else { return nil }
    return tree.seek(index: hit.rowIndex - hit.localRow, mode: mode)
  }

  /// The visible viewport band (already inclusive of the ±overscan) a layout pass
  /// materializes against — bundled so `place` / `configure` stay within the
  /// parameter budget.
  private struct LayoutWindow {
    let minY: CGFloat
    let maxY: CGFloat
  }

  /// A single chunk being placed this pass: its resolved top row, its reserved
  /// height, and the layout band — bundled so `configure` takes one payload.
  private struct Placement {
    let top: ChunkHit
    let height: CGFloat
    let window: LayoutWindow
  }

  private func place(
    _ top: ChunkHit, height: CGFloat, width: CGFloat, window: LayoutWindow,
    live: inout [DiffReuseKind: Set<ChunkID>]
  ) {
    let kind = top.chunk.reuseKind
    let pool = pool(for: kind)
    let view = pool.getOrCreateView(forKey: top.id) { Self.makeView(for: kind) }
    configure(view, placement: Placement(top: top, height: height, window: window), width: width)
    // Grow a wrapped line view's frame to its measured height IN THE SAME PASS so
    // a wrapped row is never clipped while the tree catches up on the next pass.
    var frameHeight = height
    if let lineView = view as? LineRowView { frameHeight = max(height, lineView.totalMeasuredHeight) }
    view.frame = CGRect(x: 0, y: top.yOrigin, width: width, height: frameHeight)
    if view.superview == nil { documentView.addSubview(view) }
    live[kind, default: []].insert(top.id)
    let identity = Self.anchorIdentity(for: top, mode: mode)
    windowMap[identity] = top.yOrigin
    materialized.append((identity, top.yOrigin))
  }

  private func configure(_ view: NSView, placement: Placement, width: CGFloat) {
    switch placement.top.chunk {
    case .lineSegment(let segment):
      if let lineView = view as? LineRowView {
        let window = lineRenderWindow(placement)
        let typeset = lineView.configure(
          segment: segment,
          chunkID: placement.top.id,
          context: LineRowRenderContext(
            metrics: metrics,
            rowHeight: tree.metrics.lineHeight,
            mode: mode,
            width: width,
            cache: ctLineCache,
            palette: .shared,
            styleGeneration: DiffPalette.shared.styleGeneration,
            wordDiffEnabled: wordDiffEnabled,
            syntaxVersion: syntaxVersion,
            oldStyleRuns: oldStyleRuns,
            newStyleRuns: newStyleRuns,
            renderRange: window.rows,
            renderRangeTop: window.top
          )
        )
        lineRowsConfigured += typeset
      }
    case .widget(let widget):
      configureWidget(view, widget: widget, width: width)
    }
  }

  /// The visible sub-range of a placed line leaf's rendered rows (the layout band
  /// already carries the ±overscan) plus the y-offset of that range's first row
  /// relative to the leaf top — pierre `renderRange` { startingLine, totalLines } +
  /// `bufferBefore` (`VirtualizedFile.ts:191/909`). Two O(log n) tree seeks resolve
  /// the window against the tree's CURRENT geometry (so `bufferBefore` already
  /// accounts for any measured deltas of the rows above the window); the leaf then
  /// typesets only these rows and estimates the rest.
  private func lineRenderWindow(_ placement: Placement) -> (rows: Range<Int>, top: CGFloat) {
    let rowCount = placement.top.chunk.baseSummary(metrics: tree.metrics).count(mode)
    // WINDOWING DISABLED (2026-07-06) — the sub-window computation regressed the
    // REAL-app initial render: rows landed at the leaf BOTTOM with an empty top,
    // because the window depends on `visibleRect` at apply time (before the scroll
    // view is sized), a condition the headless controller tests never reproduced.
    // Reverted to whole-leaf typeset (the known-correct render, verified visually
    // pre-windowing). Re-enable windowing ONLY behind a real-NSScrollView layout+draw
    // integration test that asserts rows paint at the right y. Cost: initial typeset
    // is O(leaf) again — the two DiffViewportScalePerfTests are back to withKnownIssue.
    return (0..<rowCount, 0)
  }

  /// Mount (or recycle) the resolved `DiffWidget` model into a `WidgetHostChunkView`
  /// (Phase-6 harness). A recycled host is offered the new model first (identity
  /// swap); an occupied / incompatible host is torn down and re-mounted.
  private func configureWidget(_ view: NSView, widget: Widget, width: CGFloat) {
    guard let host = view as? WidgetHostChunkView else { return }
    guard let model = widgetResolver.resolve(widget, coalescer: coalescer) else {
      host.prepareForReuse()
      return
    }
    if host.mountedKey == widget.key { return }  // already showing this model
    if !host.reuse(model, key: widget.key, width: width) {
      host.prepareForReuse()
      host.mount(model, key: widget.key, width: width, coalescer: coalescer)
    }
  }

  private static func makeView(for kind: DiffReuseKind) -> NSView {
    switch kind {
    case .line: return LineRowView()
    case .widget: return WidgetHostChunkView()
    }
  }

  private func pool(for kind: DiffReuseKind) -> ViewReuseQueue<NSView, ChunkID> {
    if let existing = pools[kind] { return existing }
    let created = ViewReuseQueue<NSView, ChunkID>()
    created.onEnqueue = { view in (view as? DiffViewportRecyclable)?.prepareForReuse() }
    pools[kind] = created
    return created
  }

  /// The anchor identity for a placed chunk — a line chunk keys off its first
  /// rendered row's `(lineNumber, side)`; a widget keys off its `ChunkID`.
  static func anchorIdentity(for hit: ChunkHit, mode: DiffViewMode) -> ScrollAnchor.Identity {
    guard let segment = hit.chunk.lineSegment else { return .widget(hit.id) }
    guard let first = segment.renderedRows(mode).first else { return .widget(hit.id) }
    if let new = first.newNumber { return .line(lineNumber: new, side: .new) }
    if let old = first.oldNumber { return .line(lineNumber: old, side: .old) }
    return .widget(hit.id)
  }

  private func fireVisibleRange() {
    // The visible SOURCE-line window per side (NOT `indexRange`'s widget-shifted,
    // side-shared rendered-row indices — those query the wrong blob region). Deduped
    // so a pure scroll within the same lines does not re-issue an identical query.
    let window = tree.visibleLineRange(in: visibleRect, mode: mode)
    guard window != lastVisibleWindow else { return }
    lastVisibleWindow = window
    onVisibleRangeChanged?(window)
  }

  // MARK: - Scroll anchoring

  /// The pixel-precise position of the current viewport in document space. Uses
  /// the clip's `bounds` (origin == scroll offset, size == clip) — the same rect
  /// `DiffTableController.captureAnchor :477` reads, and window-less by design.
  var visibleRect: CGRect { scrollView.contentView.bounds }

  /// Capture the first *fully* visible materialized chunk (pierre `getScrollAnchor
  /// :445`, `lineOffset >= 0` at `:483`) — NOT the straddling top row of the old
  /// `DiffTableController.captureAnchor :478`. Reads only the bounded materialized
  /// window from the previous layout, so it is valid to call before a mutation.
  func captureAnchor() -> ScrollAnchor? {
    let minY = visibleRect.minY
    if let fully = materialized.first(where: { $0.yOrigin >= minY }) {
      return ScrollAnchor(identity: fully.identity, pixelOffset: fully.yOrigin - minY)
    }
    // Everything straddles the top (e.g. one giant leaf fills the viewport) —
    // anchor the last materialized chunk; its offset can be negative.
    guard let straddling = materialized.last else { return nil }
    return ScrollAnchor(identity: straddling.identity, pixelOffset: straddling.yOrigin - minY)
  }

  /// Re-land the anchored line at the same pixel: read its fresh `yOrigin` from
  /// the materialized window (pierre `scrollFix` reads the freshly rendered
  /// element), fall back to the nearest surviving line when the exact anchor
  /// collapsed, clamp, and scroll instantly (no `NSAnimationContext`).
  func restore(_ anchor: ScrollAnchor) {
    guard let anchorY = materializedYOrigin(anchor.identity) ?? nearestSurvivingYOrigin(anchor.identity) else {
      return
    }
    let targetY = ScrollAnchor.clampedTargetY(
      anchorY: anchorY,
      pixelOffset: anchor.pixelOffset,
      documentHeight: documentView.bounds.height,
      clipHeight: scrollView.contentView.bounds.height
    )
    setScrollY(targetY)
    Self.logger.debug("scroll anchor restored to y=\(targetY)")
  }

  /// The fresh `yOrigin` of the anchored identity in the current materialized
  /// window, or `nil` when it is not materialized (collapsed / off-window).
  private func materializedYOrigin(_ identity: ScrollAnchor.Identity) -> CGFloat? {
    windowMap[identity]
  }

  /// The nearest surviving line (`DiffTableController.nearestSurvivingIndex :496`
  /// analog): when the anchored line collapsed, land on the closest materialized
  /// line on the same side rather than hard-resetting to the top.
  private func nearestSurvivingYOrigin(_ identity: ScrollAnchor.Identity) -> CGFloat? {
    guard case .line(let target, let side) = identity else { return nil }
    var best: (distance: Int, yOrigin: CGFloat)?
    for entry in materialized {
      guard case .line(let line, let entrySide) = entry.identity, entrySide == side else { continue }
      let distance = abs(line - target)
      if best == nil || distance < best!.distance {
        best = (distance, entry.yOrigin)
      }
    }
    return best?.yOrigin
  }

  /// Clamp the current scroll origin into `[0, docHeight − clipHeight]` — the
  /// `DiffTableController :489-490` maxY clamp, applied whenever the document
  /// shrinks below the current offset (a many-collapse) so we never leave the
  /// viewport parked in blank space past the tail.
  private func clampScrollOrigin() {
    let clip = scrollView.contentView
    let maxY = max(0, documentView.bounds.height - clip.bounds.height)
    let clamped = min(max(0, clip.bounds.origin.y), maxY)
    if clamped != clip.bounds.origin.y {
      setScrollY(clamped)
    }
  }

  private func setScrollY(_ yOffset: CGFloat) {
    let clip = scrollView.contentView
    isAdjustingScroll = true
    defer { isAdjustingScroll = false }
    clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: yOffset))
    scrollView.reflectScrolledClipView(clip)
  }

  // MARK: - Measure↔layout guard (C7; live in Phase 3)

  /// Phase 3 wires the C7 guard: each placed `LineRowView` reports its per-row
  /// CoreText-typeset height; any row whose measured (possibly-wrapped) height
  /// differs from the tree's current row height by more than `heightEpsilon` is
  /// written back via `tree.setMeasuredHeight` (O(log n)) and an anchored relayout
  /// is re-queued (bounded by `maxMeasurePasses`). A non-wrapping leaf measures
  /// exactly one row height per row, so nothing differs and `measurePass` stays 0.
  private func runMeasureGuard(_ placed: [(hit: ChunkHit, reservedHeight: CGFloat)]) {
    var needsReflow = false
    for entry in placed {
      guard let view = pools[entry.hit.chunk.reuseKind]?.getView(forKey: entry.hit.id) else { continue }
      if let lineView = view as? LineRowView {
        if writeLineHeights(lineView, chunk: entry.hit.id) { needsReflow = true }
      } else {
        // A widget's whole-view frame height is its measured height (localRow 0).
        let measured = view.frame.height
        if abs(measured - entry.reservedHeight) > heightEpsilon {
          tree.setMeasuredHeight(measured, chunk: entry.hit.id, localRow: entry.hit.localRow, mode: mode)
          needsReflow = true
        }
      }
    }
    // A measured row grew / shrank the tree ⇒ grow the document so the scrollbar
    // reflects the true height (pierre `computeApproximateSize` re-aggregate). Do
    // this even at the pass cap so the final height is never left stale.
    if needsReflow { resizeDocument() }
    guard needsReflow, measurePass < maxMeasurePasses else { return }
    measurePass += 1
    documentView.needsLayout = true
  }

  /// Write each TYPESET (visible-window) row's measured height back into the tree,
  /// but ONLY when it differs from the tree's CURRENT row height (base +
  /// already-written delta) by more than the epsilon — so a converged layout does
  /// not re-trigger reflow (the guard against an unbounded sub-pixel loop). Only the
  /// windowed rows are considered (`typesetRowHeights` carries their leaf-local
  /// index); off-window rows keep whatever delta they earned when last visible, like
  /// pierre's sparse height cache. Returns whether any row changed.
  private func writeLineHeights(_ view: LineRowView, chunk id: ChunkID) -> Bool {
    let heights = view.typesetRowHeights
    guard !heights.isEmpty else { return false }
    let node = tree.nodesByID[id]
    let base = tree.metrics.lineHeight
    var changed = false
    for (localRow, measured) in heights {
      let current = base + (node?.heightDeltas?[localRow]?.value(mode) ?? 0)
      if abs(measured - current) > heightEpsilon {
        tree.setMeasuredHeight(measured, chunk: id, localRow: localRow, mode: mode)
        changed = true
      }
    }
    return changed
  }

  /// Appearance / Dynamic Type / zoom flip: bump the palette's `styleGeneration`,
  /// drop the whole CTLine cache (parse trees survive — they're not here),
  /// re-resolve font metrics, then re-measure the visible window with top-visible
  /// anchoring so the viewport does not jump. Wired from
  /// `DiffViewportView.viewDidChangeEffectiveAppearance`.
  func styleDidChange() {
    DiffPalette.shared.styleDidChange()
    ctLineCache.invalidateStyle()
    metrics = DiffMetrics.resolve()
    let anchor = captureAnchor()
    measurePass = 0
    resizeDocument()
    layoutVisibleChunks()
    if let anchor {
      restore(anchor)
      layoutVisibleChunks()
    }
  }

  // MARK: - Mode toggle (Phase 8 — O(log #hunks) dual-mode re-seek, NO reproject)

  /// Toggle unified↔split WITHOUT reprojecting (C6). The dual-mode tree (Phase 1)
  /// stores `unifiedLineCount` / `splitLineCount` per node, so the toggle never
  /// touches a row array:
  /// 1. resolve the top-visible row to a mode-independent `(chunkID, localRow)`
  ///    anchor via ONE seek in the OLD dimension — O(log n);
  /// 2. flip the render dimension;
  /// 3. re-seek that anchor into the NEW dimension — `rowIndex(for:)` is a rank walk
  ///    (no seek) + one `seek(index:)` for its fresh y — O(log n);
  /// 4. grow / shrink the document to the new mode's height and re-materialize ONLY
  ///    the visible window. Heights are mode-keyed ON THE TREE (`ChunkSummary`'s
  ///    `unified*` / `split*` fields + `LineHeightDelta.unified` / `.split`), so
  ///    there is nothing stale to invalidate — the split column ≈ half width wraps
  ///    differently, and the measure guard re-measures the VISIBLE rows lazily on
  ///    this same pass. No `buildRows`, no O(n) walk.
  ///
  /// The reducer `DiffReviewFeature.diffModeChanged` scope-down (deleting its
  /// `buildRows` loop, leaving flag-persist + `revision` bump) is **Phase 9's** — this
  /// phase only adds the viewport-side re-seek. `tree.diagnostics.seekCount` /
  /// `buildRowsCallCount` pin the "no O(n) reproject" invariant to a number.
  func toggleMode(to newMode: DiffViewMode) {
    let oldMode = mode
    guard newMode != oldMode else { return }
    // (1) Anchor the top-visible row in the OLD dimension (one seek).
    let anchor = tree.seek(y: visibleRect.minY, mode: oldMode).map { (chunk: $0.id, localRow: $0.localRow) }
    // (2) Flip the render dimension.
    mode = newMode
    // (3) Re-seek the anchor into the NEW dimension: `rowIndex(for:)` is a rank walk
    //     (no seek); one `seek(index:)` resolves its fresh y.
    let restoredY: CGFloat? =
      anchor
      .flatMap { tree.rowIndex(for: $0, mode: newMode) }
      .flatMap { tree.seek(index: $0, mode: newMode)?.yOrigin }
    // (4) Re-fit the document + re-land the anchor row at the viewport top, then
    //     materialize the new window (one pass — heights are mode-keyed, nothing
    //     stale to invalidate; visible rows re-measure lazily via the measure guard).
    measurePass = 0
    resizeDocument()
    if let restoredY {
      let maxY = max(0, documentView.bounds.height - visibleRect.height)
      setScrollY(min(max(0, restoredY), maxY))
    }
    clampScrollOrigin()
    layoutVisibleChunks()
    axProvider?.reload()  // unified↔split changes the row count + per-row labels
    Self.logger.debug("mode toggle \(oldMode) → \(newMode) re-seek (no reproject)")
  }

  // MARK: - Geometry API (Phase 6 gutter + Phase 10 scroll-spy)

  /// The document-space rect of a chunk (its top row's `yOrigin` and full
  /// height), or `nil` when the id is not in the current tree.
  func frame(forChunk id: ChunkID) -> CGRect? {
    guard let rowIndex = tree.rowIndex(for: (chunk: id, localRow: 0), mode: mode),
      let top = tree.seek(index: rowIndex, mode: mode)
    else { return nil }
    let rowCount = top.chunk.baseSummary(metrics: tree.metrics).count(mode)
    let next = tree.seek(index: rowIndex + rowCount, mode: mode)
    let height = (next?.yOrigin ?? tree.totalHeight(mode)) - top.yOrigin
    return CGRect(x: 0, y: top.yOrigin, width: documentView.bounds.width, height: height)
  }

  /// Geometric hit-test: `y → chunk` O(log n) + `x → column` via the ≤ 6 x-bands.
  func hitTest(_ point: CGPoint) -> DiffHit? {
    DiffHitTest.hit(point, width: documentView.bounds.width, tree: tree, mode: mode, metrics: metrics)
  }

  /// Scroll to a document-space y (clamped into range) and materialize the new
  /// window. The programmatic-scroll entry point for Phase 10 nav / scroll-spy.
  func scroll(toY yOffset: CGFloat) {
    let clip = scrollView.contentView
    let maxY = max(0, documentView.bounds.height - clip.bounds.height)
    setScrollY(min(max(0, yOffset), maxY))
    layoutVisibleChunks()
  }

  /// The sum of in-use views across every pool — the acceptance bound
  /// (≈ viewport + overscan, independent of tree size).
  var totalUsedViewCount: Int {
    pools.values.reduce(0) { $0 + $1.usedCount }
  }

  /// The bottom of the visible viewport in document space — the streaming
  /// consumer's below-fold-vs-intersecting decision (`insertY > visibleMaxY +
  /// overscan` ⇒ append fast path).
  var visibleMaxY: CGFloat { visibleRect.maxY }

  /// Below-fold append fast path (pierre `appendItemsInternal(…, false)` /
  /// `tryAppendItems`): the tree already grew below the fold, so grow the document
  /// frame and re-materialize the window WITHOUT capturing / restoring a scroll
  /// anchor. The anchored top does not move because everything that changed is
  /// off-screen; the scrollbar simply lengthens as files stream in.
  func appendBelowFold() {
    measurePass = 0
    resizeDocument()
    layoutVisibleChunks()
  }

  // MARK: - Gutter geometry API (Phase 6 — consumed by `GutterRibbonController`)

  /// The line-number gutter-column width (both old / new columns share it). The
  /// gutter ribbon uses it to place the "+" glyph and gate number-column hits.
  var gutterWidth: CGFloat { metrics.gutterWidth }

  /// Side-pinned geometric hit (drag continuation): read the git line number on
  /// `side` under `point.y` regardless of which x-band `point.x` fell in (pierre
  /// `requireNumberColumn: false` on drag, side pinned to the anchor).
  func hitTest(_ point: CGPoint, side: DiffSide) -> DiffHit? {
    DiffHitTest.hit(point, side: side, tree: tree, mode: mode)
  }

  /// The logical location of a rendered row carrying a git line on a side — a
  /// recycle-safe `(chunkID, localRow, rowIndex)` coordinate, the inverse of
  /// `hitTest`.
  struct LineLocation: Equatable {
    let chunkID: ChunkID
    let localRow: Int
    let rowIndex: Int
  }

  /// The `LineLocation` of the rendered row carrying `line` on `side` (an in-order
  /// scan; a user gutter action is infrequent and the target line sits in the
  /// viewport). `nil` when no rendered row carries that number on that side.
  func lineLocation(line: Int, side: DiffSide) -> LineLocation? {
    var hit = tree.seek(index: 0, mode: mode)
    while let current = hit {
      if current.chunk.lineAndSide(for: .gutter(side), localRow: current.localRow, mode: mode).line == line {
        return LineLocation(chunkID: current.id, localRow: current.localRow, rowIndex: current.rowIndex)
      }
      hit = tree.successor(of: current, mode: mode)
    }
    return nil
  }

  /// The document-space rect of the rendered row carrying `line` on `side`, used
  /// to paint the "+" glyph and the drag band. `nil` when the line isn't rendered.
  func lineRect(line: Int, side: DiffSide) -> NSRect? {
    guard let location = lineLocation(line: line, side: side),
      let hit = tree.seek(index: location.rowIndex, mode: mode)
    else { return nil }
    return CGRect(x: 0, y: hit.yOrigin, width: documentView.bounds.width, height: hit.rowHeight)
  }

  /// Build the anchor snippet (the joined text of the covered lines) + up to three
  /// preceding-context lines for a resolved `side` range, read straight off the
  /// `DiffLine`s (mode-independent — relocation keys off the exact line text; ports
  /// `DiffTableController.anchorPayload`). In-order scan (infrequent user action).
  func anchorPayload(side: DiffSide, startLine: Int, endLine: Int) -> (snippet: String, contextBefore: String) {
    var covered: [String] = []
    var preceding: [String] = []
    for node in tree.inorderNodes() {
      guard let segment = node.chunk.lineSegment else { continue }
      for line in segment.windowedLines {
        guard let number = line.lineNumber(on: side) else { continue }
        if number >= startLine, number <= endLine {
          covered.append(line.content)
        } else if number < startLine {
          preceding.append(line.content)
        }
      }
    }
    return (covered.joined(separator: "\n"), preceding.suffix(3).joined(separator: "\n"))
  }

  // MARK: - Widget layout host (Phase 6 — consumed by `LayoutCoalescer`)

  /// Retina pixel-snap a height so a measured widget lands on a device pixel
  /// (`(v·scale).rounded()/scale`) — avoids a sub-pixel measure↔layout wobble.
  func retinaSnap(_ value: CGFloat) -> CGFloat {
    let scale = documentView.window?.backingScaleFactor ?? 2
    return (value * scale).rounded() / scale
  }

  /// The last recorded `(width, height)` a widget was measured at, or `nil` when
  /// it has never been measured (so the first report always applies). Height is
  /// read back from the tree (est + measured delta) in the current `mode`.
  func measuredHeight(forWidget key: WidgetKey) -> (width: CGFloat, height: CGFloat)? {
    guard let width = widgetMeasuredWidth[key], let node = tree.widgetNode(for: key) else { return nil }
    return (width, node.summary.height(mode))
  }

  /// Write a widget's measured height back into the tree (O(log n) re-aggregate)
  /// and record the width it was measured at. No relayout here — the coalescer
  /// captures / restores the scroll anchor once around the whole batch.
  func setMeasuredHeight(_ key: WidgetKey, width: CGFloat, height: CGFloat) {
    guard let node = tree.widgetNode(for: key) else { return }
    tree.setMeasuredHeight(height, chunk: node.id, localRow: 0, mode: mode)
    widgetMeasuredWidth[key] = width
  }

  /// Capture the current scroll anchor (first fully-visible chunk). Public alias
  /// for the coalescer's once-per-frame anchor capture.
  func captureScrollAnchor() -> ScrollAnchor? { captureAnchor() }

  /// Re-grow the document to the tree's fresh height and re-land the anchor at the
  /// same pixel — the once-per-frame anti-jump restore the coalescer runs after a
  /// height batch. Anchoring holds even for a widget ABOVE the fold, because the
  /// anchor is the first fully-visible line, not the mutated widget.
  func restoreScrollAnchor(_ anchor: ScrollAnchor?) {
    measurePass = 0
    resizeDocument()
    clampScrollOrigin()
    layoutVisibleChunks()
    if let anchor {
      restore(anchor)
      layoutVisibleChunks()
    }
  }

  // MARK: - Comment-thread widget harness (Phase 6 — gutter commit / cancel)

  /// Insert an editing comment-thread widget anchored below the bottom
  /// (`endLine`) of a gutter range (pierre insertion flow): `split` the line
  /// segment after the commented row when needed, then `insert(after:)` the
  /// `.widget(.commentThread)` — O(log n). The widget's height reserves via its
  /// `estimatedHeight`, pushing the lines below it down while lines above are
  /// unaffected. Returns the inserted node id, or `nil` when the line isn't found.
  @discardableResult
  func insertCommentWidget(
    side: DiffSide, startLine: Int, endLine: Int, anchorID: UUID, estimatedHeight: CGFloat
  ) -> ChunkID? {
    guard let location = lineLocation(line: endLine, side: side), let node = tree.nodesByID[location.chunkID]
    else { return nil }
    let widget = Widget(
      key: .commentThread(anchorID: anchorID),
      estimatedHeight: estimatedHeight,
      payload: .commentThread(anchorID: anchorID)
    )
    let anchorChunk = splitAnchor(for: node, localRow: location.localRow)
    let inserted = tree.insert(.widget(widget), after: anchorChunk)
    let scrollAnchor = captureAnchor()
    restoreScrollAnchor(scrollAnchor)
    axProvider?.reload()  // a new comment thread widget grows the materialized-row count
    return inserted
  }

  /// Remove the comment-thread widget for `anchorID` (cancel path): the lines
  /// below re-close to their prior pixels. O(log n).
  @discardableResult
  func removeCommentWidget(anchorID: UUID) -> Bool {
    guard let node = tree.widgetNode(for: .commentThread(anchorID: anchorID)) else { return false }
    let scrollAnchor = captureAnchor()
    let removed = tree.remove(node.id)
    restoreScrollAnchor(scrollAnchor)
    axProvider?.reload()  // removing a comment thread widget shrinks the row count
    return removed
  }

  /// The chunk id to insert the widget after: the commented row's own leaf when it
  /// is that leaf's last rendered row (or a single-row leaf), otherwise the LEFT
  /// half of a split so the widget lands directly under the commented line rather
  /// than after the rest of the leaf. Splitting is defined for the 1:1 context
  /// projection; a mid-change-leaf comment inserts after the whole leaf.
  private func splitAnchor(for node: ChunkNode, localRow: Int) -> ChunkID {
    guard let segment = node.chunk.lineSegment else { return node.id }
    let renderedCount = segment.renderedRows(mode).count
    guard localRow + 1 < renderedCount else { return node.id }  // last row → no split
    switch segment.classification {
    case .context, .contextExpanded:
      // 1:1 projection (barring markers): rendered row r ↔ window offset r.
      let offset = localRow + 1
      guard offset > 0, offset < segment.window.count else { return node.id }
      let (left, _) = tree.split(node.id, atLocalRow: offset)
      return left
    case .change:
      return node.id  // coarser placement (after the change block) — never mis-orders
    }
  }
}

// MARK: - WidgetLayoutHost

/// The height write-back + anti-jump surface a `LayoutCoalescer` drives. Abstracted
/// so the coalescer's arithmetic (epsilon, 5-pass guard, `max`-paired, capture /
/// restore once) is unit-testable against a fake host with NO live view / display
/// link (C §CI note).
@MainActor
protocol WidgetLayoutHost: AnyObject {
  func retinaSnap(_ value: CGFloat) -> CGFloat
  func measuredHeight(forWidget key: WidgetKey) -> (width: CGFloat, height: CGFloat)?
  func setMeasuredHeight(_ key: WidgetKey, width: CGFloat, height: CGFloat)
  func captureScrollAnchor() -> ScrollAnchor?
  func restoreScrollAnchor(_ anchor: ScrollAnchor?)
}

extension DiffViewportController: WidgetLayoutHost {}
