import AppKit
import Foundation
import Testing

@testable import supacode

/// Parked-compositor guard (2026-07-11). Proves `StyleRunCompositor`'s narrowest-wins
/// precedence produces the SAME per-character foreground as production's array-order
/// last-wins (`LineTypesetter.attributed`) for the ACTUAL capture shapes our bundled
/// grammars emit — the evidence behind keeping the compositor PARKED, not wired. neon
/// emits only same-range ties + non-overlapping splits (never a strictly-nested
/// different-width overlap), which both strategies resolve identically. If a future
/// grammar introduces a divergent nesting, this fails and the compositor should be wired.
@MainActor
struct StyleRunCompositorEquivalenceTests {

  /// Array-order last-wins (mirrors `LineTypesetter.attributed`): the LAST run covering
  /// `index` wins; `nil` when no run covers it.
  private func productionColor(at index: Int, runs: [StyleRun]) -> NSColor? {
    var color: NSColor?
    for run in runs where run.range.contains(index) { color = HighlightTheme.color(for: run.capture) }
    return color
  }

  /// Compositor winner: the first composited (already non-overlapping) run covering it.
  private func compositorColor(at index: Int, composited: [StyleRun]) -> NSColor? {
    for run in composited where run.range.contains(index) {
      return run.capture.isEmpty ? nil : HighlightTheme.color(for: run.capture)
    }
    return nil
  }

  @Test func compositorMatchesArrayOrderForRealGrammarOutput() async {
    let engine = DiffHighlightEngine()
    let sources = [
      "let s = \"a\\nb\"\n",  // string split around an escape
      "let s = \"x\\(y)z\"\n",  // interpolation (punctuation.special ties)
      "// TODO return if\n",  // comment (+ dropped @spell)
      "/// A `let` doc comment\n",  // doc comment (comment / comment.documentation tie)
      "struct Foo { let bar = 42 }\n",  // variable / variable.member tie
    ]
    for (index, source) in sources.enumerated() {
      let input = HighlightBlobInput(blobOID: "equiv-\(index)", utf16: DiffFixture.blob(source), path: "a.swift")
      let byLine = await engine.styleRuns(for: input, visibleLines: 0..<2)
      for runs in byLine.values {
        let length = runs.map(\.range.upperBound).max() ?? 0
        let composited = StyleRunCompositor.composite(
          length: length, foreground: runs, wordDiff: [],
          defaultForeground: "", wordDiffBackground: .wordDiffAddition)
        for offset in 0..<length {
          // Compare only where production actually colors a token; gaps are the base
          // color in production vs `defaultForeground` in the compositor — orthogonal
          // to the precedence question under test.
          guard let prod = productionColor(at: offset, runs: runs) else { continue }
          #expect(
            compositorColor(at: offset, composited: composited) == prod,
            "precedence divergence at \(offset) in \(source.debugDescription)")
        }
      }
    }
  }
}
