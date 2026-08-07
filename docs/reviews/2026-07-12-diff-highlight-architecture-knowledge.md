# Diff syntax-highlight — architecture knowledge for a future redesign

> Written 2026-07-12 after root-causing three highlight bugs (flaky repaint, all-red corruption,
> scroll slowdown). This is **KNOWLEDGE, not a prescription** — empirical facts about how the
> current pieces behave, so a future agent can design a better system with eyes open. The current
> pull-model + per-window-warm design is serviceable but strained; the unified single-scroll file
> feed and any multithreading will force a rethink. Trust the measurements here over intuition.

## The layers, as they actually are

```
reducer (.visibleRangeChanged, blob-slice windowing only — NO highlight state anymore)
  │  blobs (old/new UTF-16 + blobOID + path) flow to the controller, keyed per FileID
  ▼
DiffViewportController.warmVisibleHighlights()   ← launched per layout/scroll settle
  │  computes the visible+overscan line window, resolves per-side MISSING blob-line gaps
  │  launches a Task that calls engine.styleRuns(window) per gap, then repaintForSyntaxFill()
  ▼
DiffHighlightEngine.styleRuns(blob, visibleLines) async   ← parses + buckets + MERGES into cache
  │  wraps neon TreeSitterClient (one client per (blobOID, queryName))
  ▼
HighlightSpanCache   ← [blobLine → [StyleRun]] + a COVERED IndexSet, keyed (blobOID, queryName, themeGen)
  ▲
LineRowView.syntaxRuns()   ← PULL: each drawn row reads its runs O(1) from the cache (number-1 → blobLine)
```

Key architectural facts:
- **Pull model.** Highlighting is a render concern, not app state. The view pulls each row's runs
  from the span cache at typeset time. The warm only *fills* the cache; a repaint re-typesets so
  the view re-pulls. There is no highlight state in the reducer anymore (deleted in the pull-model
  refactor, commits `e23e3a6e`..`a30d6e7a`).
- **The span cache is the single source of truth** the view reads. Everything upstream exists to
  fill it. It is correctly keyed by content identity (blobOID) + grammar + theme — safe to SHARE
  across tabs/files; do NOT split it per file. The per-file bug that once existed was in the
  *controller's* per-file state, never the caches.
- **Two spaces, one ±1 conversion.** The engine/cache speak **0-based blob lines**; the view speaks
  **1-based source line numbers**. The single translation is `number - 1` in `LineRowView.syntaxRuns`
  and `DiffHighlightEngine.blobWindow(forLineNumbers:)`. Keep it confined; every past miscolor-by-shift
  was a leak of this boundary.

## neon / TreeSitterClient — the load-bearing external behaviors

The whole design lives or dies on how `TreeSitterClient.highlights` behaves. There are **two overloads**
(`Tuist/.build/checkouts/Neon/Sources/TreeSitterClient/TreeSitterClient.swift:380,385`):

1. **`highlights(in: NSRange) throws -> [NamedRange]?`  — SYNCHRONOUS.** Reads the ALREADY-PARSED tree
   (`layerTree.executeQuery`) and returns immediately. No `await`, no background hop. Returns **`nil`**
   when `canAttemptSynchronousAccess == (hasPendingChanges == false)` is false — i.e. while the tree
   still has unprocessed content. **~0.04–2 ms/call.**
2. **`highlights(in: NSRange) async throws -> [NamedRange]`  — ASYNCHRONOUS.** Runs
   `rangeProcessor.processLocation(maxLocation)` + `await processingCompleted()` + async
   `layerTree.executeQuery`. It DRIVES the parse up to the query's max offset and awaits the background
   processor. **~34–64 ms/call warm on a big file** — measured, an order of magnitude worse than sync.

Measured on the real `test25k.swift` (25k lines Swift, 174-line windows):

