import AppKit
import CoreText

/// The rendering inputs a `LineRowView` needs to typeset + paint one `.line`
/// chunk: metrics, the tree's per-sub-line row height, mode, the current document
/// width, the shared `CTLineCache` + `DiffPalette`, and the style generation that
/// keys the cache. Bundled so `configure` stays inside the parameter budget.
@MainActor
struct LineRowRenderContext {
  var metrics: DiffMetrics
  /// The tree's single-sub-line row height (== `ChunkLayoutMetrics.lineHeight`).
  /// A wrapped line is an integer multiple of this — keeps the measured height
  /// consistent with the tree's estimate (a non-wrapped row measures exactly one).
  var rowHeight: CGFloat
  var mode: DiffViewMode
  var width: CGFloat
  var cache: CTLineCache
  var palette: DiffPalette
  var styleGeneration: Int
  /// Whether intra-line word-diff is drawn for this document. The upstream gate
  /// (`WordDiffPolicy`, surfaced as `DiffDocument.wordDiffDisabled`) flips this off
  /// for a massively-changed file so `WordDiff` is never invoked on the render path.
  var wordDiffEnabled: Bool = true
  /// Syntax-highlight generation (Phase 4). Folded into the CTLine cache key only
  /// where the foreground is baked into the glyphs — a syntax arrival re-typesets;
  /// word-diff never does (§Cache + async).
  var syntaxVersion: Int = 0
  /// Word-diff generation. Deliberately EXCLUDED from the CTLine cache key: because
  /// `CTLineDraw` ignores background, a word-diff arrival recomposites + redraws the
  /// row's rects but must NOT re-typeset the glyphs (⚠️ Deepening note 4).
  var wordDiffVersion: Int = 0
  /// The render-layer seam the row PULLS its syntax runs from (pull model): each drawn
  /// row asks the provider for its own line's runs synchronously (a µs span-cache read),
  /// so the overscan the viewport materializes is colored too — no reducer push, no
  /// white overscan band. A cache miss returns `[]` (plain foreground); the async warmer
  /// fills the cache off-main and bumps `syntaxVersion` → the row re-typesets and pulls
  /// its now-cached color.
  ///
  /// LINE SPACE: `LineRowView` holds 1-based SOURCE line numbers; the provider/cache key
  /// is a **0-based BLOB line**. `syntaxRuns` converts with `blobLine = number - 1`.
  /// Empty identity (`nil` OID / query name) ⇒ that side stays plain (unbundled grammar,
  /// over-cap file, or an added/deleted/working-tree side with no counterpart blob).
  var syntaxProvider: SyntaxRunsProvider = .empty
  var oldBlobOID: String?
  var newBlobOID: String?
  var oldQueryName: String?
  var newQueryName: String?
  /// The sub-range of the leaf's rendered rows to actually typeset — the visible
  /// viewport window (+overscan) the viewport resolved via the tree (pierre
  /// `renderRange` { startingLine, totalLines }, `VirtualizedFile.ts:191`). Rows
  /// OUTSIDE this range reserve their estimate height WITHOUT building CTLines
  /// (pierre estimates off-screen line heights). `nil` ⇒ typeset the WHOLE leaf —
  /// the Phase-2-compat / headless-unit entry, which has no viewport to window
  /// against (so `firstRowCTLines` / `measuredRowHeights` see the full leaf).
  var renderRange: Range<Int>?
  /// The y-offset of `renderRange`'s first row RELATIVE to the leaf top (== this
  /// view's own origin), read from the tree in O(log n) by the viewport (pierre
  /// `renderRange.bufferBefore`). The windowed rows lay out from here so they paint
  /// at their true document y even though the rows above them were never typeset.
  var renderRangeTop: CGFloat = 0
}

/// Renders one `.line` **chunk** (a dense leaf) as real wrapped code via CoreText
/// (Phase 3 — replaces the plain `NSString.draw` placeholder). One view per chunk;
/// it typesets ONLY the rendered rows inside the viewport window (+overscan) the
/// controller resolves — pierre `renderRange` (`VirtualizedFile.ts:191`), NOT the
/// whole ≤5000-row leaf. Off-window rows reserve their estimate height without
/// building CTLines (pierre estimates off-screen line heights). The measured,
/// possibly-wrapped height of the WINDOWED rows is available to the viewport's
/// measure guard WITHOUT a draw pass; wrapped `CTLine`s are cached by content
/// identity; and it paints — under the text — the gutter substrate (row tint +
/// change bars) plus right-aligned line numbers, everything retina pixel-snapped.
/// A scroll that slides the window re-typesets the newly-exposed rows lazily and
/// releases the CTLines of rows that left it, so per-frame typeset work stays
/// O(window), never O(leaf).
///
/// Not an accessibility element (Phase 12 seam S2): diff a11y is owned by the
/// synthesized `DiffLineAXElement`s on the `documentView`, so a recycled row view
/// must not compete as an AX identity.
@MainActor
final class LineRowView: NSView, DiffViewportRecyclable {
  /// One rendered row of the leaf, in the SAME order + count as
  /// `LineSegment.renderedRows(mode)` so `measuredRowHeights[i]` maps 1:1 to the
  /// tree's local row `i`.
  private struct RowRender {
    var oldNumber: Int?
    var newNumber: Int?
    /// Full-row origin (unified) or `nil` for a marker row.
    var unifiedOrigin: DiffLineOrigin?
    var oldOrigin: DiffLineOrigin?  // split old-pane substrate origin (nil = empty pane)
    var newOrigin: DiffLineOrigin?  // split new-pane substrate origin
    var content: NSString?  // unified content column
    var oldContent: NSString?  // split old pane
    var newContent: NSString?  // split new pane
    /// Intra-line word-diff spans for the unified content column (a deletion row's
    /// `oldSpans` / an addition row's `newSpans`); empty when word-diff is off.
    var unifiedWordSpans: [WordDiff.Span] = []
    /// Word-diff spans for the split old pane (`oldSpans`).
    var oldWordSpans: [WordDiff.Span] = []
    /// Word-diff spans for the split new pane (`newSpans`).
    var newWordSpans: [WordDiff.Span] = []
    var wrapped: LineTypesetter.Wrapped?  // unified column
    var oldWrapped: LineTypesetter.Wrapped?
    var newWrapped: LineTypesetter.Wrapped?
    var isMarker: Bool
    var markerText: NSString?
    var height: CGFloat
    var top: CGFloat
  }

