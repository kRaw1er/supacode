import AppKit

/// Resolved rendering metrics for the diff viewer, derived from the system
/// monospaced font (no hardcoded sizes). `lineHeight` is the O(1) fixed height
/// returned from `heightOfRow`. Recomputed on font / appearance change.
struct DiffMetrics {
  let font: NSFont
  let lineHeight: CGFloat
  let charWidth: CGFloat
  let vPad: CGFloat
  let hPad: CGFloat
  /// Width of one line-number gutter column (old and new each get one).
  let gutterWidth: CGFloat

  static func resolve() -> DiffMetrics {
    let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    let vPad: CGFloat = 1
    let lineHeight = ceil(font.ascender - font.descender + font.leading) + 2 * vPad
    let charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
    return DiffMetrics(
      font: font,
      lineHeight: lineHeight,
      charWidth: max(1, charWidth),
      vPad: vPad,
      hPad: 6,
      gutterWidth: charWidth * 5 + 8
    )
  }

  /// Returns a copy whose gutter is wide enough for the largest line number in
  /// `rows` (keeps the code column aligned as numbers grow past 9,999).
  func withGutter(for rows: [DiffRow]) -> DiffMetrics {
    var maxNumber = 0
    for row in rows {
      switch row {
      case .line(let line):
        maxNumber = max(maxNumber, line.oldLineNumber ?? 0, line.newLineNumber ?? 0)
      case .splitLine(_, let old, let new):
        maxNumber = max(maxNumber, old?.oldLineNumber ?? 0, new?.newLineNumber ?? 0)
      case .plainFallback(let number, _):
        maxNumber = max(maxNumber, number)
      default:
        break
      }
    }
    let digits = max(3, String(maxNumber).count)
    let width = charWidth * CGFloat(digits) + 10
    return DiffMetrics(
      font: font,
      lineHeight: lineHeight,
      charWidth: charWidth,
      vPad: vPad,
      hPad: hPad,
      gutterWidth: width
    )
  }
}

/// A single recycled cell that renders any `DiffRow` kind by custom drawing —
/// no retained `NSTextField` per row. One reuse identifier feeds the whole
/// table, so recycling is a single pool. Split rows draw both panes inside the
/// one full-width cell for pixel-exact structural alignment.
final class DiffCellView: NSView {
  private var row: DiffRow?
  private var metrics = DiffMetrics.resolve()
  private var mode: DiffViewMode = .unified
  private var onExpand: ((Int) -> Void)?

  override var isFlipped: Bool { true }
  override var wantsDefaultClipping: Bool { true }

  func configure(row: DiffRow, metrics: DiffMetrics, mode: DiffViewMode, onExpand: @escaping (Int) -> Void) {
    self.row = row
    self.metrics = metrics
    self.mode = mode
    self.onExpand = onExpand
    needsDisplay = true
  }

  override func mouseDown(with event: NSEvent) {
    if case .expander(let anchor, _, _) = row {
      onExpand?(anchor)
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
    case .commentThread:
      break  // Phase 5 stub.
    }
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
    drawCode(line.content, startX: metrics.gutterWidth * 2 + metrics.hPad, color: .labelColor)
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
      fill(rect, with: NSColor.quaternaryLabelColor.withAlphaComponent(0.06))
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
    drawCode(
      line.content,
      startX: rect.minX + metrics.gutterWidth + metrics.hPad,
      color: .labelColor,
      maxX: rect.maxX
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