| scenario | cost |
|---|---|
| async overload, warm re-query | ~64 ms/call |
| sync overload, warm | ~2 ms (40-line) / ~11 ms (174-line, dominated by bucketing) |
| cold 14-way concurrent async fan-out (pre-fix) | ~7200 ms |
| cold, single-flight full parse then sync | ~1300 ms one-time |

Critical non-obvious facts (each cost hours to establish):

- **`hasPendingChanges` is GLOBAL, not per-range.** Until the WHOLE seeded blob is processed, the sync
  overload returns `nil` for EVERY range — even ranges already parsed. Consequence: a *partial* async
  parse (a windowed query) does NOT make sync usable; the tree must be driven to `blob.length` first.
  A cheap way to settle without materializing an O(file) `NamedRange` array: query a **1-unit range at
  the very end** — `processLocation` runs to the end, `hasPendingChanges` clears, sync works everywhere.
- **`processLocation(loc)` processes from byte 0 up to `loc`.** The async overload re-drives this every
  call. A deep window (line 20000) therefore re-parses ~the whole file *per call*. This — not the query
  itself — is why the async path is slow and why N concurrent cold windows cost N× a full parse.
- **The off-main parse cannot be cancelled.** `Task.cancel()` on a warm task does NOT stop an in-flight
  `client.highlights`; the parse runs to completion and MERGES into the cache anyway. Cancellation only
  stops the task from *launching further* work. Any design that relies on cancel to coalesce is wrong.
- **Concurrent async `highlights` on the SAME client CORRUPTS the parse.** `TreeSitterClient` is
  non-Sendable; its parse runs off-main during the `await`. Two concurrent calls on one client race on
  neon's shared parse state and return GARBAGE — reproduced deterministically as an entire region coming
  back as a single spurious `string` capture per line (`string` == `systemRed` → "everything red"). This
  is rare in the wild because it needs the exact interleaving, but a fast-scroll fan-out reliably hits
  it. Regression guard: `DiffHighlightConcurrentParseTests` (fails without serialization, needs a LARGE
  source WITH multi-line `"""` strings — a small or string-free fixture hides the race).
- **Injected sublayer resolution is ITERATIVE and wall-clock-paced.** For embedded languages (JS in
  HTML `<script>`, code in a markdown fence, regex in Swift), neon resolves one layer per async query,
  advancing only when the async path `await`s the background processor across real runloop turns. It
  needs *several* async queries *over time*. A tight async loop does NOT drive it (measured: 8 back-to-back
  passes, 0.03 s, no resolution). The SYNC overload never drives it at all (no await). So sync-first
  fundamentally cannot resolve injections — an accepted limitation today (`injectionResolvesEmbeddedGrammar`
  is `withKnownIssue`). NOTE: in-app, `markCovered` already suppresses re-querying a region, so injected
  highlights were effectively best-effort/not-arriving even before sync-first — the loss is smaller than
  it looks. A real fix needs a background "fully resolve this blob" pass decoupled from the query path.

## Where the current design is strained (the "херабора" smell)

- **The warm fans out.** `warmVisibleHighlights` launches a Task per `boundsDidChange`; a fast scroll
  spawns ~15 tasks. `markCovered` (claimed up front) makes each grab a DISJOINT gap, so they don't
  dedupe — 15 tasks each re-parse 0→depth. Cancellation doesn't help (see above). This is the root of
  both the corruption (concurrency) and the slowdown (serialized redundant parses). The current mitigation
  is a per-client serial gate + a sync fast path, but the fan-out itself is the wrong shape.
- **`markCovered` couples two concerns.** It both (a) stops the token-less-line re-query runaway and
  (b) records "we looked here." (a) is essential (without it the warm→repaint→layout→warm loop pegs the
  CPU). But (b) also suppresses the re-queries that injected-sublayer resolution needs. These should be
  separable.