  private var rows: [RowRender] = []
  private var context = LineRowView.defaultContext()
  private var totalHeight: CGFloat = 0

  /// The view-space union rect of the rows (re)built by the last `typesetRows` pass — the
  /// exposed strip the incremental repaint invalidates instead of the whole leaf view.
  private var lastBuiltRect: NSRect = .zero

  /// The sub-range of `rows` currently typeset (CTLines built) — the visible
  /// window the last `configure` resolved. For the whole-leaf compat path this is
  /// `0..<rows.count`. Only these rows carry `wrapped` glyphs, have a valid `top`,
  /// are painted, and flow into the measure guard; everything else reserves its
  /// estimate height. A pure scroll that leaves this unchanged is a no-op.
  private var typesetWindow: Range<Int> = 0..<0

  /// The `bufferBefore` (window-top offset relative to this view) the current window was
  /// last laid out from. A same-window re-place whose `renderRangeTop` moved (the leaf
  /// shifted, or measured deltas above the window changed) must RE-LAY-OUT so the rows
  /// paint at their new y — comparing the window range alone would leave them stale.
  private var typesetTop: CGFloat = 0

  /// Rendered-row count of the currently configured segment (O(1)). The viewport
  /// accumulates this per layout as its parallel-safe "rows (re)configured this
  /// frame" perf counter — a pure scroll of already-materialized chunks must not
  /// grow it once the configure early-out lands.
  var renderedRowCount: Int { rows.count }

  /// The chunk currently configured onto this view — recycle diagnostics only.
  private(set) var configuredChunkID: ChunkID?

  /// What invalidates the ROW MODEL (`project()` — the whole ≤maxLeafSpan leaf): the
  /// leaf identity, the render mode (split vs unified changes the row structure), and
  /// the word-diff gate (spans are computed in `project`). Deliberately EXCLUDES
  /// width + syntax + appearance — those change only how the SAME rows TYPESET, not
  /// which rows exist. Folding `syntaxVersion` in here re-walked the entire leaf on
  /// every windowed-highlight arrival (≈ every scroll frame) — the O(leaf)-per-frame
  /// scroll stall.
  private struct ProjectKey: Equatable {
    var chunkID: ChunkID
    // `chunkID` is NOT unique across trees — every `ChunkTree` restarts its id counter at
    // 0 (`ChunkTree.nextRaw`), so a leaf at position N in file A and file B share `chunkID
    // == N`. A recycled `LineRowView` pooled by `chunkID` is therefore handed a DIFFERENT
    // file's leaf under the SAME `chunkID` on a file switch; keying only on `chunkID` made
    // `configure` early-out and keep the PREVIOUS file's rows while the new file's syntax
    // recoloured them — the previous file's text in the new file's colors ("плавающая
    // каша"). `hunkID` (carries the fileID) + `window` restore a real per-leaf content
    // identity so a cross-file / re-windowed reuse always re-projects. O(1) — no hot-path
    // cost (a pure scroll reuses the same leaf ⇒ same key ⇒ early-out preserved).
    var hunkID: HunkID
    var window: Range<Int>
    var mode: DiffViewMode
    var wordDiffEnabled: Bool
  }
  /// What invalidates the TYPESET of the already-projected rows (re-wrap / re-colour
  /// the visible window, NO re-project): the content width (→ wrap), the syntax-runs
  /// generation (→ foreground baked into glyphs), and the appearance/Dynamic-Type
  /// generation. A change here re-typesets the window; it never rebuilds the row model.
  private struct TypesetKey: Equatable {
    var width: CGFloat
    var syntaxVersion: Int
    var styleGeneration: Int
  }
  private var configuredProjectKey: ProjectKey?
  private var configuredTypesetKey: TypesetKey?

  /// The `FileID` of the leaf currently configured onto this view (one leaf == one file).
  /// The controller resolves each leaf's blobs by this, so it's the identity a diagnostic
  /// uses to check the row was highlighted from the RIGHT file's blob.
  private(set) var configuredFileID: FileID?

  override var isFlipped: Bool { true }
  override var wantsDefaultClipping: Bool { true }
  /// `draw(_:)` fills `bounds` opaquely (textBackgroundColor) before anything else, so
  /// declaring the view opaque is truthful — and it lets `NSClipView.copiesOnScroll` blit
  /// the still-visible pixels and hand `draw` only the newly-exposed strip as `dirtyRect`,
  /// instead of the whole viewport (the `maxDirtyH ≈ visible height every frame` waste).
  override var isOpaque: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  // MARK: - Recycle probes (Phase 2)

  /// The number of rendered rows currently configured (recycle diagnostics).
  var configuredRowCount: Int { rows.count }

  /// The content text of the first rendered row (the `recycledViewHasNoStaleContent`
  /// probe — after a reconfigure this is the NEW leaf's content, never a ghost).
  var firstRowText: String? {
    guard let first = rows.first else { return nil }
    return (first.content ?? first.oldContent ?? first.newContent ?? first.markerText) as String?
  }

