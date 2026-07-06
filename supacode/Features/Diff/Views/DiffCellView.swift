import AppKit

// NOTE: `DiffMetrics` was relocated to
// `Features/Diff/Viewport/CoreText/DiffMetrics.swift` in Phase 3 (⚠️ Deepening
// note 4 / S8) so the new CoreText render layer and the old table viewer share
// one definition. The type name is unchanged; nothing else in this file moved.

/// Composited styling for one row's code content: a syntax **foreground** pass
/// (system-color theme) and an independent intra-line word-diff **background**
/// pass. The two never collide — one sets `foregroundColor`, the other
/// `backgroundColor`. Only the new side carries syntax spans (highlighted from
/// the working-tree file); deletions show pre-image text and stay plain.
struct RowHighlight: Equatable {
  /// Line-relative UTF-16 syntax spans for the new-side content.
  var syntaxNew: [SyntaxHighlighter.HighlightSpan] = []
  /// Word-diff spans on the old (deletion / split-left) content.
  var wordOld: [WordDiff.Span] = []
  /// Word-diff spans on the new (addition / split-right) content.
  var wordNew: [WordDiff.Span] = []

  static let empty = RowHighlight()
}

/// A single recycled cell that renders any `DiffRow` kind by custom drawing —
/// no retained `NSTextField` per row. One reuse identifier feeds the whole
/// table, so recycling is a single pool. Split rows draw both panes inside the
/// one full-width cell for pixel-exact structural alignment.
final class DiffCellView: NSView {
  /// The row's interaction callbacks, bundled so `configure` stays within the
  /// parameter-count budget.
  struct Callbacks {
    let onExpand: (Int) -> Void
    let onCommentTap: (UUID) -> Void
    /// Non-hover "Add comment" path for VoiceOver: resolves the row's side + line.
    var onAddComment: (DiffSide, Int) -> Void = { _, _ in }
  }

  private var row: DiffRow?
  private var metrics = DiffMetrics.resolve()
  private var mode: DiffViewMode = .unified
  private var callbacks: Callbacks?
  private var highlight: RowHighlight = .empty

  override var isFlipped: Bool { true }
  override var wantsDefaultClipping: Bool { true }

  func configure(
    row: DiffRow,
    metrics: DiffMetrics,
    mode: DiffViewMode,
    highlight: RowHighlight,
    callbacks: Callbacks
  ) {
    self.row = row
    self.metrics = metrics
    self.mode = mode
    self.highlight = highlight
    self.callbacks = callbacks
    needsDisplay = true
  }

  // NOTE: VoiceOver exposure for the diff body moved OUT of this recycled view in
  // Phase 12. A recycled cell republishing role/label on every `configure` is the
  // pool-coupled a11y model the new viewport rejects; the synthesized
  // `DiffLineAXElement`s on the `documentView` own diff a11y now, and the pure
  // string logic (`axLabel` / `lineLabel` / `commentAnchor`) moved verbatim into
  // `DiffAXText`. `Callbacks.onAddComment` stays for the legacy table controller
  // until the Phase-13 seam swap deletes this viewer wholesale.

  /// Re-applies just the composited styling (after async highlights arrive)
  /// without rebuilding the row, then redraws.
  func updateHighlight(_ highlight: RowHighlight) {
    guard self.highlight != highlight else { return }
    self.highlight = highlight
    needsDisplay = true
  }

  override func mouseDown(with event: NSEvent) {
    if case .expander(let anchor, _, _) = row {
      callbacks?.onExpand(anchor)
      return
    }
    if case .commentThread(let comment) = row {
      callbacks?.onCommentTap(comment.id)
      return
    }
    super.mouseDown(with: event)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let row else { return }
    switch row {
    case .line(let line):
      drawUnifiedLine(line)
    case .splitLine(_, let old, let new):
      drawSplitLine(old: old, new: new)
    case .hunkHeader(_, let text):
      drawHunkHeader(text)
    case .expander(_, _, let hiddenCount):
      drawExpander(hiddenCount: hiddenCount)
    case .placeholder(let placeholder):
      drawPlaceholder(placeholder)
    case .plainFallback(let number, let text):
      drawPlainFallback(number: number, text: text)
    case .commentThread(let comment):
      drawCommentThread(comment)
    }
  }

  // MARK: - Comment thread (Phase 5)

  /// Fixed row height for an inline comment thread: a badge header line, the
  /// body's newline-split lines, and an optional orphaned caption.
  static func commentThreadHeight(_ comment: ReviewComment, metrics: DiffMetrics) -> CGFloat {
    let bodyLines = max(1, comment.body.split(separator: "\n", omittingEmptySubsequences: false).count)
    let lines = 1 + bodyLines + (comment.orphaned ? 1 : 0)
    return metrics.lineHeight * CGFloat(lines) + 8
  }

