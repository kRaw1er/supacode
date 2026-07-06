import Foundation
import Neon
import SwiftTreeSitter
import SwiftTreeSitterLayer
import Testing
import TreeSitterClient
import TreeSitterGrammars

@testable import supacode

/// Phase 13 (C 15.5 / E 2.3) — the parse-tree cache's memory-pressure evict. The
/// response mapping is pure (`.critical → clear`, `.warning → trim-to-8`), injected
/// synthetically — never waiting on real pressure; the key excludes
/// `styleGeneration` so a style flip never invalidates a parse (parse trees survive).
@MainActor
struct ParseTreeCacheTests {

  // MARK: - Pure pressure-response mapping (no client needed)

  @Test func pressureResponseMapping() {
    #expect(ParseTreeCache.pressureResponse(critical: true, warning: false) == .clear)
    #expect(ParseTreeCache.pressureResponse(critical: false, warning: true) == .trim(toCount: 8))
    #expect(ParseTreeCache.pressureResponse(critical: false, warning: false) == .none)
    // A coalesced event carrying BOTH is treated as critical (clear wins).
    #expect(ParseTreeCache.pressureResponse(critical: true, warning: true) == .clear)
    #expect(ParseTreeCache.memoryWarningKeepCount == 8)
  }

  // MARK: - Real-client eviction

  private func makeSwiftClient(_ source: String) throws -> TreeSitterClient {
    let language = Language(tree_sitter_swift())
    let scmURL = try #require(
      Bundle.main.url(forResource: "highlights", withExtension: "scm", subdirectory: "TreeSitterQueries/swift"),
      "bundled swift highlights.scm missing")
    let query = try Query(language: language, data: Data(contentsOf: scmURL))
    let config = LanguageConfiguration(language, name: "swift", queries: [.highlights: query])
    let content = LanguageLayer.ContentSnapshot(string: source)
    let length = source.utf16.count
    return try TreeSitterClient(
      rootLanguageConfig: config,
      configuration: .init(
        languageProvider: { _ in nil },
        contentSnapshopProvider: { _ in content },
        lengthProvider: { length },
        invalidationHandler: { _ in },
        locationTransformer: { _ in nil }
      )
    )
  }

  @Test func criticalPressureClearsPopulatedCache() throws {
    let cache = ParseTreeCache(capacity: 24, monitorMemoryPressure: false)
    for index in 0..<3 {
      cache[ParseTreeCache.Key(blobOID: "oid-\(index)", queryName: "swift")] = try makeSwiftClient("let x = \(index)\n")
    }
    #expect(cache.count == 3)
    // Inject a synthetic .critical — clears everything.
    cache.handleMemoryPressure(critical: true, warning: false)
    #expect(cache.count == 0)
  }

  @Test func warningPressureTrimsToKeepCount() throws {
    let cache = ParseTreeCache(capacity: 24, monitorMemoryPressure: false)
    for index in 0..<3 {
      cache[ParseTreeCache.Key(blobOID: "oid-\(index)", queryName: "swift")] = try makeSwiftClient("let x = \(index)\n")
    }
    // trim-to-1 keeps only the MRU (oid-2, inserted last).
    cache.trim(toCount: 1)
    #expect(cache.count == 1)
    #expect(cache[ParseTreeCache.Key(blobOID: "oid-2", queryName: "swift")] != nil)
    #expect(cache[ParseTreeCache.Key(blobOID: "oid-0", queryName: "swift")] == nil)
    // A synthetic .warning maps to trim-to-8; on a 1-entry cache it's a no-op.
    cache.handleMemoryPressure(critical: false, warning: true)
    #expect(cache.count == 1)
  }

  @Test func styleGenerationExcludedFromKey() {
    // The key has NO styleGeneration component, so a style flip never changes it —
    // the same blob is ONE parse entry across appearance / zoom flips.
    let keyA = ParseTreeCache.Key(blobOID: "oid-1", queryName: "swift")
    let keyB = ParseTreeCache.Key(blobOID: "oid-1", queryName: "swift")
    #expect(keyA == keyB)
    #expect(keyA != ParseTreeCache.Key(blobOID: "oid-1", queryName: "python"))
  }
}