  /// Test probe: the wrapped `CTLine`s of the first rendered row's unified content
  /// column (nil for a marker / split-only row). Lets a headless render test assert
  /// the syntax foreground actually baked into the CoreText runs the viewport draws.
  var firstRowCTLines: [CTLine]? { rows.first?.wrapped?.ctLines }

  /// One typeset (visible-window) row's source text, keyed by leaf-local rendered-row
  /// index — the render-fidelity probe (pierre `collectRowSourceMismatches`). Named
  /// so the accessor stays inside the tuple-arity lint.
  struct VisibleRowText: Equatable {
    var localRow: Int
    var unified: String?
    var old: String?
    var new: String?
  }

  /// Test probe: the SOURCE text of each row currently inside the typeset window.
  /// Proves the windowed render shows the RIGHT text at the RIGHT row — not merely
  /// the right count — for unified (`unified`) and split (`old` / `new`) alike.
  var visibleRowTexts: [VisibleRowText] {
    typesetWindow.compactMap { index in
      guard index < rows.count else { return nil }
      let row = rows[index]
      return VisibleRowText(
        localRow: index, unified: row.content as String?, old: row.oldContent as String?,
        new: row.newContent as String?)
    }
  }

  /// Test probe: per-typeset-row identity + drawn CTLines for the windowed-render
  /// color-fidelity check (the dense-leaf + live-scroll path `firstRowCTLines` can't
  /// reach). Unified column only; at a non-wrapping width each row is one CTLine whose
  /// string indices are 0-based within the row content.
  struct TypesetRowRender {
    var localRow: Int
    var oldNumber: Int?
    var newNumber: Int?
    var unifiedOrigin: DiffLineOrigin?
    var content: String?
    var ctLines: [CTLine]
  }

  /// Test probe: every typeset row's identity + unified CTLines.
  var typesetRowRenders: [TypesetRowRender] {
    typesetWindow.compactMap { index in
      guard index < rows.count else { return nil }
      let row = rows[index]
      return TypesetRowRender(
        localRow: index, oldNumber: row.oldNumber, newNumber: row.newNumber, unifiedOrigin: row.unifiedOrigin,
        content: row.content as String?, ctLines: row.wrapped?.ctLines ?? [])
    }
  }

  /// The measured height of each rendered row (each an integer multiple of the
  /// tree's row height). For the WHOLE-leaf compat path (headless unit tests) every
  /// row is measured; in the windowed viewport path only the typeset window carries
  /// a measured value. The measure guard reads `typesetRowHeights`, not this.
  var measuredRowHeights: [CGFloat] { rows.map(\.height) }

  /// The `(localRow, measuredHeight)` pairs for the rows typeset in the current
  /// window — the ONLY rows the viewport's C7 measure guard writes back via
  /// `setMeasuredHeight`. Off-window rows are never re-measured until they scroll
  /// into the window, so their tree height (estimate + any prior measured delta)
  /// stands — pierre keeps unmeasured lines at their estimate (sparse height cache,
  /// `VirtualizedFile.ts:37`). `localRow` is the leaf-local rendered-row index, so
  /// the guard writes the RIGHT row even when the window starts mid-leaf.
  var typesetRowHeights: [(localRow: Int, height: CGFloat)] {
    typesetWindow.compactMap { index in
      index < rows.count ? (index, rows[index].height) : nil
    }
  }

  /// One typeset row's leaf-local layout — its `top` (relative to this view) and `height`,
  /// so a drawn row's DOCUMENT y is `view.frame.minY + top`.
  struct RowFrameProbe: Equatable {
    var localRow: Int
    var top: CGFloat
    var height: CGFloat
  }

  /// Test probe: each typeset row's leaf-local frame. Proves rows lay out CONTIGUOUSLY from
  /// the view top (no gap, no bottom-anchoring) — the exact geometry the scroll layer
  /// paints. Pairs with `visibleRowTexts` (content).
  var typesetRowFrames: [RowFrameProbe] {
    typesetWindow.compactMap { index in
      index < rows.count ? RowFrameProbe(localRow: index, top: rows[index].top, height: rows[index].height) : nil
    }
  }

  /// The total typeset height covered so far (bufferBefore + Σ windowed row
  /// heights). The viewport grows this view's frame to at least this so a freshly
  /// wrapped windowed row is never clipped before the tree catches up; the leaf's
  /// full reserved height (from the tree) still bounds the frame from below.
  var totalMeasuredHeight: CGFloat { totalHeight }

  // MARK: - Configuration

  /// Phase-2-compatible entry (kept so `ViewReuseQueueTests` and any caller that
  /// only has `rowHeight` + `font` still resolve). Builds a default render context.
  func configure(segment: LineSegment, chunkID: ChunkID, rowHeight: CGFloat, font: NSFont, mode: DiffViewMode) {
    let charWidth = max(1, ("0" as NSString).size(withAttributes: [.font: font]).width)
    let metrics = DiffMetrics(
      font: font, lineHeight: rowHeight, charWidth: charWidth, vPad: 1, hPad: 6, gutterWidth: charWidth * 5 + 8)
    configure(
      segment: segment,
      chunkID: chunkID,
      context: LineRowRenderContext(
        metrics: metrics,
        rowHeight: rowHeight,
        mode: mode,
        width: max(bounds.width, 800),
        cache: Self.fallbackCache,
        palette: .shared,
        styleGeneration: DiffPalette.shared.styleGeneration
      )
    )
  }

