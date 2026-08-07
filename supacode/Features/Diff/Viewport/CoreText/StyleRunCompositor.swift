import Foundation

/// Flattens (possibly overlapping) foreground syntax runs + word-diff background
/// spans into ONE gap-free, non-overlapping `[StyleRun]` over `0..<length`. This is
/// "the real work" of Phase 5: syntax (Phase 4 `capture` foreground) and word-diff
/// (Phase 5 `background`) are ORTHOGONAL attributes, so the only conflict to resolve
/// is *overlapping foreground* (nested tree-sitter captures), flattened by
/// precedence — narrowest range wins, ties broken by the later (innermost) capture.
///
/// The foreground stays a `capture` **token** (resolved via `HighlightTheme` at
/// draw), never a baked `NSColor`, so word-diff arrival cannot force a color and the
/// composited model stays appearance-independent. Only the composited **foreground**
/// is baked into the attributed string / CTLine; the `background` drives the
/// hand-filled word-diff rects (`WordDiffBackgroundPainter`), never CoreText.
///
/// O(intervals × fgRuns) per line, both bounded by tokens-per-visible-line. Caseless
/// `enum` — no free functions (CLAUDE.md).
///
/// PARKED (2026-07-11, not wired into the render path): an investigation over real
/// neon output for our bundled grammars found that this compositor's narrowest-wins
/// precedence produces output IDENTICAL to production's array-order last-wins
/// (`LineTypesetter.attributed`). neon does not emit strictly-nested different-width
/// overlaps — it splits captures around inner ones (e.g. `string` around
/// `string.escape`) and otherwise emits same-range ties, which BOTH strategies resolve
/// to the later capture. Wiring it would unify syntax fg + word-diff bg into one model
/// but change no visible output while adding cache-key / word-diff / perf risk. Retained
/// (NOT deleted) with `StyleRunCompositorEquivalenceTests` guarding the equivalence — if
/// a future grammar introduces a divergent nesting, that guard fails and this gets wired.
enum StyleRunCompositor {
  /// Merge `foreground` (syntax fg; `background == nil`, may overlap) with `wordDiff`
  /// spans (→ background) into one non-overlapping, coalesced `[StyleRun]` covering
  /// `0..<length`.
  ///
  /// - Parameters:
  ///   - length: the rendered line's UTF-16 length; the output covers `0..<length`.
  ///   - foreground: syntax runs (capture token, `background == nil`). May overlap.
  ///   - wordDiff: intra-line changed spans → each becomes a `background`.
  ///   - defaultForeground: the capture token for any interval no syntax run covers
  ///     (e.g. `""`, which `HighlightTheme` resolves to the default label color).
  ///   - wordDiffBackground: the `StyleColor` token painted behind covered intervals.
  static func composite(
    length: Int,
    foreground: [StyleRun],
    wordDiff: [WordDiff.Span],
    defaultForeground: String,
    wordDiffBackground: StyleColor
  ) -> [StyleRun] {
    guard length > 0 else { return [] }

    // Every foreground + word-diff boundary becomes a cut; sweep the sorted cuts.
    var cuts: Set<Int> = [0, length]
    for run in foreground {
      cuts.insert(clamp(run.range.lowerBound, length: length))
      cuts.insert(clamp(run.range.upperBound, length: length))
    }
    for span in wordDiff {
      cuts.insert(clamp(span.range.lowerBound, length: length))
      cuts.insert(clamp(span.range.upperBound, length: length))
    }
    let bounds = cuts.sorted()

    var out: [StyleRun] = []
    for index in 0..<(bounds.count - 1) {
      let lower = bounds[index]
      let upper = bounds[index + 1]
      guard upper > lower else { continue }
      // The covering foreground run with the narrowest range; on a tie the later
      // (innermost / higher-index) capture wins.
      let winner =
        foreground
        .enumerated()
        .filter { $0.element.range.lowerBound <= lower && upper <= $0.element.range.upperBound }
        .min { ($0.element.range.count, -$0.offset) < ($1.element.range.count, -$1.offset) }?
        .element
      let covered = wordDiff.contains { $0.range.lowerBound <= lower && upper <= $0.range.upperBound }
      out.append(
        StyleRun(
          range: lower..<upper,
          capture: winner?.capture ?? defaultForeground,
          background: covered ? wordDiffBackground : nil,
          traits: winner?.traits ?? []
        )
      )
    }
    return coalesce(out)
  }

  /// Merge adjacent runs that share identical `(capture, background, traits)` so the
  /// output is minimal (a syntax run split only by a word-diff boundary re-joins
  /// where the background matches).
  private static func coalesce(_ runs: [StyleRun]) -> [StyleRun] {
    var out: [StyleRun] = []
    for run in runs {
      if let last = out.last,
        last.range.upperBound == run.range.lowerBound,
        last.capture == run.capture,
        last.background == run.background,
        last.traits == run.traits
      {
        out[out.count - 1] = StyleRun(
          range: last.range.lowerBound..<run.range.upperBound,
          capture: last.capture,
          background: last.background,
          traits: last.traits
        )
      } else {
        out.append(run)
      }
    }
    return out
  }

  private static func clamp(_ value: Int, length: Int) -> Int { min(max(value, 0), length) }
}
