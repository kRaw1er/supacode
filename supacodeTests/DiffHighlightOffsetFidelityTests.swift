import Foundation
import Testing

@testable import supacode

/// Scenario 10.3 / SEAM row BUG3 — the within-line syntax-offset fidelity guard.
///
/// The retired hand-rolled highlighter (`SyntaxHighlighter.swift:109-110`) applied a
/// SECOND `/2` to an already-UTF-16 `NamedRange`, halving every within-line span
/// offset — the exact "highlight lands on the wrong characters / colors drift"
/// symptom the user reported. `DiffHighlightEngine.bucket` consumes `named.range`
/// DIRECTLY (no second `/2`, see its doc comment); this test pins that fix on a real
/// tree-sitter parse where a keyword lives AFTER a surrogate pair, so a halved offset
/// (14 → 7) would land on the wrong glyphs and fail loudly.
///
/// Drives the REAL engine through `SyntaxRenderHarness.liveRuns` (real neon +
/// tree-sitter) so a regression anywhere on the blob → `NamedRange` → line-relative
/// `StyleRun` path is caught end-to-end, not just in a unit of `bucket`.
@MainActor
struct DiffHighlightOffsetFidelityTests {
  /// A one-line Swift file whose `func` keyword begins at UTF-16 offset 14 — AFTER a
  /// surrogate pair (the 👍 emoji at units 9..<11). If any stage re-halved the
  /// already-UTF-16 span, `func`'s run would land at ~7 (mid-string), not 14..<18.
  @Test func noDoubleUTF16HalveSpanLandsAtExactOffset() async throws {
    // l e t ␠ x ␠ = ␠ "  👍   "  ;  ␠  f  u  n  c  ␠  f  o  o  (  )  ␠  {  }
    // 0 1 2 3 4 5 6 7 8 9,10 11 12 13 14 15 16 17 …            (UTF-16 units)
    let source = "let x = \"\u{1F44D}\"; func foo() {}\n"
    let input = HighlightBlobInput(blobOID: "halve-1", utf16: DiffFixture.blob(source), path: "Fidelity.swift")
    // 1-based visible window for a one-line file: line 1 only.
    let runs = await SyntaxRenderHarness.liveRuns(input, lineNumbers: 1..<2)

    let lineRuns = runs[1] ?? []
    #expect(!lineRuns.isEmpty, "sanity: real Swift must produce runs for line 1")

    // `func` occupies the EXACT UTF-16 range 14..<18. A double-`/2` would report it
    // near 7 (halved), so an exact-range match is the discriminating assertion.
    let funcRange = 14..<18
    let funcRun = lineRuns.first { $0.range == funcRange }
    let observed = lineRuns.map(\.range)
    // `func` occupies EXACTLY 14..<18; a double-`/2` would report it near 7.
    #expect(funcRun != nil, "func run must be exactly 14..<18 (halved ≈ 7) — got \(observed)")

    // No run may land at the halved position (7..<9) that a double-`/2` of 14..<18
    // would produce — a direct negative guard on the specific regression.
    #expect(
      !lineRuns.contains { $0.range == 7..<9 },
      "a run at 7..<9 is the double-/2 halving of func's real 14..<18 range")

    // The leading `let` keyword still anchors at 0 (offsets are absolute, not shifted
    // by the surrogate pair that follows it later in the line).
    #expect(
      lineRuns.contains { $0.range.lowerBound == 0 },
      "the leading `let` keyword must start at offset 0")
  }
}