  /// The rich entry the viewport uses. Projects the leaf's rendered rows only when
  /// the configuration actually changed (leaf / width / mode / syntax / appearance /
  /// word-diff — the `ConfigKey`, which deliberately EXCLUDES the scroll window),
  /// then typesets ONLY the rows inside `context.renderRange` (the visible window +
  /// overscan). Three outcomes:
  ///  • same key AND same window ⇒ a pure scroll of an unchanged window: no work,
  ///    returns 0 (the line-segment analog of the widget host's `mountedKey == key`);
  ///  • same key, window moved ⇒ re-typeset the newly-exposed rows lazily WITHOUT
  ///    re-projecting (pierre "renders visible lines in hunk-sized batches as you
  ///    scroll"); the rows that left the window release their CTLines;
  ///  • key changed ⇒ re-project + typeset the window fresh.
  /// Returns the NUMBER OF ROWS typeset this pass, so the viewport's perf counter
  /// measures real (windowed) typeset work, not the whole segment and not free
  /// scroll re-placements.
  @discardableResult
  func configure(segment: LineSegment, chunkID: ChunkID, context: LineRowRenderContext) -> Int {
    let projectKey = ProjectKey(
      chunkID: chunkID, hunkID: segment.hunkID, window: segment.window, mode: context.mode,
      wordDiffEnabled: context.wordDiffEnabled)
    let typesetKey = TypesetKey(
      width: context.width, syntaxVersion: context.syntaxVersion, styleGeneration: context.styleGeneration)
    self.context = context  // keep the fresh palette / word-diff / syntax generation for redraw

    // Re-PROJECT the row model only when the leaf structure changes — NOT on a syntax /
    // width / appearance change. Rebuilding the whole ≤maxLeafSpan leaf on every
    // windowed-highlight arrival was the O(leaf)-per-frame scroll stall.
    var reprojected = false
    if configuredProjectKey != projectKey || rows.isEmpty {
      self.configuredChunkID = chunkID
      self.configuredProjectKey = projectKey
      self.configuredFileID = segment.hunkID.fileID
      self.rows = Self.project(segment: segment, mode: context.mode, wordDiffEnabled: context.wordDiffEnabled)
      self.typesetWindow = 0..<0
      isHidden = false
      reprojected = true
    }

    let window = clampedRenderRange(context)
    // Pure scroll of an unchanged window with unchanged typeset inputs ⇒ no work.
    if !reprojected, configuredTypesetKey == typesetKey, window == typesetWindow,
      context.renderRangeTop == typesetTop
    {
      return 0
    }
    // Same typeset inputs (width / syntax / appearance), window merely SHIFTED ⇒ reuse the
    // surviving rows' glyphs and typeset ONLY the newly-exposed rows (incremental). A key
    // change or a reproject invalidates every row's glyphs ⇒ rebuild the whole window.
    let reuseExisting = !reprojected && configuredTypesetKey == typesetKey
    // Whether the whole windowed band shifted document-y (a measured height change above the
    // window). When it hasn't, the survivor rows are byte-identical at their document-fixed
    // positions, so only the newly-built rows need repainting.
    let bandMoved = context.renderRangeTop != typesetTop
    self.configuredTypesetKey = typesetKey
    let typeset = typesetRows(window: window, top: context.renderRangeTop, reuseExisting: reuseExisting)
    if reuseExisting, !bandMoved {
      // Incremental repaint: invalidate ONLY the exposed strip, not the whole (viewport-
      // spanning) leaf view. The window backing keeps the survivors' pixels, so `draw` gets
      // a narrow `dirtyRect` instead of the full visible height every scroll frame.
      if typeset > 0 { setNeedsDisplay(lastBuiltRect) }
    } else {
      needsDisplay = true  // fresh projection / full re-typeset / the whole band shifted
    }
    return typeset
  }

  /// The context's requested window clamped into `rows` — `nil` (compat / headless)
  /// means "the whole leaf" so the unit paths still typeset every rendered row.
  private func clampedRenderRange(_ context: LineRowRenderContext) -> Range<Int> {
    guard let range = context.renderRange else { return 0..<rows.count }
    let lower = min(max(0, range.lowerBound), rows.count)
    let upper = min(max(lower, range.upperBound), rows.count)
    return lower..<upper
  }

  /// Unmount hook — clears stale content so the next borrower of this recycled
  /// view can never render a ghost of the prior leaf (pierre `onPostRenderPhase`).
  override func prepareForReuse() {
    rows = []
    configuredChunkID = nil
    configuredFileID = nil
    configuredProjectKey = nil
    configuredTypesetKey = nil
    typesetWindow = 0..<0
    typesetTop = 0
    totalHeight = 0
    needsDisplay = true
  }

  // MARK: - Typesetting

