---
phase: 0
title: Engine & build foundation (neon adoption spike + grammar rebuild) — GATE
wave: 1
execution: parallel        # with Phase 1 (disjoint files)
depends_on: []
status: completed
touches: [Tuist/Package.swift, Tuist/Package.resolved, Project.swift, scripts/build-treesitter-grammars.sh, scripts/treesitter-grammars.lock, mise.toml, ThirdParty/tree-sitter, patches/, Infrastructure/SyntaxHighlighting/GrammarRegistry.swift, Infrastructure/SyntaxHighlighting/SyntaxHighlighter.swift, Features/Diff/Views/DiffViewerRepresentable.swift, supacodeTests/NeonSmokeTests.swift]
---

# Phase 0 — Engine & build foundation (neon spike) — GATE

## Goal

Land the build/dependency foundation for ChimeHQ **neon** and **prove or disprove it under the
project's pinned Xcode BEFORE any render code depends on it.** Harden grammar delivery so a missing
grammar fails loudly (root cause of "highlighting doesn't work"), not silently to plain text. This is
the plan's **highest single risk** — it is Phase 0 and gated.

## Depends on

Nothing. Runs in parallel with Phase 1 (Phase 1 is pure Swift model, disjoint files). The current
shipped viewer keeps working throughout (its thin SwiftTreeSitter usage is source-compatible across
the bump — see below).

## Context (cold-start)

**Why this is a gate.** The brainstorm resolved "adopt neon, cap it," but only said "bump
SwiftTreeSitter to a neon-compatible version." Grounding in the **actual neon + SwiftTreeSitter
source** revealed the real cost:

- neon `main` → SwiftTreeSitter `branch: main` (neon `Package.swift:18`) → tree-sitter runtime
  `.upToNextMinor(from: "0.25.0")` (SwiftTreeSitter `main/Package.swift`, tools-version 5.9).
- Our pin is **SwiftTreeSitter `exact 0.9.0` → tree-sitter `0.23.2`** (`Tuist/Package.swift:30`,
  `Tuist/Package.resolved:176-192`), chosen **specifically** to avoid **tree-sitter#5523** (`TSLanguage`
  "not in scope" under Xcode 26.4+/Swift 6.3 explicit-modules, which bites tree-sitter **≥ 0.25**).
- Adopting neon **reactivates #5523** and forces a grammar xcframework rebuild against the 0.25 ABI +
  likely activation of the amalgamation-override the earlier Phase 4 built but proved "unnecessary"
  only because 0.9.0 stayed pre-0.25.
- neon pins SwiftTreeSitter to `branch: main`, **not a semver** → commit-pin both.
- `TreeSitterClient` is a **`@MainActor` class, not an `actor`** (neon `TreeSitterClient.swift:22-24`,
  `@MainActor @preconcurrency public final class`); heavy parse is offloaded to its internal
  `BackgroundingLanguageLayerTree` (`TreeSitterClient.swift:114-126`). Our `Project.swift:128`
  already sets `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`, so this isolation lines up out of the box.

### Exact pins (grounded 2026-07-05 — use these verbatim in the spike)

| Package | Current pin | After neon | Source |
|---|---|---|---|
| **Neon** (new) | — | `revision: 484d6fb9e0c4fb679a1d5f5ddaf2cac2ecf21165` (main HEAD, 2026-04-18) | neon has no live semver tag — pin the sha |
| **SwiftTreeSitter** | `exact 0.9.0` (rev `36aa61d1…`, `Package.resolved:180-181`) | `revision: 0f40435cdb41673ce4194d731571cf2a2f7c3285` (main HEAD, 2026-05-26) | neon pins it `branch: main` (`neon/Package.swift:18`) |
| **tree-sitter** (transitive) | `0.23.2` (rev `d97db6d6…`, `Package.resolved:189-190`) | **`0.25.10`** (highest `0.25.x`) | SwiftTreeSitter `main` `.upToNextMinor(0.25.0)` |
| **Rearrange** (new, transitive via neon) | — | `from: "2.0.0"` (semver — **no commit-pin needed**; `Package.resolved` records the exact build) | `neon/Package.swift:19` |

