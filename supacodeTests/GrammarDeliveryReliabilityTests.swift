import Foundation
import SwiftTreeSitter
import Testing
import TreeSitterGrammars

@testable import supacode

/// Phase 0 grammar-delivery reliability gate. Exercises the *real* delivery path —
/// the `TreeSitterGrammars` xcframework symbols + the bundled `highlights.scm` +
/// the resolved tree-sitter 0.25 runtime behind `SwiftTreeSitter` — so a stale or
/// ABI-mismatched grammar fails loudly here instead of silently degrading a diff to
/// plain text at runtime.
struct GrammarDeliveryReliabilityTests {
  /// tree-sitter 0.25 accepts language ABI 13–15 (`TREE_SITTER_MIN/MAX_COMPATIBLE_
  /// LANGUAGE_VERSION`); a grammar sha emitting anything outside the range parses to
  /// a nil tree at runtime and drops silently. Assert every bundled grammar is in
  /// range so a future sha bump can't smuggle in an incompatible ABI.
  @Test func grammarABIVersionInRange() {
    let grammars = GrammarRegistry.allGrammars
    // One entry per treesitter-grammars.lock line (aliases collapse) — ties this
    // audit to the lock so an added/removed grammar forces the count to be updated.
    #expect(grammars.count == 24)
    for grammar in grammars {
      let abi = Language(grammar.language()).ABIVersion
      #expect(
        (13...15).contains(abi),
        "grammar '\(grammar.queryName)' language ABI \(abi) outside tree-sitter 0.25's 13...15 — bump its sha"
      )
    }
  }

  /// The `.scm` re-audit against SwiftTreeSitter-main's `Query` parser + the 0.25
  /// runtime. `Query(language:data:)` throws on a `ts_query_new` node/field mismatch
  /// or an invalid `#match?` regex; unknown predicates (`#lua-match?`, custom
  /// directives) degrade to `.generic` and are tolerated. Every bundled query must
  /// both resolve from the bundle and compile — a throw means that grammar silently
  /// drops in production.
  @Test func allBundledQueriesParseUnderResolvedRuntime() throws {
    for grammar in GrammarRegistry.allGrammars {
      guard case .available(let url) = SyntaxHighlighter.queryResource(for: grammar.queryName) else {
        Issue.record("bundled highlights.scm missing for resolved grammar '\(grammar.queryName)'")
        continue
      }
      let data = try Data(contentsOf: url)
      #expect(throws: Never.self, "highlights.scm for '\(grammar.queryName)' failed to compile under the 0.25 runtime")
      {
        _ = try Query(language: Language(grammar.language()), data: data)
      }
    }
  }

  /// The loud-fallback decision (Task 4b). A grammar the registry resolved but whose
  /// `highlights.scm` is absent must classify as `.missing` — the branch wired to a
  /// `SupaLogger.error` — never a silent `.available`/nil. A real bundled grammar
  /// classifies as `.available`. This proves the split that replaced the silent
  /// `return nil`, without needing to intercept the logger.
  @Test func missingGrammarLogsLoudly() {
    // A resolved grammar with a bundled query resolves to a real URL (silent path).
    guard case .available = SyntaxHighlighter.queryResource(for: "swift") else {
      Issue.record("expected the bundled swift highlights.scm to resolve in the test host")
      return
    }
    // A grammar name with no bundled query hits the loud branch, not a silent nil.
    #expect(
      SyntaxHighlighter.queryResource(for: "no-such-grammar-xyz")
        == .missing(queryName: "no-such-grammar-xyz")
    )
  }
}