  /// Typeset (build CTLines for) ONLY the rows in `window`, laying them out from
  /// `bufferBefore` (the window's top relative to this view — the viewport reads it
  /// from the tree in O(log n), pierre `renderRange.bufferBefore`). Rows outside the
  /// window reserve their estimate height and hold NO CTLines: the rows that just
  /// left the previous window release theirs so retained glyph runs stay bounded by
  /// the window, not the leaf. `totalHeight` becomes `bufferBefore + Σ windowed
  /// heights` (the frame-growth floor). Returns the count of rows typeset this pass.
  @discardableResult
  private func typesetRows(window: Range<Int>, top bufferBefore: CGFloat, reuseExisting: Bool) -> Int {
    let previousWindow = typesetWindow
    let rowHeight = context.rowHeight
    // Release the CTLines of rows that scrolled out of the window (bounded by the
    // previous window, so this stays O(window) — never O(leaf)).
    for index in previousWindow where !window.contains(index) && index < rows.count {
      rows[index].wrapped = nil
      rows[index].oldWrapped = nil
      rows[index].newWrapped = nil
      rows[index].height = rowHeight
    }

    let geo = geometry()
    let style = LineTypesetter.paragraphStyle(advance: context.metrics.charWidth)
    var built = 0
    var builtRect = NSRect.zero
    var top = bufferBefore
    for index in window {
      if rows[index].isMarker {
        rows[index].height = rowHeight
        rows[index].top = top
        top += rowHeight
        continue
      }
      // Incremental: a survivor row (in the prior window, glyphs still held) with unchanged
      // typeset inputs only needs its `top` repositioned — skip the re-wrap. Rebuild only
      // the newly-exposed rows. This is the "whole window re-wraps every frame though it
      // shifted a few rows" fix; `built` (the return value) counts only genuine rebuilds.
      if reuseExisting, previousWindow.contains(index), rowHasGlyphs(index) {
        rows[index].top = top
        top += rows[index].height
        continue
      }
      built += 1
      let rowTop = top
      switch context.mode {
      case .unified:
        let content = rows[index].content ?? ""
        let isOldSide = rows[index].unifiedOrigin == .deletion  // a deletion row shows the OLD line
        let runs = syntaxRuns(
          oldNumber: rows[index].oldNumber, newNumber: rows[index].newNumber, isOldSide: isOldSide)
        let wrapped = wrap(content, width: geo.unifiedContentWidth, style: style, rowHeight: rowHeight, syntax: runs)
        rows[index].wrapped = wrapped
        rows[index].height = wrapped.height
      case .split:
        var height = rowHeight
        if let old = rows[index].oldContent {
          let runs = syntaxRuns(oldNumber: rows[index].oldNumber, newNumber: nil, isOldSide: true)
          let wrapped = wrap(old, width: geo.oldContentWidth, style: style, rowHeight: rowHeight, syntax: runs)
          rows[index].oldWrapped = wrapped
          height = max(height, wrapped.height)
        }
        if let new = rows[index].newContent {
          let runs = syntaxRuns(oldNumber: nil, newNumber: rows[index].newNumber, isOldSide: false)
          let wrapped = wrap(new, width: geo.newContentWidth, style: style, rowHeight: rowHeight, syntax: runs)
          rows[index].newWrapped = wrapped
          height = max(height, wrapped.height)
        }
        rows[index].height = height
      }
      rows[index].top = top
      top += rows[index].height
      let rowRect = NSRect(x: 0, y: rowTop, width: context.width, height: rows[index].height)
      builtRect = builtRect.isEmpty ? rowRect : builtRect.union(rowRect)
    }
    lastBuiltRect = builtRect
    totalHeight = top
    typesetWindow = window
    typesetTop = bufferBefore
    return built
  }

  /// Whether row `index` currently holds the wrapped glyphs it WOULD rebuild in the
  /// current mode — the reuse gate for the incremental typeset. A content column with no
  /// text needs no glyphs, so it never blocks reuse; a column with text must already carry
  /// its `Wrapped` (else it was released and must rebuild).
  private func rowHasGlyphs(_ index: Int) -> Bool {
    let row = rows[index]
    switch context.mode {
    case .unified:
      return row.content == nil || row.wrapped != nil
    case .split:
      let oldReady = row.oldContent == nil || row.oldWrapped != nil
      let newReady = row.newContent == nil || row.newWrapped != nil
      return oldReady && newReady
    }
  }

  /// Cache-through typeset of one content string at a content width. The syntax runs
  /// are folded into the cache key (their resolved fg is baked into the glyphs), so a
  /// highlight arrival re-typesets the row while an unchanged line stays a cache hit;
  /// `styleGeneration` (in the key) re-typesets on an appearance flip so the resolved
  /// `HighlightTheme` colors track light/dark.
  private func wrap(
    _ content: NSString, width: CGFloat, style: NSParagraphStyle, rowHeight: CGFloat, syntax: [StyleRun]
  ) -> LineTypesetter.Wrapped {
    var hasher = Hasher()
    hasher.combine(content.hash)
    hasher.combine(syntax)
    let key = context.cache.key(
      contentHash: hasher.finalize(), styleGeneration: context.styleGeneration, width: width)
    return context.cache.wrapped(key) {
      let attributed = LineTypesetter.attributed(content, font: context.metrics.font, style: style, syntax: syntax)
      return LineTypesetter.wrap(attributed, width: width, lineHeight: rowHeight)
    }
  }

  /// The syntax runs for a rendered row's content column, PULLED from the span cache via
  /// the provider: old-blob runs for a deletion (the row shows the old line), new-blob
  /// runs otherwise. Converts the row's 1-based source line number to the provider's
  /// 0-based blob line (`number - 1`). Empty when the side has no blob identity or the
  /// cache has not yet been warmed for that line.
  private func syntaxRuns(oldNumber: Int?, newNumber: Int?, isOldSide: Bool) -> [StyleRun] {
    if isOldSide {
      guard let oldNumber, let oid = context.oldBlobOID, let query = context.oldQueryName else { return [] }
      return context.syntaxProvider.runs(oid, query, oldNumber - 1)
    }
    guard let newNumber, let oid = context.newBlobOID, let query = context.newQueryName else { return [] }
    return context.syntaxProvider.runs(oid, query, newNumber - 1)
  }

  // MARK: - Geometry (matches `DiffHitTest.bands` so render + hit-test agree)

  private struct Geometry {
    var barWidth: CGFloat
    var gutterWidth: CGFloat
    var hPad: CGFloat
    // Unified bands.
    var unifiedOldNumX: CGFloat
    var unifiedNewNumX: CGFloat
    var unifiedBarX: CGFloat
    var unifiedContentX: CGFloat
    var unifiedContentWidth: CGFloat
    // Split panes.
    var mid: CGFloat
    var oldNumX: CGFloat
    var oldContentX: CGFloat
    var oldContentWidth: CGFloat
    var newBarX: CGFloat
    var newNumX: CGFloat
    var newContentX: CGFloat
    var newContentWidth: CGFloat
  }

