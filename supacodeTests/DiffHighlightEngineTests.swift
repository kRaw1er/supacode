import Foundation
import Testing

@testable import supacode

/// Phase 4 — CT-HEADLESS coverage that drives a REAL `TreeSitterClient` through OUR
/// engine (blob → windowed `NamedRange` → line-relative `StyleRun`), the neon
/// delivery path the app actually uses. `@MainActor` because `TreeSitterClient` and
/// the engine are.
@MainActor
struct DiffHighlightEngineTests {

  /// 4.11 — carries the Phase-0 smoke forward THROUGH the engine: real Swift source →
  /// non-empty `StyleRun`s including a `keyword`-prefixed capture (proves the query
  /// classified `struct` / `let`, not just tokenised whitespace).
  @Test func neonSmokeSwiftHighlightsNonEmpty() async {
    let engine = DiffHighlightEngine()
    let source = "struct Foo { let bar = 42 }\n"
    let input = HighlightBlobInput(blobOID: "swift-smoke", utf16: DiffFixture.blob(source), path: "Foo.swift")

    let byLine = await engine.styleRuns(for: input, visibleLines: 0..<2)
    let runs = byLine.values.flatMap { $0 }

    #expect(!runs.isEmpty)
    #expect(runs.contains { $0.capture.hasPrefix("keyword") })
  }

  /// A file with no bundled grammar renders plain (empty), never crashes.
  @Test func plainFileYieldsNoRuns() async {
    let engine = DiffHighlightEngine()
    let input = HighlightBlobInput(
      blobOID: "plain", utf16: DiffFixture.blob("just some text\n"), path: "notes.unknownext")
    let byLine = await engine.styleRuns(for: input, visibleLines: 0..<1)
    #expect(byLine.isEmpty)
  }

  /// 4.10 — JS-in-HTML injection. The `LanguageProvider` resolves the embedded
  /// language; a MISSING injected grammar returns `nil` (logged) and the region
  /// renders plain, never crashing.
  @Test func injectionResolvesEmbeddedGrammar() async {
    let engine = DiffHighlightEngine()

    // The LanguageProvider contract, directly.
    #expect(engine.injectedConfiguration(named: "javascript") != nil)
    #expect(engine.injectedConfiguration(named: "css") != nil)
    #expect(engine.injectedConfiguration(named: "no-such-lang-xyz") == nil)  // missing ⇒ plain, no crash

    // End-to-end: HTML with an embedded <script>. The html highlights.scm has NO
    // `keyword` capture, so a `keyword` run can ONLY come from the injected JS layer.
    let source = "<script>let answer = 42;</script>"
    let input = HighlightBlobInput(blobOID: "html-inj", utf16: DiffFixture.blob(source), path: "page.html")
    // neon resolves injected sublayers on its BACKGROUND processor (async), so the
    // FIRST query can return before the JS sublayer is ready — the viewer simply
    // re-queries on the next scroll/relayout. Re-query (bounded) until it settles.
    var runs: [StyleRun] = []
    for _ in 0..<20 {
      runs = (await engine.styleRuns(for: input, visibleLines: 0..<1)).values.flatMap { $0 }
      if runs.contains(where: { $0.capture.hasPrefix("keyword") }) { break }
    }

    #expect(!runs.isEmpty)
    #expect(runs.contains { $0.capture.hasPrefix("keyword") }, "expected injected JS `let` keyword in <script>")
  }

  /// A missing injected grammar is handled — the `LanguageProvider` returns `nil` so
  /// the embedded region renders plain (never crashes). The engine also logs the miss
  /// loudly (bug #3: no silent drop) via `SupaLogger.info`; there is no log-capture
  /// harness, so this asserts the observable contract (the `nil` return) directly.
  @Test func missingInjectedGrammarReturnsNilForPlainFallback() {
    let engine = DiffHighlightEngine()
    #expect(engine.injectedConfiguration(named: "definitely-not-a-language") == nil)
    #expect(engine.injectedConfiguration(named: "") == nil)
  }

  /// B §10 — the shared engine is one lazily-built instance across files; `dispose`
  /// tears it down and the next request rebuilds a NEW instance.
  @Test func sharedHighlighterSingletonLifecycle() {
    let first = DiffHighlightEngine.shared
    let second = DiffHighlightEngine.shared
    #expect(first === second)  // same instance across files

    DiffHighlightEngine.disposeShared()
    let rebuilt = DiffHighlightEngine.shared
    #expect(first !== rebuilt)  // dispose ⇒ next request rebuilds a new instance
  }

