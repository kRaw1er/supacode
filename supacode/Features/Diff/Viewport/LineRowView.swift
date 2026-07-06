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
}

/// Renders one `.line` **chunk** (a dense leaf) as real wrapped code via CoreText
/// (Phase 3 — replaces the plain `NSString.draw` placeholder). One view per chunk;
/// it typesets every rendered row of its leaf in `configure` (so the measured,
/// possibly-wrapped height is available to the viewport's measure guard WITHOUT a
/// draw pass), caches wrapped `CTLine`s by content identity, and paints — under
/// the text — the gutter substrate (row tint + change bars) plus right-aligned
/// line numbers, everything retina pixel-snapped.
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

  /// The chunk currently configured onto this view — recycle diagnostics only.
  private(set) var configuredChunkID: ChunkID?

  override var isFlipped: Bool { true }
  override var wantsDefaultClipping: Bool { true }

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

  /// The measured height of each rendered row (each an integer multiple of the
  /// tree's row height). The viewport's C7 measure guard writes any per-row delta
  /// back into the tree via `setMeasuredHeight` (O(log n)).
  var measuredRowHeights: [CGFloat] { rows.map(\.height) }

  /// The total typeset height of the whole leaf (Σ row heights). The viewport
  /// grows this view's frame to at least this so a wrapped row is never clipped
  /// mid-pass while the tree catches up.
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

  /// The rich entry the viewport uses. Typesets every rendered row up front so the
  /// measure guard has heights before any draw.
  func configure(segment: LineSegment, chunkID: ChunkID, context: LineRowRenderContext) {
    self.context = context
    self.configuredChunkID = chunkID
    self.rows = Self.project(segment: segment, mode: context.mode, wordDiffEnabled: context.wordDiffEnabled)
    typesetRows()
    isHidden = false
    needsDisplay = true
  }

  /// Unmount hook — clears stale content so the next borrower of this recycled
  /// view can never render a ghost of the prior leaf (pierre `onPostRenderPhase`).
  override func prepareForReuse() {
    rows = []
    configuredChunkID = nil
    totalHeight = 0
    needsDisplay = true
  }

  // MARK: - Typesetting

  private func typesetRows() {
    let geo = geometry()
    let style = LineTypesetter.paragraphStyle(advance: context.metrics.charWidth)
    let rowHeight = context.rowHeight
    var top: CGFloat = 0
    for index in rows.indices {
      if rows[index].isMarker {
        rows[index].height = rowHeight
        rows[index].top = top
        top += rowHeight
        continue
      }
      switch context.mode {
      case .unified:
        let content = rows[index].content ?? ""
        let wrapped = wrap(content, width: geo.unifiedContentWidth, style: style, rowHeight: rowHeight)
        rows[index].wrapped = wrapped
        rows[index].height = wrapped.height
      case .split:
        var height = rowHeight
        if let old = rows[index].oldContent {
          let wrapped = wrap(old, width: geo.oldContentWidth, style: style, rowHeight: rowHeight)
          rows[index].oldWrapped = wrapped
          height = max(height, wrapped.height)
        }
        if let new = rows[index].newContent {
          let wrapped = wrap(new, width: geo.newContentWidth, style: style, rowHeight: rowHeight)
          rows[index].newWrapped = wrapped
          height = max(height, wrapped.height)
        }
        rows[index].height = height
      }
      rows[index].top = top
      top += rows[index].height
    }
    totalHeight = top
  }

  /// Cache-through typeset of one content string at a content width.
  private func wrap(
    _ content: NSString, width: CGFloat, style: NSParagraphStyle, rowHeight: CGFloat
  ) -> LineTypesetter.Wrapped {
    let key = context.cache.key(
      contentHash: content.hash, styleGeneration: context.styleGeneration, width: width)
    return context.cache.wrapped(key) {
      let attributed = LineTypesetter.attributed(content, font: context.metrics.font, style: style)
      return LineTypesetter.wrap(attributed, width: width, lineHeight: rowHeight)
    }
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
    dirtyRect.fill()
    guard !rows.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
    let scale = window?.backingScaleFactor ?? 2
    let geo = geometry()
    let gutter = GutterRenderer(metrics: context.metrics, scale: scale, palette: context.palette)
    ctx.textMatrix = .identity
    for row in rows where row.top < dirtyRect.maxY && row.top + row.height > dirtyRect.minY {
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

  private static func project(segment: LineSegment, mode: DiffViewMode, wordDiffEnabled: Bool) -> [RowRender] {
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