- **Repaint delivery is manual and fragile.** The warm completion bumps `syntaxVersion`, re-runs
  `layoutVisibleChunks` (re-typeset), then flushes each `LineRowView` via `displayIfNeeded` inside an
  explicit `CATransaction` (a Task continuation has no implicit commit boundary, so the layer-backed draw
  otherwise waits for the next event — the "colors only after a nudge" flake). And the repaint must fire
  on EVERY task that merged, even a superseded one, or runs strand in the cache. This works but is a lot
  of coupling between the async warm and AppKit's display cycle. `documentView.displayIfNeeded()` HANGS
  (re-entrant layout) — only per-row flush is safe.
- **One client per (blobOID, queryName), one tree per blob.** Correct for identity, but there is no
  notion of "parse this blob once, in the background, to completion" — parsing is smeared across
  on-demand windowed queries. A single owned parse would be simpler and faster.

## Implications for the unified single-scroll file feed (the coming refactor)

- **`visibleLineRange` currently returns ONE (old,new) range for the whole viewport.** That is correct
  only while the viewport holds a single file. A feed of many files in one scroll needs **per-file
  visible ranges** so each file warms only its own visible lines. This is flagged in
  `warmVisibleHighlights` but not built.
- **Per-file isolation already exists** in the controller (`highlightBlobsByFile: [FileID: ...]`, each
  leaf resolves its own file's runs via `segment.hunkID.fileID`). The caches are content-keyed. So the
  feed's *coloring* is already structurally safe; the missing piece is per-file *windowing* + per-file
  *warm scheduling*.
- **Cross-file concurrency is SAFE; same-file is not.** Different files = different clients = different
  trees → parsing them in parallel is fine. The corruption is only same-client concurrency. A feed could
  legitimately parse several files' clients concurrently — a natural multithreading axis — as long as any
  one client is only ever touched by one parse at a time.

## Multithreading notes

- `DiffHighlightEngine` and `TreeSitterClient` are `@MainActor`. The heavy parse runs off-main inside
  neon, but the client API must be entered from the main actor, and one client tolerates only one
  in-flight parse. So the parallelism unit is **the client (the blob)**, not the window.
- The injected-language `languageProvider` is called by neon OFF the main actor (background processor);
  the engine's config cache is a `Mutex` for exactly this reason. Any redesign must keep config/grammar
  resolution reachable nonisolated (a tree-sitter `Query` is parser-bound — never share one `Query`
  across clients).
- A clean model worth considering: an actor (or serial executor) **per blob** that owns its client and
  serializes parses, exposes a fast synchronous "read cached runs" path, and drives one background
  full-parse (+ iterative sublayer resolution) to completion on first touch. Queries become pure cache
  reads; the parse is a single owned job, not a fan-out. This would dissolve the gate, the fan-out, the
  cancel-can't-stop-parse hazard, and the injection limitation in one move — but it is a real refactor.

## Diagnostic techniques that worked (for the next investigator)

- **`SupaLogger.debug` prints to STDOUT in DEBUG** (not os_log). `make log-stream` shows nothing. Launch
  the DerivedData binary detached with stdout→a file and read the file. A `[TAG]`-prefixed log on every
  warm/parse/repaint (window, gaps, launch/cancel, merged-lines, cache coverage) is what cracked the
  flaky-repaint and all-red bugs.
- **Mutation repro on the real fixture beat theory.** The all-red bug was proven by parsing the actual
  `test25k.swift` window CONCURRENTLY headlessly and asserting the capture distribution (1/72 sequential
  vs 72/72 concurrent) — not by reading code. Timing/perf claims (async vs sync ms/call) likewise came
  from a headless probe over the real file, and repeatedly overturned intuition. Measure first.
- **Injected-grammar files:** cpp, html, javascript, make, markdown, php, rust, swift, zig ship an
  `injections.scm` — so you cannot gate behavior on "grammar has injections" (Swift does, and is the hot
  path). Whether a *specific blob* actually triggers a sublayer is only knowable by parsing.
