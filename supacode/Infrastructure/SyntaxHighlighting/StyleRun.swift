import Foundation

/// One resolved styling run within a single rendered line, in **line-relative UTF-16
/// code units** so it composites directly onto the line's CTLine (Phase 3) with no
/// offset conversion. Foreground only in Phase 4; Phase 5 adds `bg` for word-diff.
///
/// `capture` (not a resolved color) is stored so the color re-resolves through
/// `HighlightTheme` at draw time — system colors are dynamic per appearance, so this
/// keeps the span cache appearance-independent (only `syntaxThemeGen`, not
/// `styleGeneration`, invalidates it).
///
/// `nonisolated` because the app target is `@MainActor`-by-default: the value is
/// stored in TCA state and captured into `@Sendable` effect closures, so it must be
/// constructible off the main actor.
nonisolated struct StyleRun: Sendable, Equatable, Hashable {
  /// Line-relative UTF-16 code-unit range within the rendered line.
  let range: Range<Int>
  /// e.g. `"keyword.control"`; resolved via `HighlightTheme.color(for:)` at draw time.
  let capture: String
  /// Bold / italic (empty in Phase 4; grammars rarely emit these captures).
  let traits: FontTraits

  init(range: Range<Int>, capture: String, traits: FontTraits = []) {
    self.range = range
    self.capture = capture
    self.traits = traits
  }

  struct FontTraits: OptionSet, Sendable, Equatable, Hashable {
    let rawValue: Int
    static let bold = FontTraits(rawValue: 1 << 0)
    static let italic = FontTraits(rawValue: 1 << 1)
  }
}
