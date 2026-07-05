import AppKit

/// Plain monospace placeholder for one `.line` **chunk** (a dense leaf). One view
/// per chunk — it draws every rendered row of its leaf (old / new line-number
/// gutters + content) via `draw(_:)`, clipped by the dirty rect so an off-screen
/// row inside a tall leaf costs nothing. Deliberately throwaway detail: Phase 3
/// replaces the body with the `CTLine` typesetter. Its only job here is to prove
/// the recycle loop places real, content-bearing views at kernel scale.
///
/// Not an accessibility element (Phase 12 seam S2): diff a11y is owned by the
/// synthesized `DiffLineAXElement`s installed on the `documentView`, so a
/// recycled row view must not compete as an AX identity.
@MainActor
final class LineRowView: NSView, DiffViewportRecyclable {
  private typealias RowContent = (row: RenderedRow, text: String)

  private var rows: [RowContent] = []
  private var rowHeight: CGFloat = 0
  private var font: NSFont = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

  /// The chunk currently configured onto this view — recycle diagnostics only.
  private(set) var configuredChunkID: ChunkID?

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setAccessibilityElement(false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// The number of rendered rows currently configured (recycle diagnostics).
  var configuredRowCount: Int { rows.count }

  /// The content text of the first rendered row (the `recycledViewHasNoStaleContent`
  /// probe — after a reconfigure this is the NEW leaf's content, never a ghost).
  var firstRowText: String? { rows.first?.text }

  func configure(segment: LineSegment, chunkID: ChunkID, rowHeight: CGFloat, font: NSFont, mode: DiffViewMode) {
    self.rows = Self.rowsWithContent(segment, mode: mode)
    self.rowHeight = rowHeight
    self.font = font
    self.configuredChunkID = chunkID
    isHidden = false
    needsDisplay = true
  }

  /// Unmount hook — clears stale content so the next borrower of this recycled
  /// view can never render a ghost of the prior leaf (pierre `onPostRenderPhase`).
  /// Overrides `NSView.prepareForReuse()` and satisfies `DiffViewportRecyclable`.
  override func prepareForReuse() {
    rows = []
    configuredChunkID = nil
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.textBackgroundColor.setFill()
    dirtyRect.fill()
    guard rowHeight > 0, !rows.isEmpty else { return }
    let first = max(0, Int((dirtyRect.minY / rowHeight).rounded(.down)))
    let last = min(rows.count, Int((dirtyRect.maxY / rowHeight).rounded(.up)))
    guard first < last else { return }
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
    for index in first..<last {
      let (row, text) = rows[index]
      let old = row.oldNumber.map(String.init) ?? ""
      let new = row.newNumber.map(String.init) ?? ""
      let prefix = row.isMarker ? "\\ " : "\(old)\t\(new)\t"
      let line = "\(prefix)\(text)" as NSString
      line.draw(at: NSPoint(x: 4, y: CGFloat(index) * rowHeight), withAttributes: attributes)
    }
  }

  /// Pair each rendered row (numbers / origin / marker — matching
  /// `SegmentProjection.renderedRows`) with its content text. Kept local because
  /// the projection intentionally omits content (scalars-only tree); Phase 3's
  /// typesetter reads content straight from the UTF-16 store instead.
  private static func rowsWithContent(_ segment: LineSegment, mode: DiffViewMode) -> [RowContent] {
    var out: [RowContent] = []
    func emit(old: DiffLine?, new: DiffLine?, origin: DiffLineOrigin) {
      let source = new ?? old
      out.append(
        (
          RenderedRow(oldNumber: old?.oldLineNumber, newNumber: new?.newLineNumber, origin: origin, isMarker: false),
          source?.content ?? ""
        )
      )
      if (old?.noNewlineAtEof ?? false) || (new?.noNewlineAtEof ?? false) {
        out.append(
          (
            RenderedRow(
              oldNumber: old?.oldLineNumber, newNumber: new?.newLineNumber, origin: .noNewlineMarker, isMarker: true),
            "No newline at end of file"
          )
        )
      }
    }
    switch segment.classification {
    case .context, .contextExpanded:
      for line in segment.windowedLines { emit(old: line, new: line, origin: .context) }
    case .change:
      if mode == .unified {
        for line in segment.windowDeletions { emit(old: line, new: nil, origin: .deletion) }
        for line in segment.windowAdditions { emit(old: nil, new: line, origin: .addition) }
      } else {
        let deletions = segment.windowDeletions
        let additions = segment.windowAdditions
        for index in 0..<max(deletions.count, additions.count) {
          let old = index < deletions.count ? deletions[index] : nil
          let new = index < additions.count ? additions[index] : nil
          emit(old: old, new: new, origin: new != nil ? .addition : .deletion)
        }
      }
    }
    return out
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
