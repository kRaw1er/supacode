import Foundation

/// One resolved styling run within a single rendered line, in **line-relative UTF-16
/// code units** so it composites directly onto the line's CTLine (Phase 3) with no
/// offset conversion. Foreground only in Phase 4; Phase 5 adds `background` for
/// word-diff — an orthogonal attribute (foreground rides CoreText glyph drawing;
/// background is a hand-filled rect drawn behind the glyphs, since `CTLineDraw`
/// ignores background color).
///
/// `capture` (not a resolved color) is stored so the color re-resolves through
/// `HighlightTheme` at draw time — system colors are dynamic per appearance, so this
/// keeps the span cache appearance-independent (only `syntaxThemeGen`, not
/// `styleGeneration`, invalidates it). `background` is likewise a `StyleColor`
/// **token** (not a resolved `NSColor`) so `StyleRun` stays `Equatable`/`Sendable`/
/// `Hashable`; the draw layer resolves it through `DiffPalette`.
///
/// `nonisolated` because the app target is `@MainActor`-by-default: the value is
/// stored in TCA state and captured into `@Sendable` effect closures, so it must be
/// constructible off the main actor.
nonisolated struct StyleRun: Sendable, Equatable, Hashable {
  /// Line-relative UTF-16 code-unit range within the rendered line.
  let range: Range<Int>
  /// e.g. `"keyword.control"`; resolved via `HighlightTheme.color(for:)` at draw time.
  let capture: String
  /// Phase 5 addition — word-diff emphasis ONLY (a `DiffPalette` token; `nil` = no
  /// background). Never carries syntax: syntax is `capture` (foreground). Resolved
  /// through `DiffPalette` at draw and hand-filled behind the glyphs.
  let background: StyleColor?
  /// Bold / italic (empty in Phase 4; grammars rarely emit these captures).
  let traits: FontTraits

  init(range: Range<Int>, capture: String, background: StyleColor? = nil, traits: FontTraits = []) {
    self.range = range
    self.capture = capture
    self.background = background
    self.traits = traits
  }

  struct FontTraits: OptionSet, Sendable, Equatable, Hashable {
    let rawValue: Int
    static let bold = FontTraits(rawValue: 1 << 0)
    static let italic = FontTraits(rawValue: 1 << 1)
  }
}

/// A resolved-at-draw-time color token for a `StyleRun.background`. Kept a token
/// (not a raw `NSColor`) so `StyleRun` stays `Equatable`/`Sendable`/`Hashable` and
/// the composited span cache is appearance-independent. Phase 5 uses it ONLY for
/// intra-line word-diff emphasis; the draw layer maps each case to a dynamic
/// `DiffPalette.wordEmphasis(isOld:)` color that tracks light/dark. The raw `String`
/// value gives the I5 golden a stable, engine-independent serialization.
nonisolated enum StyleColor: String, Sendable, Equatable, Hashable {
  /// Deletion-side intra-line word-diff emphasis — `DiffPalette.wordEmphasis(isOld: true)`.
  case wordDiffDeletion
  /// Addition-side intra-line word-diff emphasis — `DiffPalette.wordEmphasis(isOld: false)`.
  case wordDiffAddition
}