Products the app/tests reference: `Neon` (only product of the Neon pkg, `neon/Package.swift:15`),
`SwiftTreeSitter` + `SwiftTreeSitterLayer` (products of the ST pkg), `Rearrange`. **`TreeSitterClient`
is a _target_ of the Neon package, not a product** — the Phase-4 engine imports it, so the spike must
confirm Tuist surfaces it (see Edge cases).

**Source-compatibility fact (why the current viewer survives the bump):** our thin usage
(`Language(_:)`, `Query(language:data:)` `SyntaxHighlighter.swift:214`, `query.execute(in:)` `:101`,
`QueryCursor.setRange` `:102`, `.resolve(with:).highlights()` `:103`, `Parser.parse` `:193`,
`MutableTree` `:54`) is **unchanged** 0.9.0 → main (per C9's verified diff). Only the tree-sitter
**runtime** bump + grammar rebuild is real work. The one plausible break is the `ResolvingQueryCursor`
context init form at `:103` (`.resolve(with: .init(string:))`) — if main dropped the `string:`
convenience for the `textProvider:` form (neon uses `.init(textProvider:)`, `TreeSitterClient.swift:348`),
adapt that single line; that is in-scope for "keep it green."

**Prior-art to mirror (already in the repo):**
- `Project.swift:164-176` — GhosttyKit `.foreignBuild` xcframework (the template).
- `Project.swift:177-190` — the existing `TreeSitterGrammars` `.foreignBuild` target (already wired).
- `scripts/build-treesitter-grammars.sh` — the grammar C-compile pipeline; fingerprint short-circuit
  `:53-59` (the reliability gap: a partial/stale `.build/treesitter` is treated as up-to-date because
  `:54-57` only checks that the dirs *exist*, not that every locked grammar is present).
- `scripts/build-ghostty.sh:75-151` — the out-of-tree `patches/*.patch` apply/revert pattern
  (`apply_ghostty_patches` `:90`, `revert_ghostty_patches` `:114`, EXIT+INT+TERM traps `:148-151`) to
  mirror for a tree-sitter amalgamation submodule.
- `scripts/treesitter-grammars.lock` — 24 pinned grammar shas (`key␉repo␉sha␉subdir␉symbol`), a
  fingerprint input to the `.foreignBuild`.
- The earlier `docs/plans/2026-07-03-feat-git-diff-review-panel-phases/phase-4-syntax-highlighting.md`
  "Build wiring" section — the amalgamation-override design (submodule + `patches/tree-sitter-amalgamation.patch`,
  `sources:["src/lib.c"]`, drop `publicHeadersPath`) is already written there; it was disabled because
  0.9.0/0.23.2 already ships that single-TU shape.

**Silent-fallback code to fix:** `SyntaxHighlighter.swift:205-211` (missing `.scm` URL → `return nil`,
**no log**) and `DiffViewerRepresentable.swift:126-134` (`scheduleHighlight` guard → `clearSyntax()`
silently). `SyntaxHighlighter` already owns `SupaLogger("SyntaxHighlighter")` (`:65`); the Coordinator
(`DiffViewerRepresentable.swift:85`) has no logger yet.

**Open first (read the code, not this summary):** neon `Package.swift`,
`Sources/TreeSitterClient/TreeSitterClient.swift` (`init :116`, `Configuration :38-88`,
`highlights(in:provider:) :375-388`, `@MainActor :22`), `Sources/Neon/TreeSitterClient+Neon.swift:75-110`
(headless `highlight(string:)`); SwiftTreeSitter `Sources/SwiftTreeSitter/LanguageConfiguration.swift`
(`init(_:name:queries:)`), our `Tuist/Package.swift:24-30`, `Project.swift:54-91,164-190`,
`scripts/build-treesitter-grammars.sh`, `scripts/build-ghostty.sh:75-151`.

CLAUDE.md: `SupaLogger` only (no `print`/`os.Logger`); no free funcs; TestClock not `Task.sleep`;
120-col; commit only touched files; `make check` strict; pins live in the Tuist SPM manifest,
regenerate via `make generate-project` (`tuist install` rewrites `Package.resolved`).

## Tasks

- [x] **Spike first (timebox):** add neon + Rearrange and bump SwiftTreeSitter in `Tuist/Package.swift`
      (commit pins, §diffs below); let tree-sitter resolve to `0.25.10`. Add `.external(name: "Neon")`
      to app + test deps in `Project.swift`. Write a headless smoke test (§snippet) — build a
      `TreeSitterClient` over a Swift `String`, call `highlights(in:provider:)`, assert non-empty
      `[NamedRange]`. **Build under the project's pinned Xcode 26.3** (`scripts/select-developer-dir.sh`).
      → `NeonSmokeTests.swiftHighlightsAreNonEmpty` passes; `make build-app` links Neon green under 26.3.
- [x] **Gate decision — RECORD in this file (§decision matrix):** ran the #5523 procedure under both
      Xcode 26.3 and 26.4.1 (isolated spike + xcodebuild explicit-modules) → **#5523 did not reproduce**
      → **neon-vanilla** (no amalgamation; no Option B). See the filled RECORD block above.
- [x] **Grammar xcframework rebuild** against the resolved tree-sitter ABI via `.foreignBuild` +
      `scripts/build-treesitter-grammars.sh` (rebuilt during `make build-app`); **re-audited** the 24
      bundled `highlights.scm` via `allBundledQueriesParseUnderResolvedRuntime` — all 24 compile under the
      0.25 runtime + SwiftTreeSitter-main (no grammar drops). Finding: unknown predicates (`#lua-match?`,
      `#is-not?`, `#any-of?`, custom directives) degrade to `.generic` and are **tolerated** (they do NOT
      throw in SwiftTreeSitter-main), so no grammar silently drops. Kept the nested `TreeSitterGrammars/`
      modulemap. Per-grammar ABI-range check (`grammarABIVersionInRange`) confirms every grammar ∈ 13…15.
- [x] **Reliability fix (§validation + §logging):** added build-time validation (`validate_artifact` —
      every locked symbol exported by the fat lib + every locked `highlights.scm` copied) + a
      build-provenance stamp (`compute_provenance` → `.build/treesitter/provenance`, committed into the
      lock header) so the short-circuit can't mask a stale/partial artifact; and **loud `SupaLogger.error`
      on a missing grammar** in both `SyntaxHighlighter.query(for:)` (resolved-grammar/missing-`.scm`) and
      `DiffViewerRepresentable` (resolved grammar → zero highlights), replacing the silent fallbacks.
- [x] Confirmed the **current** highlighter still compiles across the bump (NOT deleted; the
      `(x/2)..<(y/2)` double-divide at `SyntaxHighlighter.swift` is untouched — C10). `make build-app` and
      the shipped viewer stay green.

### `Tuist/Package.swift` diff (Task 1)

Replace the `exact 0.9.0` line (`:30`); add neon + Rearrange:
```swift
-    .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.9.0"),
+    // neon adoption (Phase 0). neon pins SwiftTreeSitter branch:main → tree-sitter 0.25.x; we
+    // commit-pin the resolved shas so a floating branch can't drift (C9). Rearrange is semver.
+    .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", revision: "0f40435cdb41673ce4194d731571cf2a2f7c3285"),
+    .package(url: "https://github.com/ChimeHQ/Neon", revision: "484d6fb9e0c4fb679a1d5f5ddaf2cac2ecf21165"),
+    .package(url: "https://github.com/ChimeHQ/Rearrange", from: "2.0.0"),
```
A root `.revision()` on SwiftTreeSitter overrides neon's transitive `branch: "main"` (SPM: the root
package's requirement wins). **If SPM rejects the branch↔revision mix** ("required using both a
revision and a branch"), fall back to `branch: "main"` and rely on the committed `Tuist/Package.resolved`
(records the exact sha) — that IS a commit-pin. `make generate-project` (`tuist install`) rewrites
`Package.resolved`; **commit it**.

### `Project.swift` diff (Task 1)

`appDependencies` (`:54-72`) and `testDependencies` (`:74-91`) each gain one line; keep
`.external(name: "SwiftTreeSitter")` and `.target(name: "TreeSitterGrammars")`:
```swift
     .external(name: "SwiftTreeSitter"),
+    .external(name: "Neon"),
```
`Neon` transitively links `TreeSitterClient` / `RangeState` / `Rearrange` / `SwiftTreeSitterLayer`.

### Headless neon smoke test (Task 1) — `supacodeTests/NeonSmokeTests.swift`

Mirrors `neon/TreeSitterClient+Neon.swift:81-97`. `TreeSitterClient` is `@MainActor` (C9) → `@MainActor`
suite. Grammar + query come from our own `TreeSitterGrammars` xcframework + bundled `.scm` (same lookup
the app uses at `SyntaxHighlighter.swift:206`), so this exercises the real delivery path, not neon's
vendored fixture.
```swift
import Foundation
import Neon
import SwiftTreeSitter
import SwiftTreeSitterLayer
import Testing
import TreeSitterClient
import TreeSitterGrammars

@Suite @MainActor
struct NeonSmokeTests {
  @Test func swiftHighlightsAreNonEmpty() async throws {
    let language = Language(tree_sitter_swift())                       // OpaquePointer → Language
    let scmURL = try #require(
      Bundle.main.url(forResource: "highlights", withExtension: "scm",
                      subdirectory: "TreeSitterQueries/swift"))
    let query = try Query(language: language, data: Data(contentsOf: scmURL))
    let config = try LanguageConfiguration(language, name: "swift", queries: [.highlights: query])

    let source = "struct Foo { let bar = 42 }\n"
    let content = LanguageLayer.ContentSnapshot(string: source)
    let length = source.utf16.count
    let client = try TreeSitterClient(
      rootLanguageConfig: config,
      configuration: .init(                                            // TreeSitterClient.swift:72-87
        languageProvider: { _ in nil },
        contentSnapshopProvider: { _ in content },
        lengthProvider: { length },
        invalidationHandler: { _ in },
        locationTransformer: { _ in nil }))
    client.didChangeContent(in: NSRange(location: 0, length: 0), delta: length)   // primes the parse

    let ranges = try await client.highlights(
      in: NSRange(location: 0, length: length), provider: content.textProvider)
    #expect(!ranges.isEmpty)                                           // engine + grammar + query OK
    #expect(ranges.contains { $0.name.hasPrefix("keyword") })         // `struct` / `let`
  }
}
```
`LanguageConfiguration(_:name:queries:)` is the non-throwing dict init (has an `OpaquePointer` variant
too). Remove the test after the gate if Option B is chosen.

### #5523 test procedure + gate decision matrix (Task 2)

1. After Task 1 resolves (tree-sitter `0.25.10`), `make build-app` under the pinned Xcode 26.3.
2. If it links, repeat under a 26.4+/Swift 6.3 toolchain **if installed**:
   `DEVELOPER_DIR=/Applications/Xcode_26.4.app/Contents/Developer make build-app`.
3. **#5523 signature:** compile errors in the `TreeSitter`/`SwiftTreeSitter` modules of the form
   `cannot find type 'TSLanguage' in scope` / `cannot find 'ts_*' in scope` even though `import
   TreeSitter` succeeds — only under the explicit-modules pipeline (Swift 6.3). A clean 0.23.2 baseline
   compiles both.
4. **Record below:** which Xcodes tested, exact error text (or "clean"), chosen row, final pins.

| Spike result (26.3 / 26.4+) | #5523? | Decision |
|---|---|---|
| 26.3 clean · 26.4+ clean (or 26.4+ untested) | no | **neon vanilla** — no submodule/patch. Still commit-pin. |
| 26.3 clean · 26.4+ "TSLanguage not in scope" | yes (26.4+) | **neon + amalgamation override** (§amalgamation). CI / other devs on 26.4+ need it; verify it clears 26.4+. |
| amalgamation unworkable (patch/resolve-timing/build-cost) | — | **Option B** — revert ST `exact 0.9.0` / tree-sitter `0.23.2`, drop neon+Rearrange, Phase 4 = fix hand-rolled engine (injections lost). Record the cut. |

> **RECORD (2026-07-06, gated):** **Decision = neon-vanilla** (matrix row 1 — no submodule/patch;
> commit-pinned). **#5523 = did NOT reproduce.**
>
> - **Xcodes tested:** Xcode **26.3** (Build 17C529 / Swift 6.2.4 — the project's pinned, Zig-linkable
>   toolchain) **and** Xcode **26.4.1** (Build 17E202 / Swift 6.3.1 — the "26.4+/6.3" toolchain #5523
>   targets). The dependency graph resolves to Neon `484d6fb9…`, SwiftTreeSitter `0f40435c…` (branch
>   `main`, exact sha in `Tuist/Package.resolved`), tree-sitter **`0.25.10`** (rev `da6fe9be…`),
>   Rearrange `2.1.1`.
> - **26.3 = CLEAN.** Isolated spike (`swift build` + `xcodebuild` explicit-modules) green; and the real
>   `make build-app` links Neon + tree-sitter 0.25.10 into the app → **Build Succeeded**. `NeonSmokeTests`
>   + the 3 grammar-delivery tests pass (10 tests, 3 suites).
> - **26.4+ = CLEAN.** Isolated spike under 26.4.1: `swift build` green; **`xcodebuild -scheme Neon`
>   through the explicit-modules pipeline** (`-explicit-module-build`, `SwiftExplicitDependencyGeneratePcm`
>   — the exact #5523 trigger) → **`** BUILD SUCCEEDED **`**, no `TSLanguage`/`ts_*` "not in scope".
> - **#5523 analysis:** the issue reproduces on Xcode **26.4.0 (17E192) / Swift 6.3.0** with tree-sitter's
>   multi-file `sources:["src"]` + umbrella-dir modulemap under Xcode 26's explicit modules. It is **fixed
>   in the 26.4.1 (17E202) / Swift 6.3.1 point release** (verified above). Independently, it is **moot on
>   this project's ship path**: ghostty/zig#31658 forces every real build to Xcode 26.3 via
>   `scripts/select-developer-dir.sh`, so tree-sitter is only ever compiled under 26.3 (clean). No
>   vendored `tree-sitter` amalgamation submodule/patch is required or added.
>
> Pins committed: Neon `484d6fb9e0c4fb679a1d5f5ddaf2cac2ecf21165` · SwiftTreeSitter
> `0f40435cdb41673ce4194d731571cf2a2f7c3285` (branch `main`, sha pinned in `Package.resolved`) ·
> tree-sitter `0.25.10` (`da6fe9be…`) · Rearrange `2.1.1`. **SPM branch↔revision note:** a root
> `.revision()` over neon's transitive `branch:"main"` on SwiftTreeSitter is rejected ("required using two
> different revision-based requirements"), so SwiftTreeSitter stays `branch:"main"` with the exact sha
> committed in `Package.resolved` (that IS the commit-pin). **Tuist note:** `.external(name:)` accepts SPM
> *products* only — `TreeSitterClient` is a package *target*, not a product, so it is reached as a
> transitive module through the `Neon` product rather than named directly.

### Amalgamation override (Task 2 — only if #5523 bites)

Mirrors the ghostty submodule + out-of-tree patch. **No fork; the submodule pin never moves.**
1. `git submodule add https://github.com/tree-sitter/tree-sitter ThirdParty/tree-sitter`, checkout the
   **exact tree-sitter commit SwiftTreeSitter-main resolves** (v0.25.10). Record it in `Package.resolved`.
2. `Tuist/Package.swift`: add `.package(path: "ThirdParty/tree-sitter")`. SPM identity is the last path
   component (`tree-sitter`), which **matches** the transitive remote
   `https://github.com/tree-sitter/tree-sitter` → the local path package **overrides** it (root
   local-path-override wins). It must expose the `TreeSitter` product SwiftTreeSitter's `TreeSitter`
   target links.
3. `patches/tree-sitter-amalgamation.patch` transforms the `TreeSitter` target from the 0.25.10
   **multi-file** shape (`sources:["src"]` + `publicHeadersPath:"include"` → the umbrella-dir modulemap
   #5523 chokes on) to the **known-good single-TU** shape tree-sitter 0.23.2 shipped (which compiles
   clean under 26.3 — verified by the earlier Phase-4 deviation):
   ```diff
    .target(
        name: "TreeSitter",
        path: "lib",
   -    exclude: ["src/lib.c", "src/unicode/ICU_SHA", /* …wasm… */],
   -    sources: ["src"],
   -    publicHeadersPath: "include",
   +    sources: ["src/lib.c"],                       // amalgamation: lib.c #includes every other src/*.c
        cSettings: [
            .headerSearchPath("src"),                 // 0.23.2 keeps this; keep it
            .define("_POSIX_C_SOURCE", to: "200112L"),// keep 0.25's C defines — its src needs them
            .define("_DEFAULT_SOURCE"),
            .define("_DARWIN_C_SOURCE"),
        ]
    ),
   ```
   (0.25.10: `sources:["src"]`, `publicHeadersPath:"include"`, `exclude` lists `src/lib.c`. 0.23.2:
   `sources:["src/lib.c"]`, `headerSearchPath:"src"`, no `publicHeadersPath`, no `exclude`. The patch
   makes 0.25 look like 0.23.2, retaining 0.25's defines. Confirm in the spike whether dropping
   `publicHeadersPath` alone suffices or `import TreeSitter` needs the default `include/` — 0.23.2's
   known-good config drops it.)
4. Apply/revert: reuse `build-ghostty.sh:90-128`'s idempotent `git apply --reverse --check` /
   `--check` logic verbatim (rename `ghostty_` → `tree_sitter_`).

> ⚠️ **Deepening note (NEW conflict — resolve in the spike; does NOT overturn the amalgamation
> decision):** ghostty's patch is safe to revert-on-EXIT because `zig build` reads the working tree
> only *during* the build script. A tree-sitter **local path package** is different: SPM re-reads the
> path package's sources on **every resolve _and_ every build**, so a revert-on-exit would leave an
> unpatched (broken) tree for the next `tuist generate`/Xcode build. The patch must be **live at
> SPM-resolve time and stay applied** while Tuist/Xcode reference the package. Options: (a) apply the
> patch idempotently at the top of `make generate-project` **and** as the first step of the grammars
> `.foreignBuild` script, and **do not revert** (a dirty submodule working tree is fine — the parent
> repo's submodule pin is untouched; `scripts/patch-tree-sitter.sh --check` asserts it's applied); (b)
> commit our amalgamation `Package.swift` as a repo file that shadows the submodule's. Recommend (a);
> verify no `make check` / `git status` breakage from the persistently-dirty submodule in the spike.

### Grammar rebuild + `.scm`/ABI re-audit (Task 3)

- The grammar xcframework forward-declares `TSLanguage` opaque and compiles only `parser.c`/`scanner.c`
  (`build-treesitter-grammars.sh:104-114,167-169`) — **no runtime headers**, so it's ABI-decoupled at
  *compile* time and needs **no lock-sha change to link**. But at **runtime** the 0.25 runtime validates
  each `tree_sitter_<lang>()`'s language ABI (`ts_language_abi_version`); tree-sitter 0.25 accepts
  language ABI 13–15. A grammar sha emitting an out-of-range ABI **silently returns a nil tree** → plain
  fallback. **Re-audit:** add a test asserting `ts_language_abi_version(tree_sitter_<sym>())` ∈ range
  for every lock entry; bump any offending sha in `treesitter-grammars.lock`.
- `.scm` re-audit: `Query(language:data:)` tolerates unknown capture *names* (they map to
  `HighlightTheme` default `.labelColor`), but **throws on an unknown predicate** (`#is-not?`,
  `#any-of?`). If a 0.25-era `highlights.scm` uses one SwiftTreeSitter-main can't parse, that grammar
  silently drops. Record which captures/predicates are new; Phase 4 adds the colors.

### Reliability — build-time validation + provenance stamp (Task 4a) in `build-treesitter-grammars.sh`

- After `lipo` (`:151-152`), for every lock `symbol` assert the fat lib exports it, else fail loudly:
  `nm -gU "${fat_lib}" | grep -q "_tree_sitter_${symbol}$" || { echo "error: ${key}: missing symbol" >&2; exit 1; }`
- After `copy_queries` (`:142`), assert `${queries_dir}/${key}/highlights.scm` exists for every entry.
- **Provenance stamp:** write `${build_root}/provenance` = `sha256(lock) + count + sorted symbols`, and
  extend the `:53-59` short-circuit to also require the stamp match the current lock — a partial/stale
  `.build/treesitter` (some grammars missing) then **fails** the short-circuit and rebuilds. Commit the
  stamp value into the lock header comment so CI catches a stale gitignored artifact.

### Reliability — loud runtime logging (Task 4b), replaces silent plain fallback

- `SyntaxHighlighter.swift:205-211` (`query(for:)`): the `guard let url = Bundle.main.url(…) else {
  return nil }` returns nil with no log when a **resolved** grammar's `.scm` is missing. Log first:
  ```swift
  else {
    Self.logger.error(
      "missing bundled highlights.scm for grammar '\(queryName)' — plain-text fallback "
      + "(stale/partial TreeSitterGrammars build?)")
    return nil
  }
  ```
- `DiffViewerRepresentable.swift:126-134` (`scheduleHighlight`): the guard folds three cases —
  `workingDirectory`, `grammar`, `visibleLines`. `grammar == nil` is a **legit** plain-text extension
  (stay silent / DEBUG). The defect is "a **known** grammar produced nothing." Split the guard: keep
  no-grammar/no-visible silent; add `private static let logger = SupaLogger("DiffViewer")` to the
  Coordinator (`:85`) and `logger.error(…)` where `GrammarRegistry.grammar(forPath:) != nil` yet the
  highlight Task returns empty. (The wrong-blob bug #1 is Phase 4; here we only remove the *silence*.)

## Acceptance criteria

- [x] `import Neon` + `NeonSmokeTests.swiftHighlightsAreNonEmpty` build & pass under the project's
      pinned Xcode 26.3; `make build-app` + `make check` clean.
- [x] The engine decision (**neon vs Option B**) is recorded in the §matrix with the #5523 outcome
      (Xcodes tested + exact error/clean) and the exact pins. → neon-vanilla, #5523 did not reproduce.
- [x] A deliberately-missing grammar produces a `SupaLogger` **error**, not silent plain text
      (`SyntaxHighlighter.queryResource` `.missing` branch + `DiffViewer` empty-highlight branch; covered
      by `missingGrammarLogsLoudly`); the build-time validation fails loudly on a missing symbol/`.scm`
      (`validate_artifact`, negative case exercised).
- [x] `Tuist/Package.resolved` shows Neon `484d6fb9…`, SwiftTreeSitter `0f40435c…` (branch `main`, exact
      sha), tree-sitter `0.25.10` — **committed**, no floating branch (the branch requirement is pinned by
      the committed sha).

## Edge cases & gotchas

- **tree-sitter#5523 is a 26.4+/6.3 regression** — verify on BOTH the pinned 26.3 and (if available) a
  26.4+ toolchain before declaring the amalgamation unnecessary. 26.3 passing does **not** clear CI/other
  devs on 26.4+.
- **SPM branch↔revision conflict:** a root `.revision()` over neon's transitive `branch: "main"` may be
  rejected; fall back to `branch: "main"` + committed `Package.resolved` (still a commit-pin).
- **`TreeSitterClient` is a target, not a product**, of the Neon package (`neon/Package.swift:15` exposes
  only `Neon`). If `import TreeSitterClient` doesn't resolve under Tuist `.external(name: "Neon")`, add
  `.external(name: "TreeSitterClient")` (Tuist usually surfaces graph target names) — confirm in the spike.
- **Amalgamation patch timing** (⚠️ above): a local path package is re-read every resolve/build, so the
  ghostty revert-on-exit pattern does **not** transfer — keep it applied.
- **Grammar ABI drift:** a pinned sha emitting an ABI outside 0.25's 13–15 range parses to nil silently
  → assert `ts_language_abi_version` per grammar.
- **`.scm` predicate drift:** a new predicate throws in `Query(language:data:)` → that grammar drops.
- **Rearrange is semver** (`from: 2.0.0`) — only SwiftTreeSitter (branch-pinned by neon) needs a commit
  pin; don't over-pin Rearrange.
- **Fingerprint short-circuit (`:53-59`)** masks a stale artifact — the provenance stamp is the fix.
- **Don't touch** `SyntaxHighlighter.swift:110`'s double-divide (C10) or delete the current highlighter
  here (Phase 4 does both) — only additive logs land in this phase.

## Verification checklist

Tests ship WITH this phase (bar: ≥pierre + net-new + UTF + seam; full assignment in TEST-STRATEGY.md §2).

_P0 has no render/text entities → no Unicode/seam tests land here; only the build-reliability gate + the
grammar-delivery reliability tests. `neonSmokeSwiftHighlightsAreNonEmpty` is carried into P4 as `4.11`._

| Test | Type | Assertion (≤1 line) | Src |
|---|---|---|---|
| `neonSmokeSwiftHighlightsAreNonEmpty` | CT-HEADLESS | `TreeSitterClient.highlights` over a Swift `String` → non-empty `[NamedRange]` incl. a `keyword` capture (the gate) | C/A |
| `grammarABIVersionInRange` | PURE | `ts_language_abi_version(tree_sitter_<sym>())` ∈ 13–15 for every lock entry | C |
| `grammarRegistryExtensions` | PURE | `GrammarRegistry` resolves each new ext/alias/capture from the 0.25 `.scm` re-audit | C |
| `missingGrammarLogsLoudly` | PURE | a resolved grammar with a missing `.scm` emits a `SupaLogger` error, not silent plain fallback | C |
| `buildValidationFailsOnMissingSymbol` | MANUAL | build-time validation fails loudly on a missing exported symbol / uncopied `.scm` (17.5) | C |
| `sharedHighlighterSingletonLifecycle` (seed) | CT-HEADLESS | P0 only proves `TreeSitterClient` builds headless; full singleton test DEFERRED to P4 | B |

- **Builds first:** none of the shared I1–I5 infra (those land P1/P3/P5/P9). The NeonSmoke build under the
  pinned Xcode 26.3 is itself the P0 highlight perf-baseline (§5.4).
- [x] `make build-app` + `make check` clean.
- [x] **Plan compliance check:** Re-read this phase file top to bottom; every `[ ]` addressed. All 6
      Verification tests shipped: `neonSmokeSwiftHighlightsAreNonEmpty` (NeonSmokeTests),
      `grammarABIVersionInRange` + `allBundledQueriesParseUnderResolvedRuntime` (the `.scm` re-audit) +
      `missingGrammarLogsLoudly` (GrammarDeliveryReliabilityTests), `grammarRegistryExtensions`
      (GrammarRegistryTests), and `buildValidationFailsOnMissingSymbol` (MANUAL — `validate_artifact`
      negative case). 10 tests / 3 suites pass under Xcode 26.3.

## Review Prompt

Review Phase 0 (engine & build foundation). Verify: (1) the neon adoption was **spiked and gated** —
build result under the pinned Xcode recorded in the decision matrix, #5523 outcome documented (Xcodes +
exact error/clean), and either the amalgamation override applied (submodule + `patches/*.patch`,
`sources:["src/lib.c"]`, no `publicHeadersPath`, apply/revert adapted from `build-ghostty.sh` — noting the
resolve-time-timing divergence) OR Option B (SwiftTreeSitter 0.9.0) chosen with rationale; (2) neon +
SwiftTreeSitter are **commit-pinned** in `Tuist/Package.swift` + `Package.resolved` (not floating
`branch: main`); (3) the grammar xcframework rebuilt against the resolved tree-sitter ABI, the 24
bundled `.scm` re-audited, and a per-grammar ABI-range check added; (4) a missing grammar now **logs via
`SupaLogger`** (runtime) **and fails the build** (validation + provenance stamp) instead of silent plain
fallback; (5) the current shipped highlighter still compiles (not deleted; double-divide untouched); (6)
`make build-app` + `make check` clean. Flag any floating branch pin, any silent fallback left in place,
any revert-on-exit of the tree-sitter path-package patch, or an undocumented gate decision. Confirm the 4
automated gate tests (§Verification: neon smoke, per-grammar ABI-range, GrammarRegistry ext/alias,
missing-grammar-logs-loudly) ship with the phase.
