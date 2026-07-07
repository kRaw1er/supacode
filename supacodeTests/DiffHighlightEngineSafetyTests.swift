import Foundation
import Testing

@testable import supacode

/// Crash guards for the highlight engine — both LATENT until the production load path
/// actually fed the highlighter (blobs were nil), then surfaced on real files:
///  1. UTF-16 length desync. `PreparedBlob` built `NSString(fromRawUTF16) as String`,
///     and that bridge can CHANGE the UTF-16 count, so `windowRange` / `lineStarts`
///     (NSString space) disagreed with neon's parse length (`String.utf16.count`) —
///     a query range past the parse length made tree-sitter read past content
///     (`location > end`). The blob is now built String-first, one UTF-16 space.
///  2. neon resolves injected sublayers on its BACKGROUND processor and calls our
///     `languageProvider`; that closure used `MainActor.assumeIsolated`, which traps
///     off the main actor. `injectedLanguageConfiguration` is now nonisolated.
@Suite(.serialized)
@MainActor
struct DiffHighlightEngineSafetyTests {
  private func realLargeSwiftSource() throws -> String {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "supacode/Features/Diff/Reducer/DiffReviewFeature.swift")
    let data = try #require(FileManager.default.contents(atPath: url.path), "fixture file missing")
    return try #require(String(data: data, encoding: .utf8))
  }

  /// Highlighting a big REAL Swift file (hundreds of lines) must not crash — it did,
  /// via the UTF-16 length desync (`location > end`) and the off-main injection
  /// resolution (`MainActor.assumeIsolated`). Both are exercised here end to end.
  @Test func highlightsLargeRealSwiftFileWithoutCrashing() async throws {
    let source = try realLargeSwiftSource()
    let lineCount = source.split(separator: "\n", omittingEmptySubsequences: false).count
    let engine = DiffHighlightEngine()
    let input = HighlightBlobInput(
      blobOID: "safety-large", utf16: Array(source.utf16), path: "DiffReviewFeature.swift")
    let runs = await engine.styleRuns(for: input, visibleLines: 0..<lineCount)
    #expect(!runs.isEmpty, "a real Swift file must highlight")
  }

  /// Resolving an injected grammar OFF the main actor must not crash (it did, via
  /// `MainActor.assumeIsolated`) and must still return a config.
  @Test func injectedConfigResolvesOffMainActorWithoutCrashing() async {
    let engine = DiffHighlightEngine()
    let config = await Task.detached { engine.injectedConfiguration(named: "python") }.value
    #expect(config != nil, "the injected config must resolve off the main actor")
    let missing = await Task.detached { engine.injectedConfiguration(named: "no-such-lang") }.value
    #expect(missing == nil)
  }
}
