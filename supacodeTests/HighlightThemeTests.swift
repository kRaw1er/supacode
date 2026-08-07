import AppKit
import Testing

@testable import supacode

/// Phase 4 — the capture → system-color resolver, re-audited for the 0.25 grammar
/// capture set. Longest-prefix `a.b.c → a.b → a → default`, matching how tree-sitter
/// nests `nameComponents` (joined with ".").
@MainActor
struct HighlightThemeTests {

  /// 4.6 — the new captures resolve precisely instead of falling to `labelColor`.
  @Test func captureToColorResolution() {
    #expect(HighlightTheme.color(for: "variable.parameter") == .systemTeal)
    #expect(HighlightTheme.color(for: "punctuation.bracket") == .secondaryLabelColor)
    #expect(HighlightTheme.color(for: "punctuation.delimiter") == .secondaryLabelColor)
    #expect(HighlightTheme.color(for: "embedded") == .labelColor)
    #expect(HighlightTheme.color(for: "none") == .labelColor)
    #expect(HighlightTheme.color(for: "markup") == .labelColor)
  }

  /// Longest-prefix resolution: an unmapped `a.b.c` walks down to the mapped `a`.
  @Test func longestPrefixWalksDown() {
    // `keyword` is mapped; `keyword.control.conditional` has no exact entry → keyword.
    #expect(HighlightTheme.color(for: "keyword.control.conditional") == .systemPink)
    // `variable.parameter.builtin` → `variable.parameter` (mapped teal) before `variable`.
    #expect(HighlightTheme.color(for: "variable.parameter.builtin") == .systemTeal)
    // `variable.other` → `variable` (labelColor), not the parameter teal.
    #expect(HighlightTheme.color(for: "variable.other") == .labelColor)
    // A completely unknown capture → default labelColor.
    #expect(HighlightTheme.color(for: "totally.unknown.capture") == .labelColor)
  }
}
