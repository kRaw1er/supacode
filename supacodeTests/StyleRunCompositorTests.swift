import Foundation
import Testing

@testable import supacode

/// Phase 5 — the syntax-foreground × word-diff-background compositor. Syntax fg
/// (`capture` token) and word-diff bg (`StyleColor`) are ORTHOGONAL attributes;
/// the only resolution is overlapping *foreground* (nested captures) flattened by
/// precedence (narrowest wins, later ties). Output is gap-free, non-overlapping,
/// coalesced over `0..<length`. Includes the I5 `[StyleRun]` golden.
struct StyleRunCompositorTests {

  private func fg(_ lower: Int, _ upper: Int, _ capture: String, _ traits: StyleRun.FontTraits = []) -> StyleRun {
    StyleRun(range: lower..<upper, capture: capture, traits: traits)
  }

  private func span(_ lower: Int, _ upper: Int) -> WordDiff.Span { WordDiff.Span(range: lower..<upper) }

  /// `range|capture|bg|traits` — the engine/theme-independent I5 serialization.
  private func serialize(_ runs: [StyleRun]) -> String {
    runs
      .map { run in
        let traits = [
          run.traits.contains(.bold) ? "bold" : nil,
          run.traits.contains(.italic) ? "italic" : nil,
        ]
        .compactMap { $0 }.joined(separator: ",")
        return
          "\(run.range.lowerBound)..<\(run.range.upperBound)|\(run.capture)|\(run.background?.rawValue ?? "")|\(traits)"
      }
      .joined(separator: "\n")
  }

  // MARK: - C 5.6 passthrough

  /// Foreground-only → the fg runs pass through unchanged (coalesced), no background.
  @Test func foregroundOnlyPassesThrough() {
    let out = StyleRunCompositor.composite(
      length: 6,
      foreground: [fg(0, 3, "keyword"), fg(3, 6, "string")],
      wordDiff: [],
      defaultForeground: "",
      wordDiffBackground: .wordDiffAddition
    )
    #expect(out == [fg(0, 3, "keyword"), fg(3, 6, "string")])
    #expect(out.allSatisfy { $0.background == nil })
  }

  /// Background-only → default foreground everywhere, word-diff background over the
  /// covered interval only.
  @Test func wordDiffOnlyDefaultForeground() {
    let out = StyleRunCompositor.composite(
      length: 6,
      foreground: [],
      wordDiff: [span(2, 5)],
      defaultForeground: "",
      wordDiffBackground: .wordDiffAddition
    )
    #expect(
      out == [
        StyleRun(range: 0..<2, capture: "", background: nil),
        StyleRun(range: 2..<5, capture: "", background: .wordDiffAddition),
        StyleRun(range: 5..<6, capture: "", background: nil),
      ]
    )
  }

  // MARK: - C 5.7 overlapping foreground precedence

  /// Outer A `[0,10)` + inner B `[3,6)` → runs `A, B, A` (narrowest wins).
  @Test func overlappingForegroundNarrowestWins() {
    let out = StyleRunCompositor.composite(
      length: 10,
      foreground: [fg(0, 10, "outer"), fg(3, 6, "inner")],
      wordDiff: [],
      defaultForeground: "",
      wordDiffBackground: .wordDiffAddition
    )
    #expect(out.map(\.capture) == ["outer", "inner", "outer"])
    #expect(out.map(\.range) == [0..<3, 3..<6, 6..<10])
  }

  /// Two identical-range foreground runs → the later (innermost / higher-index)
  /// capture wins the tie.
  @Test func overlappingForegroundTieLaterWins() {
    let out = StyleRunCompositor.composite(
      length: 5,
      foreground: [fg(0, 5, "first"), fg(0, 5, "second")],
      wordDiff: [],
      defaultForeground: "",
      wordDiffBackground: .wordDiffAddition
    )
    #expect(out == [fg(0, 5, "second")])
  }

  // MARK: - C 5.8 orthogonality + gap-free coverage

  /// Foreground survives under an overlapping word-diff background; the output is
  /// gap-free, non-overlapping, and its union is exactly `0..<length`.
  @Test func wordDiffOverlaysForegroundNonOverlapping() {
    let length = 8
    let out = StyleRunCompositor.composite(
      length: length,
      foreground: [fg(0, 4, "keyword")],
      wordDiff: [span(2, 6)],
      defaultForeground: "",
      wordDiffBackground: .wordDiffAddition
    )
    // The keyword survives even where the word-diff overlaps it ([2,4) is keyword+bg).
    #expect(
      out == [
        StyleRun(range: 0..<2, capture: "keyword", background: nil),
        StyleRun(range: 2..<4, capture: "keyword", background: .wordDiffAddition),
        StyleRun(range: 4..<6, capture: "", background: .wordDiffAddition),
        StyleRun(range: 6..<8, capture: "", background: nil),
      ]
    )
  }

  @Test func boundaryCoverageIsGapFree() {
    let length = 12
    let out = StyleRunCompositor.composite(
      length: length,
      foreground: [fg(1, 4, "a"), fg(3, 9, "b")],
      wordDiff: [span(0, 2), span(7, 11)],
      defaultForeground: "",
      wordDiffBackground: .wordDiffDeletion
    )
    // Non-overlapping + strictly ascending + union == 0..<length.
    #expect(out.first?.range.lowerBound == 0)
    #expect(out.last?.range.upperBound == length)
    for index in 1..<out.count {
      #expect(out[index - 1].range.upperBound == out[index].range.lowerBound)
      #expect(out[index].range.lowerBound < out[index].range.upperBound)
    }
  }

  // MARK: - C 5.9 coalesce

  /// Adjacent runs with identical `(capture, background, traits)` merge into one.
  @Test func adjacentEqualStyleCoalesced() {
    let out = StyleRunCompositor.composite(
      length: 6,
      foreground: [fg(0, 3, "keyword"), fg(3, 6, "keyword")],
      wordDiff: [],
      defaultForeground: "",
      wordDiffBackground: .wordDiffAddition
    )
    #expect(out == [fg(0, 6, "keyword")])
  }

  // MARK: - I5 golden

  /// C 5.10 / I5 — a fixture line's composited `[StyleRun]` serialized
  /// `range|capture|bg|traits` matches the checked-in golden (engine/theme-
  /// independent; `UPDATE_GOLDEN=1` regenerates; never pixels).
  @Test func styleRunGoldenComposite() {
    // "let x = 1": keyword `let`, variable `x`, number `1`; the `1` is the word-diff.
    let out = StyleRunCompositor.composite(
      length: 9,
      foreground: [fg(0, 3, "keyword"), fg(4, 5, "variable"), fg(8, 9, "number")],
      wordDiff: [span(8, 9)],
      defaultForeground: "",
      wordDiffBackground: .wordDiffAddition
    )
    GoldenText.assert(serialize(out), "styleRunComposite")
  }
}