  private func geometry() -> Geometry {
    let bar = GutterRenderer.changeBarWidth
    let gutter = context.metrics.gutterWidth
    let hPad = context.metrics.hPad
    let width = context.width
    let unifiedContentX = 2 * bar + 2 * gutter
    let mid = (width / 2).rounded()
    let oldContentX = bar + gutter
    let newContentX = mid + bar + gutter
    return Geometry(
      barWidth: bar,
      gutterWidth: gutter,
      hPad: hPad,
      unifiedOldNumX: bar,
      unifiedNewNumX: 2 * bar + gutter,
      unifiedBarX: bar + gutter,
      unifiedContentX: unifiedContentX,
      unifiedContentWidth: max(0, width - unifiedContentX - hPad),
      mid: mid,
      oldNumX: bar,
      oldContentX: oldContentX,
      oldContentWidth: max(0, mid - oldContentX - hPad),
      newBarX: mid,
      newNumX: mid + bar,
      newContentX: newContentX,
      newContentWidth: max(0, width - newContentX - hPad)
    )
  }

  // MARK: - Drawing

  override func draw(_ dirtyRect: NSRect) {
    NSColor.textBackgroundColor.setFill()
    // Fill only our OWN bounds — NOT `dirtyRect`. AppKit hands each subview the whole
    // invalidated region (the full viewport) in its own coordinates, and an NSView does
    // NOT clip drawing to its bounds by default, so `dirtyRect.fill()` would paint this
    // leaf's background across every SIBLING leaf's position and erase them — leaving only
    // the last-drawn leaf visible (the "only one hunk renders" bug; single-hunk files have
    // no sibling to erase, so they looked fine).
    bounds.fill()
    guard !rows.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
    let scale = window?.backingScaleFactor ?? 2
    let geo = geometry()
    let gutter = GutterRenderer(metrics: context.metrics, scale: scale, palette: context.palette)
    ctx.textMatrix = .identity
    // Only the typeset window carries CTLines + a valid `top`; off-window rows are
    // never painted (they are off-screen by construction of the window).
    for index in typesetWindow where index < rows.count {
      let row = rows[index]
      guard row.top < dirtyRect.maxY, row.top + row.height > dirtyRect.minY else { continue }
      switch context.mode {
      case .unified: drawUnified(row, geo: geo, gutter: gutter, scale: scale, in: ctx)
      case .split: drawSplit(row, geo: geo, gutter: gutter, scale: scale, in: ctx)
      }
    }
  }

  private func drawUnified(
    _ row: RowRender, geo: Geometry, gutter: GutterRenderer, scale: CGFloat, in ctx: CGContext
  ) {
    let rowRect = CGRect(x: 0, y: row.top, width: bounds.width, height: row.height)
    if row.isMarker {
      drawMarker(row.markerText, originX: geo.unifiedContentX, top: row.top)
      return
    }
    gutter.draw(
      row: LineRowGeometry(rowRect: rowRect, barX: geo.unifiedBarX),
      origin: row.unifiedOrigin ?? .context,
      in: ctx)
    // Opaque number-column fill behind BOTH numbers on a changed row (pierre parity).
    if let origin = row.unifiedOrigin {
      gutter.drawNumberColumn(
        CGRect(x: geo.unifiedOldNumX, y: row.top, width: geo.gutterWidth, height: row.height), origin: origin, in: ctx)
      gutter.drawNumberColumn(
        CGRect(x: geo.unifiedNewNumX, y: row.top, width: geo.gutterWidth, height: row.height), origin: origin, in: ctx)
    }
    drawNumber(row.oldNumber, originX: geo.unifiedOldNumX, top: row.top)
    drawNumber(row.newNumber, originX: geo.unifiedNewNumX, top: row.top)
    if let wrapped = row.wrapped {
      drawContent(
        wrapped,
        wordDiff: WordDiffLayer(spans: row.unifiedWordSpans, isOld: row.unifiedOrigin == .deletion),
        origin: CGPoint(x: geo.unifiedContentX, y: row.top), scale: scale, in: ctx)
    }
  }

  private func drawSplit(
    _ row: RowRender, geo: Geometry, gutter: GutterRenderer, scale: CGFloat, in ctx: CGContext
  ) {
    if row.isMarker {
      drawMarker(row.markerText, originX: geo.oldContentX, top: row.top)
      return
    }
    let oldRect = CGRect(x: 0, y: row.top, width: geo.mid, height: row.height)
    let newRect = CGRect(x: geo.mid, y: row.top, width: bounds.width - geo.mid, height: row.height)
    drawPane(
      PaneRender(
        wrapped: row.oldWrapped, origin: row.oldOrigin, number: row.oldNumber, paneRect: oldRect, barX: 0,
        numberX: geo.oldNumX, contentX: geo.oldContentX, wordSpans: row.oldWordSpans, isOld: true),
      gutter: gutter, scale: scale, in: ctx)
    drawPane(
      PaneRender(
        wrapped: row.newWrapped, origin: row.newOrigin, number: row.newNumber, paneRect: newRect, barX: geo.newBarX,
        numberX: geo.newNumX, contentX: geo.newContentX, wordSpans: row.newWordSpans, isOld: false),
      gutter: gutter, scale: scale, in: ctx)
    // Center divider.
    NSColor.separatorColor.setFill()
    CGRect(x: geo.mid, y: row.top, width: 1, height: row.height).fill()
  }

  /// The resolved geometry + content for one pane of a split row.
  private struct PaneRender {
    var wrapped: LineTypesetter.Wrapped?
    var origin: DiffLineOrigin?
    var number: Int?
    var paneRect: CGRect
    var barX: CGFloat
    var numberX: CGFloat
    var contentX: CGFloat
    var wordSpans: [WordDiff.Span] = []
    /// `true` for the deletion (old) pane — selects the del-side word-diff color.
    var isOld: Bool = false
  }