  private func drawCommentThread(_ comment: ReviewComment) {
    fill(bounds, with: NSColor.controlAccentColor.withAlphaComponent(0.06))
    NSColor.controlAccentColor.withAlphaComponent(0.55).setFill()
    NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()

    let sideMarker = comment.side == .old ? "-L" : "L"
    let range =
      comment.startLine == comment.endLine
      ? "\(comment.startLine)" : "\(comment.startLine)–\(comment.endLine)"
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping

    let attributed = NSMutableAttributedString(
      string: "\(sideMarker)\(range)\n",
      attributes: [
        .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
        .foregroundColor: NSColor.secondaryLabelColor,
        .paragraphStyle: paragraph,
      ]
    )
    if comment.orphaned {
      attributed.append(
        NSAttributedString(
          string: "original line no longer present\n",
          attributes: [.font: metrics.font, .foregroundColor: NSColor.systemOrange, .paragraphStyle: paragraph]
        )
      )
    }
    attributed.append(
      NSAttributedString(
        string: comment.body,
        attributes: [.font: metrics.font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
      )
    )
    let inset = NSRect(
      x: metrics.hPad + 6, y: 4, width: max(1, bounds.width - metrics.hPad - 12), height: bounds.height - 8)
    attributed.draw(in: inset)
  }

  // MARK: - Row kinds

  private func drawUnifiedLine(_ line: DiffLine) {
    fill(bounds, with: Self.background(for: line.origin))
    if line.origin == .noNewlineMarker {
      drawCode(line.content, startX: metrics.gutterWidth * 2 + metrics.hPad, color: .secondaryLabelColor)
      return
    }
    let oldRect = NSRect(x: 0, y: 0, width: metrics.gutterWidth, height: bounds.height)
    let newRect = NSRect(x: metrics.gutterWidth, y: 0, width: metrics.gutterWidth, height: bounds.height)
    drawGutterNumber(line.oldLineNumber, in: oldRect)
    drawGutterNumber(line.newLineNumber, in: newRect)
    drawStyledCode(line, startX: metrics.gutterWidth * 2 + metrics.hPad, maxX: nil)
  }

  private func drawSplitLine(old: DiffLine?, new: DiffLine?) {
    let half = (bounds.width / 2).rounded()
    drawPane(NSRect(x: 0, y: 0, width: half, height: bounds.height), line: old, isOld: true)
    drawPane(NSRect(x: half, y: 0, width: bounds.width - half, height: bounds.height), line: new, isOld: false)
    // Center divider.
    NSColor.separatorColor.setFill()
    NSRect(x: half, y: 0, width: 1, height: bounds.height).fill()
  }

  private func drawPane(_ rect: NSRect, line: DiffLine?, isOld: Bool) {
    guard let line else {
      // Empty split pane → the 45° diagonal hatch buffer (C5), replacing the prior
      // flat muted fill. `NSGraphicsContext.current` is set during `draw(_:)`.
      if let ctx = NSGraphicsContext.current?.cgContext {
        EmptySideHatch.draw(in: rect, into: ctx)
      }
      return
    }
    fill(rect, with: Self.background(for: line.origin))
    if line.origin == .noNewlineMarker {
      drawCode(
        line.content, startX: rect.minX + metrics.gutterWidth + metrics.hPad, color: .secondaryLabelColor,
        maxX: rect.maxX)
      return
    }
    let gutter = NSRect(x: rect.minX, y: 0, width: metrics.gutterWidth, height: bounds.height)
    drawGutterNumber(isOld ? line.oldLineNumber : line.newLineNumber, in: gutter)
    drawStyledCode(
      line,
      startX: rect.minX + metrics.gutterWidth + metrics.hPad,
      maxX: rect.maxX,
      isOldPane: isOld
    )
  }

  private func drawHunkHeader(_ text: String) {
    fill(bounds, with: NSColor.secondaryLabelColor.withAlphaComponent(0.10))
    drawCode(text, startX: metrics.hPad, color: .secondaryLabelColor)
  }

  private func drawExpander(hiddenCount: Int) {
    fill(bounds, with: NSColor.secondaryLabelColor.withAlphaComponent(0.06))
    let label = "⋯ Expand \(hiddenCount) hidden line\(hiddenCount == 1 ? "" : "s")"
    drawCode(label, startX: metrics.hPad, color: .linkColor)
  }

  private func drawPlaceholder(_ placeholder: FilePlaceholder) {
    let text = Self.placeholderText(placeholder)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: metrics.font,
      .foregroundColor: NSColor.secondaryLabelColor,
    ]
    let size = (text as NSString).size(withAttributes: attributes)
    let point = NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
    (text as NSString).draw(at: point, withAttributes: attributes)
  }

  private func drawPlainFallback(number: Int, text: String) {
    let gutter = NSRect(x: 0, y: 0, width: metrics.gutterWidth, height: bounds.height)
    drawGutterNumber(number, in: gutter)
    drawCode(text, startX: metrics.gutterWidth + metrics.hPad, color: .labelColor)
  }

