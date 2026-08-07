import Foundation
import Neon
import SwiftTreeSitter
import SwiftTreeSitterLayer
import Testing
import TreeSitterClient
import TreeSitterGrammars

/// Phase 0 GATE — the headless proof that ChimeHQ **neon** builds and runs against
/// the project's real grammar-delivery path under the pinned toolchain: the
/// `TreeSitterGrammars` xcframework symbol (`tree_sitter_swift()`), the bundled
/// `highlights.scm`, and the resolved tree-sitter 0.25 runtime behind
/// `SwiftTreeSitter`. Mirrors `TreeSitterClient+Neon.highlight(string:)`.
///
/// `TreeSitterClient` is `@MainActor` (its heavy parse is offloaded to an internal
/// `BackgroundingLanguageLayerTree`), so the whole suite is `@MainActor`.
///
/// Carried into Phase 4 as test `4.11` (`sharedHighlighterSingletonLifecycle` grows
/// out of it); if the gate ever flips to Option B this file is removed.
@Suite @MainActor
struct NeonSmokeTests {
  @Test func swiftHighlightsAreNonEmpty() async throws {
    // OpaquePointer from the prebuilt grammar xcframework → SwiftTreeSitter.Language.
    let language = Language(tree_sitter_swift())
    let scmURL = try #require(
      Bundle.main.url(
        forResource: "highlights",
        withExtension: "scm",
        subdirectory: "TreeSitterQueries/swift"
      ),
      "bundled swift highlights.scm missing — TreeSitterGrammars build did not copy the query"
    )
    let query = try Query(language: language, data: Data(contentsOf: scmURL))
    let config = LanguageConfiguration(language, name: "swift", queries: [.highlights: query])

    let source = "struct Foo { let bar = 42 }\n"
    let content = LanguageLayer.ContentSnapshot(string: source)
    let length = source.utf16.count
    let client = try TreeSitterClient(
      rootLanguageConfig: config,
      configuration: .init(
        languageProvider: { _ in nil },
        contentSnapshopProvider: { _ in content },
        lengthProvider: { length },
        invalidationHandler: { _ in },
        locationTransformer: { _ in nil }
      )
    )
    // Prime the parse over the whole document before querying it.
    client.didChangeContent(in: NSRange(location: 0, length: 0), delta: length)

    let ranges = try await client.highlights(
      in: NSRange(location: 0, length: length),
      provider: content.textProvider
    )

    // Engine + grammar + query all wired: non-empty, and a `keyword` capture proves
    // the query actually classified `struct` / `let`, not just tokenised whitespace.
    #expect(!ranges.isEmpty)
    #expect(ranges.contains { $0.name.hasPrefix("keyword") })
  }
}