  /// C9 sync fast path — once the parse tree is warm the sync overload answers
  /// immediately (non-`nil`) with the same non-empty, keyword-bearing runs the async
  /// pass produces. This is the paint-now capability the reducer relies on to color a
  /// reopened / scrolled-back file without the async round-trip. (Whether a *cold*
  /// blob returns `nil` vs runs is neon-internal — small blobs can parse synchronously
  /// — so this pins only the guaranteed post-warm contract; `nil` just routes to async.)
  @Test func syncFastPathPaintsWarmParseImmediately() async {
    let engine = DiffHighlightEngine()
    let input = HighlightBlobInput(
      blobOID: "sync-warm", utf16: DiffFixture.blob("struct Foo { let bar = 42 }\n"), path: "Foo.swift")

    // Warm the parse tree through the async path (awaits processing to completion).
    _ = await engine.styleRuns(for: input, visibleLines: 0..<2)

    let sync = engine.syncStyleRuns(for: input, visibleLines: 0..<2)
    #expect(sync != nil)  // warm ⇒ never pending
    let runs = (sync ?? [:]).values.flatMap { $0 }
    #expect(!runs.isEmpty)
    #expect(runs.contains { $0.capture.hasPrefix("keyword") })
  }

  /// A `@spell` modifier capture shares the comment's range but carries no color; it
  /// must be dropped in bucketing so it can't override the comment's foreground (which,
  /// in array order, painted comments in the default text color instead of the muted
  /// comment color). Every surviving run over the comment resolves to the comment color.
  @Test func nonColorSpellCaptureIsDroppedSoCommentKeepsColor() async {
    let engine = DiffHighlightEngine()
    let input = HighlightBlobInput(
      blobOID: "spell-comment", utf16: DiffFixture.blob("// TODO return if\n"), path: "a.swift")
    let runs = (await engine.styleRuns(for: input, visibleLines: 0..<2))[0] ?? []

    #expect(!runs.isEmpty)
    #expect(!runs.contains { $0.capture == "spell" || $0.capture.hasPrefix("spell.") })
    #expect(runs.contains { $0.capture.hasPrefix("comment") })
    // No surviving run resolves to a DIFFERENT foreground than `comment` over the line.
    let commentColor = HighlightTheme.color(for: "comment")
    #expect(runs.allSatisfy { HighlightTheme.color(for: $0.capture) == commentColor })
  }

  /// The color-bearing filter is a pure classifier: color captures pass, modifier
  /// captures (root-matched, so namespaced variants too) are rejected.
  @Test func isColorBearingRejectsModifierCaptures() {
    #expect(DiffHighlightEngine.isColorBearing("comment"))
    #expect(DiffHighlightEngine.isColorBearing("keyword.control"))
    #expect(DiffHighlightEngine.isColorBearing("string.escape"))
    #expect(!DiffHighlightEngine.isColorBearing("spell"))
    #expect(!DiffHighlightEngine.isColorBearing("spell.rare"))
    #expect(!DiffHighlightEngine.isColorBearing("conceal"))
  }

  /// C9 sync fast path — a no-grammar file is a legitimate plain render (`[:]`), NOT
  /// pending (`nil`): the reducer must treat it as "nothing to paint", not "retry async".
  @Test func syncFastPathPlainFileIsEmptyNotPending() {
    let engine = DiffHighlightEngine()
    let input = HighlightBlobInput(
      blobOID: "sync-plain", utf16: DiffFixture.blob("just some text\n"), path: "notes.unknownext")
    #expect(engine.syncStyleRuns(for: input, visibleLines: 0..<1) == [:])
  }

  /// The parse tree is cached by blob identity: a second query over the same blob
  /// reuses it (returns the same runs; no re-parse cost asserted directly, but the
  /// engine must not throw / return empty on the reuse path).
  @Test func repeatQueryReusesParse() async {
    let engine = DiffHighlightEngine()
    let input = HighlightBlobInput(
      blobOID: "reuse-1", utf16: DiffFixture.blob("let x = 1\nlet y = 2\n"), path: "a.swift")
    let first = await engine.styleRuns(for: input, visibleLines: 0..<2)
    let second = await engine.styleRuns(for: input, visibleLines: 0..<2)
    #expect(first == second)
    #expect(!first.isEmpty)
  }
}