  // MARK: - Drawing helpers

  private func fill(_ rect: NSRect, with color: NSColor?) {
    guard let color else { return }
    color.setFill()
    rect.fill()
  }

  private func drawGutterNumber(_ number: Int?, in rect: NSRect) {
    guard let number else { return }
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .right
    let attributes: [NSAttributedString.Key: Any] = [
      .font: metrics.font,
      .foregroundColor: NSColor.secondaryLabelColor,
      .paragraphStyle: paragraph,
    ]
    let inset = rect.insetBy(dx: 4, dy: metrics.vPad)
    (String(number) as NSString).draw(in: inset, withAttributes: attributes)
  }

  private func drawCode(_ text: String, startX: CGFloat, color: NSColor, maxX: CGFloat? = nil) {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: metrics.font,
      .foregroundColor: color,
    ]
    let width = (maxX ?? bounds.width) - startX - metrics.hPad
    guard width > 0 else { return }
    let rect = NSRect(x: startX, y: metrics.vPad, width: width, height: bounds.height - 2 * metrics.vPad)
    (text as NSString).draw(in: rect, withAttributes: attributes)
  }

  /// Draws one code line compositing the two independent styling passes: syntax
  /// foreground (new side only) and word-diff background. Deletions / old panes
  /// carry the pre-image text, so they get no syntax spans.
  private func drawStyledCode(_ line: DiffLine, startX: CGFloat, maxX: CGFloat?, isOldPane: Bool = false) {
    let isOldSide = isOldPane || (mode == .unified && line.origin == .deletion)
    let foreground = isOldSide ? [] : highlight.syntaxNew
    var background: [WordDiff.Span] = []
    var backgroundColor: NSColor?
    if line.origin == .addition || line.origin == .deletion {
      background = isOldSide ? highlight.wordOld : highlight.wordNew
      backgroundColor = Self.wordBackground(isOld: isOldSide)
    }
    // Fast path: nothing to composite ⇒ plain draw (avoids attributed-string cost).
    guard !foreground.isEmpty || (backgroundColor != nil && !background.isEmpty) else {
      drawCode(line.content, startX: startX, color: .labelColor, maxX: maxX)
      return
    }
    let width = (maxX ?? bounds.width) - startX - metrics.hPad
    guard width > 0 else { return }
    let attributed = NSMutableAttributedString(
      string: line.content,
      attributes: [.font: metrics.font, .foregroundColor: NSColor.labelColor]
    )
    let length = attributed.length
    for span in foreground {
      guard let range = Self.clampedRange(span.range, length: length) else { continue }
      attributed.addAttribute(.foregroundColor, value: HighlightTheme.color(for: span.capture), range: range)
    }
    if let backgroundColor {
      for span in background {
        guard let range = Self.clampedRange(span.range, length: length) else { continue }
        attributed.addAttribute(.backgroundColor, value: backgroundColor, range: range)
      }
    }
    let rect = NSRect(x: startX, y: metrics.vPad, width: width, height: bounds.height - 2 * metrics.vPad)
    attributed.draw(in: rect)
  }

  /// Clamps a UTF-16 span to the drawn string's length, dropping empty/invalid
  /// spans (guards against a span computed from a since-changed content hash).
  private static func clampedRange(_ span: Range<Int>, length: Int) -> NSRange? {
    let lower = max(0, span.lowerBound)
    let upper = min(length, span.upperBound)
    guard upper > lower else { return nil }
    return NSRange(location: lower, length: upper - lower)
  }

  /// Stronger-than-row word-diff background tint (system colors, light + dark).
  private static func wordBackground(isOld: Bool) -> NSColor {
    isOld ? NSColor.systemRed.withAlphaComponent(0.35) : NSColor.systemGreen.withAlphaComponent(0.35)
  }

  // MARK: - Static content

  /// Low-alpha system tints so the same fills read in light and dark.
  private static func background(for origin: DiffLineOrigin) -> NSColor? {
    switch origin {
    case .addition: return NSColor.systemGreen.withAlphaComponent(0.12)
    case .deletion: return NSColor.systemRed.withAlphaComponent(0.12)
    case .context, .noNewlineMarker: return nil
    }
  }

  static func placeholderText(_ placeholder: FilePlaceholder) -> String {
    switch placeholder {
    case .binaryFile: return "Binary file not shown"
    case .deletedFile: return "File deleted"
    case .addedEmpty: return "New empty file"
    case .noChanges: return "No changes"
    case .modeChangeOnly(let oldMode, let newMode):
      return oldMode.isEmpty || newMode.isEmpty ? "File mode changed" : "File mode changed \(oldMode) → \(newMode)"
    case .submodule(let oldSHA, let newSHA):
      return oldSHA.isEmpty || newSHA.isEmpty ? "Submodule changed" : "Submodule \(oldSHA) → \(newSHA)"
    }
  }
}