  private func drawPane(_ pane: PaneRender, gutter: GutterRenderer, scale: CGFloat, in ctx: CGContext) {
    guard let origin = pane.origin else {  // empty pane (no counterpart) — 45° hatch buffer (C5), no number / content.
      EmptySideHatch.draw(in: pane.paneRect, into: ctx)
      return
    }
    gutter.draw(row: LineRowGeometry(rowRect: pane.paneRect, barX: pane.barX), origin: origin, in: ctx)
    // Opaque number-column fill behind this pane's number on a changed row (pierre parity).
    gutter.drawNumberColumn(
      CGRect(
        x: pane.numberX, y: pane.paneRect.minY, width: context.metrics.gutterWidth, height: pane.paneRect.height),
      origin: origin, in: ctx)
    drawNumber(pane.number, originX: pane.numberX, top: pane.paneRect.minY)
    if let wrapped = pane.wrapped {
      drawContent(
        wrapped,
        wordDiff: WordDiffLayer(spans: pane.wordSpans, isOld: pane.isOld),
        origin: CGPoint(x: pane.contentX, y: pane.paneRect.minY), scale: scale, in: ctx)
    }
  }

  /// Right-aligned line number (secondary label), drawn via TextKit (flipped-aware).
  private func drawNumber(_ number: Int?, originX: CGFloat, top: CGFloat) {
    guard let number else { return }
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .right
    let attributes: [NSAttributedString.Key: Any] = [
      .font: context.metrics.font,
      .foregroundColor: NSColor.secondaryLabelColor,
      .paragraphStyle: paragraph,
    ]
    let vPad = context.metrics.vPad
    let inset = NSRect(
      x: originX, y: top + vPad, width: context.metrics.gutterWidth - 4, height: context.rowHeight - 2 * vPad)
    (String(number) as NSString).draw(in: inset, withAttributes: attributes)
  }

