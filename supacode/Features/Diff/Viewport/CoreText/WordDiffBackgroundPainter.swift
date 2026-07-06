import AppKit
import CoreText

/// One wrapped visual sub-line of a physical code line: its `CTLine`, the baseline
/// `origin` in flipped document coordinates (top-left origin — the point the glyphs
/// draw from), and the font `ascent` / `descent` magnitudes. Phase 3 wraps a line
/// into an array of these; both the word-diff background pass and the glyph pass
/// iterate the SAME array so a background rect lands exactly under its glyphs.
nonisolated struct WrappedSubLine {
  let line: CTLine
  /// Baseline origin (flipped doc coords): `x` = the content column's left edge,
  /// `y` = the glyph baseline.
  let origin: CGPoint
  /// `font.ascender` (positive) — glyphs rise this far above the baseline.
  let ascent: CGFloat
  /// `-font.descender` (positive magnitude) — glyphs drop this far below.
  let descent: CGFloat

  /// Build the per-sub-line baseline geometry for one wrapped physical line, matching
  /// `LineRowView.drawContent`'s baseline math so the word-diff rects and the glyphs
  /// share one coordinate source of truth. `origin` is the content column's top-left
  /// (`x` = left edge, `y` = the physical line's top in flipped doc coords). Snapped
  /// to the backing pixel grid.
  @MainActor
  static func lines(
    from wrapped: LineTypesetter.Wrapped,
    font: NSFont,
    origin: CGPoint,
    rowHeight: CGFloat,
    scale: CGFloat
  ) -> [WrappedSubLine] {
    let ascent = font.ascender
    let descent = -font.descender
    let textHeight = font.ascender - font.descender
    let inset = max(0, (rowHeight - textHeight) / 2)
    let snappedX = snap(origin.x, scale: scale)
    var out: [WrappedSubLine] = []
    out.reserveCapacity(wrapped.ctLines.count)
    for (index, line) in wrapped.ctLines.enumerated() {
      let lineTop = origin.y + CGFloat(index) * rowHeight
      let baseline = snap(lineTop + inset + ascent, scale: scale)
      out.append(
        WrappedSubLine(line: line, origin: CGPoint(x: snappedX, y: baseline), ascent: ascent, descent: descent))
    }
    return out
  }

  static func snap(_ value: CGFloat, scale: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
}

/// The strict bottom→top paint order for one rendered diff row (the authoritative
/// z-order `row-tint < word-diff < search/selection < syntax-fg` from the plan
/// index). Exposed as an ordered list so Phase 11's search / selection band slots in
/// between `.wordDiff` and `.glyphs` WITHOUT reordering the existing layers. Phase 5
/// ships three passes; Phase 11 inserts its own case.
nonisolated enum DiffRowLayer: Int, CaseIterable, Comparable, Sendable {
  /// Full-row add/del substrate tint (bottom) — `GutterRenderer`.
  case rowTint
  /// Intra-line word-diff emphasis rects, ON TOP of the row tint, BEHIND the glyphs
  /// — `WordDiffBackgroundPainter`.
  case wordDiff
  /// Glyphs via `CTLineDraw` (syntax foreground baked; background ignored by
  /// CoreText) — the terminal pass.
  case glyphs

  static func < (lhs: DiffRowLayer, rhs: DiffRowLayer) -> Bool { lhs.rawValue < rhs.rawValue }

  /// The bottom→top draw order every row follows.
  static var drawOrder: [DiffRowLayer] { allCases.sorted() }
}

/// Fills word-diff background rects behind the glyphs, BEFORE `CTLineDraw`, because
/// Core Text's `CTLineDraw` fills/strokes glyph runs only — it ignores
/// `NSAttributedString.Key.backgroundColor` (that key is honored by TextKit /
/// `NSLayoutManager`, not by Core Text glyph drawing).
///
/// **Bidi-safe:** it iterates the line's `CTRun`s and takes the PER-RUN x offsets —
/// a logically contiguous UTF-16 span can be visually discontiguous under RTL, so a
/// single start/end x for the whole span is WRONG. Ligatures are off (Phase 3
/// `.ligature = 0`) so offset↔x stays monotone within a run. Under wrapping it
/// iterates the visual sub-lines Phase 3 produced (`CTLineGetStringRange` bounds
/// each), intersects each run, and fills per sub-line.
///
/// Draws through `some DiffGraphics` (like `GutterRenderer`) so a headless test
/// records rects into a `RecordingContext` instead of sampling pixels; `CGContext`
/// conforms, so the live path is zero-cost. Caseless `enum` — no free functions.
@MainActor
enum WordDiffBackgroundPainter {
  /// Fill the word-diff `spans` behind `subLines`, in `color`, snapped to the
  /// backing pixel grid at `scale`. No spans ⇒ no fill (not even a `setFillColor`).
  static func fill(
    spans: [WordDiff.Span],
    subLines: [WrappedSubLine],
    color: CGColor,
    scale: CGFloat,
    in ctx: some DiffGraphics
  ) {
    guard !spans.isEmpty, !subLines.isEmpty else { return }
    ctx.setFillColor(color)
    for sub in subLines {
      let stringRange = CTLineGetStringRange(sub.line)  // this sub-line's UTF-16 bounds
      let subLo = stringRange.location
      let subHi = stringRange.location + stringRange.length
      let runs = CTLineGetGlyphRuns(sub.line) as? [CTRun] ?? []
      for span in spans {
        let spanLo = max(span.range.lowerBound, subLo)
        let spanHi = min(span.range.upperBound, subHi)
        guard spanLo < spanHi else { continue }
        for run in runs {
          let runRange = CTRunGetStringRange(run)
          let lower = max(spanLo, runRange.location)
          let upper = min(spanHi, runRange.location + runRange.length)
          guard lower < upper else { continue }
          let xStart = CTLineGetOffsetForStringIndex(sub.line, lower, nil)  // primary x from the line origin
          let xEnd = CTLineGetOffsetForStringIndex(sub.line, upper, nil)
          let left = sub.origin.x + min(xStart, xEnd)
          let width = abs(xEnd - xStart)
          let rect = CGRect(
            x: left,
            y: sub.origin.y - sub.ascent,
            width: width,
            height: sub.ascent + sub.descent
          )
          ctx.fill(snap(rect, scale: scale))
        }
      }
    }
  }

  /// Snap all four edges to the nearest backing pixel (the deterministic analog of
  /// `NSView.backingAlignedRect(_:options:.alignAllEdgesNearest)`, matching
  /// `GutterRenderer.backingAligned` so bars + rects share a grid).
  static func snap(_ rect: CGRect, scale: CGFloat) -> CGRect {
    let minX = WrappedSubLine.snap(rect.minX, scale: scale)
    let minY = WrappedSubLine.snap(rect.minY, scale: scale)
    return CGRect(
      x: minX,
      y: minY,
      width: WrappedSubLine.snap(rect.maxX, scale: scale) - minX,
      height: WrappedSubLine.snap(rect.maxY, scale: scale) - minY
    )
  }
}
