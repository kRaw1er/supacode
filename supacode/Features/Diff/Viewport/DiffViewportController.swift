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

  /// Repaint signal for the pull-model span cache: bumped by the warmer when a fill
  /// grows the cache for the render window, so the configure early-out never skips a
  /// colour change and each drawn row re-pulls its now-cached runs from the provider.
  private(set) var syntaxVersion = 0

  // MARK: - Pull-model warming (Phase B — fills the span cache for the render window)

  /// The per-side blobs the warmer parses (fed from the reducer's
  /// `DiffDocument.old/newBlob`), or `nil` on an added / deleted / working-tree side.
  private(set) var oldBlob: HighlightBlobInput?
  private(set) var newBlob: HighlightBlobInput?
  /// The size gate (`DiffDocument.highlightingDisabled`): `true` ⇒ render plain, no warm.
  private(set) var highlightingDisabled = false

  /// The span-cache engine the warmer fills. Defaults to the shared instance so every
  /// open tab reuses one bounded parse cache; a test injects a FRESH engine so its
  /// assertions don't collide with the app-wide live cache.
  var highlightEngine: DiffHighlightEngine = .shared

  /// The in-flight warm, cancelled + restarted on each trigger so a scroll burst
  /// collapses to a single fill. `private(set)` so the warm test can `await` it to
  /// drive the async fill to completion.
  private(set) var highlightWarmTask: Task<Void, Never>?

  /// Test instrumentation (parallel-safe, per controller — mirrors `lineRowsConfigured`):
  /// the number of warm TASKS actually launched. A warm over an already-filled window
  /// launches none (no missing lines), so this pins the "a warm scroll re-queries
  /// nothing" invariant to a number.
  private(set) var highlightWarmLaunchCount = 0

  /// Store the per-side blobs + size gate and kick a warm pass: the span cache fills
  /// off-main for the render window, then each drawn row pulls its runs from the cache
  /// (pull model). Called on every blob / size-gate change.
  func setHighlightBlobs(old: HighlightBlobInput?, new: HighlightBlobInput?, disabled: Bool) {
    oldBlob = old
    newBlob = new
    highlightingDisabled = disabled
    warmVisibleHighlights()
  }

  /// Fill the span cache for the VISIBLE + overscan window, per side, off-main and
  /// coalesced — querying ONLY the blob lines not already cached. The view pulls each
  /// drawn row's runs from the filled cache (pull model). Called after every layout
  /// settles and from `setHighlightBlobs`.
  private func warmVisibleHighlights() {
    // Mirror `layoutVisibleChunks`' preconditions: no warm when plain-gated, when there
    // is nothing to parse, or before the viewport has a real width.
    guard !highlightingDisabled else { return }
    guard oldBlob != nil || newBlob != nil else { return }
    guard documentView.bounds.width > 0 else { return }

    // The render window the layout materializes: visible band expanded by the overscan
    // the renderer draws, clamped to the document — the whole point (the reducer's
    // visible-only query never covered these rows).
    let window = tree.visibleLineRange(in: expandedRenderRect(), mode: mode)

    // Resolve each side's still-uncached 0-based blob-line gaps. A side with no grammar,
    // no blob, or an already-warm window contributes nothing (a warm scroll is a no-op).
    var work: [(blob: HighlightBlobInput, gaps: [Range<Int>])] = []
    for (blob, lineRange) in [(oldBlob, window.old), (newBlob, window.new)] {
      guard let blob, let queryName = DiffHighlightEngine.grammarQueryName(forPath: blob.path) else { continue }
      let blobLines = DiffHighlightEngine.blobWindow(forLineNumbers: lineRange)
      let gaps = highlightEngine.missingBlobLines(blobOID: blob.blobOID, queryName: queryName, blobLines: blobLines)
      guard !gaps.isEmpty else { continue }
      work.append((blob, gaps))
    }
    guard !work.isEmpty else { return }

    // Coalesce: drop the prior in-flight warm and start a fresh one, so a scroll burst
    // collapses to one fill. Each side's parse runs off-main inside `styleRuns`.
    highlightWarmTask?.cancel()
    highlightWarmLaunchCount += 1
    highlightWarmTask = Task { [weak self, highlightEngine] in
      for entry in work {
        for gap in entry.gaps {
          if Task.isCancelled { return }
          _ = await highlightEngine.styleRuns(for: entry.blob, visibleLines: gap)
        }
      }
      if Task.isCancelled { return }
      // The cache grew for the render window: bump the repaint signal AND re-typeset the
      // materialized rows so each pulls its now-cached color (pull model). The re-layout
      // re-enters `warmVisibleHighlights`, but the window is now fully warm (no missing
      // lines) → it returns without launching another task → no loop.
      self?.repaintForSyntaxFill()
    }
  }

  /// Bump the repaint signal and re-typeset the materialized rows so each pulls its
  /// now-cached runs from the span cache (pull model). `syntaxVersion` folds into the
  /// render context so a bump re-typesets WITHOUT re-projecting the leaf (the project
  /// key excludes it). Called by the warmer on a cache fill.
  func repaintForSyntaxFill() {
    syntaxVersion &+= 1
    layoutVisibleChunks()
  }

  /// The visible viewport band expanded by `Self.overscan` on each side and clamped to
  /// the document — the exact render window `placeVisibleChunksOnce` materializes
  /// against, so the warm covers every drawn (incl. overscan) row.
  private func expandedRenderRect() -> CGRect {
    visibleRect.insetBy(dx: 0, dy: -Self.overscan).intersection(documentView.bounds)
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
  /// is a valid `WidgetLayoutHost` before it binds. Driven by `documentView`'s
  /// `NSView.displayLink` so a variable-height widget (the Camp A inline comment
  /// composer, an image-compare widget) reflows as it grows — the link stays paused
  /// until a height is enqueued and re-pauses on settle (5-pass loop guard).
  private lazy var coalescer = LayoutCoalescer(host: self, displayLinkView: documentView)

  /// Test seam: the per-frame widget height coalescer, so the viewport-wiring test
  /// can assert it is display-link-driven (F#14) and drive a height batch through it.
  var widgetCoalescerForTesting: LayoutCoalescer { coalescer }

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
  /// Fires on a clip-view SIZE change (window / split-pane resize) — the scroll
  /// observer above only fires on origin changes (scroll). Without it a width
  /// change never re-tiles until the next scroll (every wrapped line stays wrapped
  /// at the old width).
  private nonisolated(unsafe) var frameObserver: NSObjectProtocol?

  /// The clip width the last layout ran at. A `frameDidChange` that leaves the width
  /// unchanged (a height-only resize, or a scroller show/hide) skips the
  /// anchor-preserving re-wrap and just re-tiles — a pure vertical resize does not
  /// re-typeset a single line.
  private var lastLaidOutWidth: CGFloat = 0

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
    scrollView.contentView.postsFrameChangedNotifications = true
    boundsObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: scrollView.contentView,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.viewportMoved() }
    }
    frameObserver = NotificationCenter.default.addObserver(
      forName: NSView.frameDidChangeNotification,
      object: scrollView.contentView,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.viewportResized() }
    }
  }

  deinit {
    if let boundsObserver {
      NotificationCenter.default.removeObserver(boundsObserver)
    }
    if let frameObserver {
      NotificationCenter.default.removeObserver(frameObserver)
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
    adoptGutterForLineNumbers()
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
    lastLaidOutWidth = width
    documentView.frame = CGRect(x: 0, y: 0, width: width, height: tree.totalHeight(mode))
  }

  /// Widen the line-number gutter to fit the tree's largest line number (F#7). The
  /// resolved default hardcodes ~5 digits, so a file whose line numbers exceed
  /// 99,999 — or a long file below a short one in a multi-file diff — would clip its
  /// numbers. `withGutter` recomputes the gutter from `charWidth`, so calling it on
  /// an already-guttered metrics is idempotent; every content swap re-resolves it.
  private func adoptGutterForLineNumbers() {
    metrics = metrics.withGutter(forMaxLineNumber: tree.maxLineNumber)
  }

  // MARK: - The recycle loop

  /// Scroll or resize → coalesce to one layout pass (pierre `queueRender` / rAF
  /// analog; AppKit collapses many `needsLayout` to one `layout()` per frame).
  private func viewportMoved() {
    guard !isAdjustingScroll else { return }
    documentView.needsLayout = true
  }

  /// The clip view resized (window drag / split-pane drag / inspector toggle). A
  /// width change re-wraps every line and shifts the total height, so mirror
  /// `styleDidChange`'s anchor-preserving relayout — capture the first visible line,
  /// re-fit the document, re-tile, and re-land the anchor — rather than leaving the
  /// old wrap until the next scroll. Runs in real time (on every `frameDidChange`),
  /// not just at `viewDidEndLiveResize`, so the viewport re-flows AS the user drags.
  /// A height-only resize keeps the same width and skips the re-wrap. `internal` so
  /// the resize regression test can drive it directly (the `frameDidChange`
  /// notification is delivered async on the main run loop, which a headless test
  /// does not spin).
  func viewportResized() {
    guard !isAdjustingScroll else { return }
    let newWidth = scrollView.contentSize.width
    guard newWidth != lastLaidOutWidth else {
      documentView.needsLayout = true  // height-only: just re-tile, no re-wrap
      return
    }
    lastLaidOutWidth = newWidth
    let anchor = captureAnchor()
    measurePass = 0
    resizeDocument()
    clampScrollOrigin()
    layoutVisibleChunks()
    if let anchor {
      restore(anchor)
      layoutVisibleChunks()
    }
  }

  /// Seek the visible window (+ overscan), diff desired vs live per pool, place
  /// one view per intersecting chunk at its `yOrigin`, recycle everything that
  /// scrolled off. O(log n) seek + O(chunks-in-window) walk — the view count is
  /// bounded by the window, independent of the tree size.
  func layoutVisibleChunks() {
    // Converge measure↔layout WITHIN this pass. The first sweep positions each leaf from
    // the tree's CURRENT row heights, but an unmeasured wrapped leaf still carries its
    // 1-row ESTIMATE there while `LineRowView` draws it at its full (taller) MEASURED
    // height — so adjacent leaves would overlap by the wrap delta. Historically the fix
    // was requeued to a LATER AppKit `layout()`, which never catches up during a
    // continuous scroll of a long-lined file: leaves scroll in mis-tiled and stay that way
    // (the reported "only a few rows, overlapping, on page 2, changing each scroll" bug).
    // So we write the measured heights back and RE-PLACE against them synchronously,
    // bounded by `maxMeasurePasses`. A non-wrapping file measures == estimate on the first
    // sweep, so it converges in one pass (no added cost for the 100k-line hot path).
    // Keep the document's width locked to the clip on every pass. `apply` can run in
    // `makeNSView` BEFORE SwiftUI sizes the scroll view (documentView width == 0); nothing
    // else re-fits the document on a pure resize, so without this the first real layout would
    // place every chunk at a stale width. A `.widget` host mounted at width 0 renders its
    // SwiftUI content collapsed at the left and never recovers, so we must reach real width
    // BEFORE the first materialization (line rows recover on their own via re-typeset; a
    // hosted SwiftUI view does not).
    if documentView.bounds.width != scrollView.contentSize.width { resizeDocument() }
    // Defer materialization until the viewport has a real width — the first placement then
    // mounts every widget host at full width instead of at 0 (pierre never renders a 0-wide
    // viewport). The scroll view's sizing fires a fresh `layout()` → `layoutVisibleChunks`.
    guard documentView.bounds.width > 0 else { return }

    measurePass = 0
    while true {
      let placed = placeVisibleChunksOnce()
      guard applyMeasuredHeights(placed) else { break }
      measurePass += 1
      if measurePass >= maxMeasurePasses { break }
    }
    fireVisibleRange()
    warmVisibleHighlights()  // pull-model: fill the span cache for the settled render window (Phase B)
  }

  /// One placement sweep: seek the visible window (+ overscan), place one view per
  /// intersecting chunk at its current tree `yOrigin`, recycle everything that scrolled
  /// off. Returns the placed `(hit, reservedHeight)` pairs so the measure guard can write
  /// their drawn heights back. O(log n) seek + O(chunks-in-window).
  private func placeVisibleChunksOnce() -> [(hit: ChunkHit, reservedHeight: CGFloat)] {
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
      let rowCount = renderedRowCount(top)
      let next = tree.seek(index: top.rowIndex + rowCount, mode: mode)
      let height = (next?.yOrigin ?? tree.totalHeight(mode)) - top.yOrigin
      place(top, height: height, width: width, window: window, live: &live)
      placed.append((top, height))
      chunkTop = next
    }

    for (kind, pool) in pools {
      pool.enqueueViews(notInSet: live[kind] ?? [])
    }
    return placed
  }

  /// Rendered-row count of a placed chunk in the current mode — O(1) from the tree's
  /// cached `node.summary` (a leaf's base counts never change; only measured HEIGHTS
  /// do). The old `chunk.baseSummary(...).count(mode)` re-filtered the whole
  /// ≤maxLeafSpan leaf on EVERY place of EVERY frame — an O(leaf) scroll cost.
  private func renderedRowCount(_ top: ChunkHit) -> Int {
    tree.nodesByID[top.id]?.summary.count(mode) ?? top.chunk.baseSummary(metrics: tree.metrics).count(mode)
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
            syntaxProvider: .live(highlightEngine),
            oldBlobOID: oldBlob?.blobOID,
            newBlobOID: newBlob?.blobOID,
            oldQueryName: oldBlob.flatMap { DiffHighlightEngine.grammarQueryName(forPath: $0.path) },
            newQueryName: newBlob.flatMap { DiffHighlightEngine.grammarQueryName(forPath: $0.path) },
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
    let top = placement.top
    let rowCount = renderedRowCount(top)
    guard rowCount > 0 else { return (0..<0, 0) }
    let leafTop = top.yOrigin
    let leafBottom = leafTop + placement.height
    let windowTop = max(placement.window.minY, leafTop)
    let windowBottom = min(placement.window.maxY, leafBottom)
    guard windowBottom > windowTop else { return (0..<0, 0) }  // leaf not actually in the window
    let clampedBottom = min(windowBottom, leafBottom - 0.001)

    // Fast path — a leaf with NO measured height deltas has uniform (base) row heights,
    // so the window resolves by arithmetic with ZERO tree seeks. Keeps the per-layout
    // seek budget O(log n × window), not O(window) seeks (a scroll over many small
    // leaves would otherwise add two seeks per leaf).
    let rowHeight = tree.metrics.lineHeight
    if rowHeight > 0, tree.nodesByID[top.id]?.heightDeltas?.isEmpty ?? true {
      let startLocal = min(max(0, Int((windowTop - leafTop) / rowHeight)), rowCount - 1)
      let endRow = min(rowCount - 1, Int((clampedBottom - leafTop) / rowHeight))
      let end = min(rowCount, max(startLocal, endRow) + 1)
      return (startLocal..<end, CGFloat(startLocal) * rowHeight)
    }

    // Variable-height leaf (some rows wrapped): resolve the window via two O(log n) seeks
    // so `bufferBefore` accounts for the measured deltas of the rows above it.
    let startHit = tree.seek(y: windowTop, mode: mode)
    let startLocal = min(max(0, startHit?.localRow ?? 0), rowCount - 1)
    let startY = startHit?.yOrigin ?? leafTop
    let endHit = tree.seek(y: clampedBottom, mode: mode)
    let endLocal = min(rowCount, (endHit?.localRow ?? (rowCount - 1)) + 1)
    let start = min(startLocal, rowCount)
    let end = min(max(start, endLocal), rowCount)
    return (start..<end, startY - leafTop)
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
    guard let first = segment.firstRenderedRow(mode) else { return .widget(hit.id) }
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
  /// CoreText-typeset height; any row whose measured (possibly-wrapped) height differs
  /// from the tree's current row height by more than `heightEpsilon` is written back via
  /// `tree.setMeasuredHeight` (O(log n)) and the document is grown to match. Returns
  /// whether anything changed, so `layoutVisibleChunks` re-places against the reconciled
  /// geometry in the SAME frame (no async requeue → no scroll-time overlap). A
  /// non-wrapping leaf measures exactly one row height per row, so nothing differs, this
  /// returns `false`, and the layout converges in a single sweep.
  private func applyMeasuredHeights(_ placed: [(hit: ChunkHit, reservedHeight: CGFloat)]) -> Bool {
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
    // A measured row grew / shrank the tree ⇒ grow the document so the scrollbar reflects
    // the true height (pierre `computeApproximateSize` re-aggregate).
    if needsReflow { resizeDocument() }
    return needsReflow
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
    adoptGutterForLineNumbers()
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
    let rowCount = renderedRowCount(top)
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