  /// Draw a no-newline marker row (secondary, no substrate).
  private func drawMarker(_ text: NSString?, originX: CGFloat, top: CGFloat) {
    guard let text else { return }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: context.metrics.font,
      .foregroundColor: NSColor.secondaryLabelColor,
    ]
    let inset = NSRect(
      x: originX, y: top + context.metrics.vPad, width: max(1, bounds.width - originX), height: context.rowHeight)
    text.draw(in: inset, withAttributes: attributes)
  }

  /// Draw one content column's word-diff background rects THEN its glyphs, in the
  /// strict `DiffRowLayer` order — the row tint is already painted by the gutter, so
  /// this covers layers 2 (word-diff, behind the glyphs) and 3 (glyphs). The
  /// per-sub-line baseline geometry is shared with the word-diff pass via
  /// `WrappedSubLine.lines` so a background rect lands exactly under its glyphs. The
  /// per-sub-line save/translate/scale flips CoreText's y-up glyph space right-side-up
  /// inside this flipped `NSView`; `CTLineDraw` ignores background (hence the separate
  /// hand-filled rects).
  /// The intra-line word-diff inputs for one content column (bundled so the draw
  /// call stays within the parameter budget).
  private struct WordDiffLayer {
    var spans: [WordDiff.Span]
    /// `true` for the deletion (old) side — selects the del-side emphasis color.
    var isOld: Bool
  }

  private func drawContent(
    _ wrapped: LineTypesetter.Wrapped, wordDiff: WordDiffLayer, origin: CGPoint, scale: CGFloat, in ctx: CGContext
  ) {
    let subLines = WrappedSubLine.lines(
      from: wrapped, font: context.metrics.font, origin: origin, rowHeight: context.rowHeight, scale: scale)
    // Layer 2 — word-diff rects (on top of the row tint, behind the glyphs).
    if context.wordDiffEnabled, !wordDiff.spans.isEmpty {
      WordDiffBackgroundPainter.fill(
        spans: wordDiff.spans, subLines: subLines,
        color: context.palette.wordEmphasis(isOld: wordDiff.isOld).cgColor, scale: scale, in: ctx)
    }
    // Layer 3 — glyphs.
    for sub in subLines {
      ctx.saveGState()
      ctx.textMatrix = .identity
      ctx.translateBy(x: sub.origin.x, y: sub.origin.y)
      ctx.scaleBy(x: 1, y: -1)
      ctx.textPosition = .zero
      CTLineDraw(sub.line, ctx)
      ctx.restoreGState()
    }
  }

  // MARK: - Projection (mirrors `SegmentProjection.renderedRows` order + count)

  /// Perf spy (mirrors `CTLineCache.buildCount`): total `project()` calls — a full
  /// row-model rebuild of a leaf (O(leaf)). A syntax / width / appearance change must
  /// NOT grow this (only a leaf / mode / word-diff change does); the
  /// `syntaxBumpDoesNotReprojectMaterializedLeaf` guard pins that a windowed-highlight
  /// arrival re-typesets the window without re-projecting the whole ≤maxLeafSpan leaf.
  static var projectCount = 0

  private static func project(segment: LineSegment, mode: DiffViewMode, wordDiffEnabled: Bool) -> [RowRender] {
    projectCount += 1
    switch segment.classification {
    case .context, .contextExpanded:
      return projectContext(segment, mode: mode)
    case .change:
      return mode == .unified
        ? projectUnifiedChange(segment, wordDiffEnabled: wordDiffEnabled)
        : projectSplitChange(segment, wordDiffEnabled: wordDiffEnabled)
    }
  }

  private static func projectContext(_ segment: LineSegment, mode: DiffViewMode) -> [RowRender] {
    var out: [RowRender] = []
    for line in segment.windowedLines {
      if mode == .unified {
        out.append(
          RowRender(
            oldNumber: line.oldLineNumber, newNumber: line.newLineNumber, unifiedOrigin: .context,
            content: line.content as NSString, isMarker: false, height: 0, top: 0))
      } else {
        out.append(
          RowRender(
            oldNumber: line.oldLineNumber, newNumber: line.newLineNumber, oldOrigin: .context, newOrigin: .context,
            oldContent: line.content as NSString, newContent: line.content as NSString, isMarker: false, height: 0,
            top: 0))
      }
      appendMarkerIfNeeded(&out, old: line, new: line)
    }
    return out
  }

  private static func projectUnifiedChange(_ segment: LineSegment, wordDiffEnabled: Bool) -> [RowRender] {
    let dels = segment.windowDeletions
    let adds = segment.windowAdditions
    // Pair deletion[i] ↔ addition[i] for intra-line word-diff — the SAME pairing the
    // split projection uses, so unified and split emit identical spans (mode-agnostic).
    let paired = Self.wordDiffPairs(dels: dels, adds: adds, enabled: wordDiffEnabled)
    var out: [RowRender] = []
    for (index, line) in dels.enumerated() {
      out.append(
        RowRender(
          oldNumber: line.oldLineNumber, newNumber: line.newLineNumber, unifiedOrigin: line.origin,
          content: line.content as NSString, unifiedWordSpans: paired.old[index], isMarker: false, height: 0, top: 0))
      appendMarkerIfNeeded(&out, old: line, new: nil)
    }
    for (index, line) in adds.enumerated() {
      out.append(
        RowRender(
          oldNumber: line.oldLineNumber, newNumber: line.newLineNumber, unifiedOrigin: line.origin,
          content: line.content as NSString, unifiedWordSpans: paired.new[index], isMarker: false, height: 0, top: 0))
      appendMarkerIfNeeded(&out, old: nil, new: line)
    }
    return out
  }

  private static func projectSplitChange(_ segment: LineSegment, wordDiffEnabled: Bool) -> [RowRender] {
    let dels = segment.windowDeletions
    let adds = segment.windowAdditions
    let paired = Self.wordDiffPairs(dels: dels, adds: adds, enabled: wordDiffEnabled)
    var out: [RowRender] = []
    for index in 0..<max(dels.count, adds.count) {
      let old = index < dels.count ? dels[index] : nil
      let new = index < adds.count ? adds[index] : nil
      out.append(
        RowRender(
          oldNumber: old?.oldLineNumber, newNumber: new?.newLineNumber,
          oldOrigin: old != nil ? .deletion : nil, newOrigin: new != nil ? .addition : nil,
          oldContent: old.map { $0.content as NSString }, newContent: new.map { $0.content as NSString },
          oldWordSpans: index < paired.old.count ? paired.old[index] : [],
          newWordSpans: index < paired.new.count ? paired.new[index] : [],
          isMarker: false, height: 0, top: 0))
      appendMarkerIfNeeded(&out, old: old, new: new)
    }
    return out
  }

  /// Intra-line word-diff spans for a change segment, keyed by side index. Pairs
  /// deletion[i] ↔ addition[i] and runs `WordDiff` on the NSString hot path; an
  /// unpaired trailing deletion / addition (count mismatch) gets no word-diff (only
  /// the row tint), matching pierre. `enabled == false` ⇒ all-empty (the upstream
  /// `WordDiffPolicy` gate: `WordDiff` is never invoked).
  private static func wordDiffPairs(
    dels: [DiffLine], adds: [DiffLine], enabled: Bool
  ) -> (old: [[WordDiff.Span]], new: [[WordDiff.Span]]) {
    var old = [[WordDiff.Span]](repeating: [], count: dels.count)
    var new = [[WordDiff.Span]](repeating: [], count: adds.count)
    guard enabled else { return (old, new) }
    for index in 0..<min(dels.count, adds.count) {
      let result = WordDiff.diff(old: dels[index].content as NSString, new: adds[index].content as NSString)
      old[index] = result.oldSpans
      new[index] = result.newSpans
    }
    return (old, new)
  }

  private static func appendMarkerIfNeeded(_ out: inout [RowRender], old: DiffLine?, new: DiffLine?) {
    guard (old?.noNewlineAtEof ?? false) || (new?.noNewlineAtEof ?? false) else { return }
    out.append(
      RowRender(
        oldNumber: old?.oldLineNumber, newNumber: new?.newLineNumber, isMarker: true,
        markerText: "No newline at end of file" as NSString, height: 0, top: 0))
  }

  // MARK: - Defaults

  /// A shared fallback cache for the Phase-2-compat `configure` overload. The
  /// viewport-driven path always injects its own cache via the render context.
  private static let fallbackCache = CTLineCache()

  private static func defaultContext() -> LineRowRenderContext {
    LineRowRenderContext(
      metrics: .resolve(), rowHeight: ChunkLayoutMetrics.production.lineHeight, mode: .unified, width: 800,
      cache: fallbackCache, palette: .shared, styleGeneration: 0)
  }
}

/// Plain placeholder for a `.widget` chunk (file header / hunk header / expander /
/// comment / placeholder). Phase 6 replaces this with the real widget host views;
/// here it exists so the recycle loop, the per-`reuseKind` pooling, and the
/// `WidgetKey → MODEL` seam are exercisable. It records the `WidgetKey` it was
/// configured with — the MODEL identity — proving that after a pool recycle the
/// view resolves the RIGHT model (keyed by `WidgetKey`), never the stale prior
/// one, while the pool itself is keyed by `ChunkID`.
@MainActor
final class DiffWidgetPlaceholderView: NSView, DiffViewportRecyclable {
  private(set) var configuredKey: WidgetKey?
  private(set) var configuredChunkID: ChunkID?

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  func configure(widget: Widget, chunkID: ChunkID) {
    configuredKey = widget.key
    configuredChunkID = chunkID
    isHidden = false
    needsDisplay = true
  }

  override func prepareForReuse() {
    configuredKey = nil
    configuredChunkID = nil
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.textBackgroundColor.setFill()
    dirtyRect.fill()
  }
}
