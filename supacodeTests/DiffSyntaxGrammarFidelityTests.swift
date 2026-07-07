import CoreText
import Foundation
import Testing

@testable import supacode

/// CAT 2 — cross-grammar color fidelity. The user report was "any file, all white",
/// so this proves the WHOLE pipeline (real `DiffHighlightClient` → tree-sitter → real
/// `LineRowView`) colors a leading keyword for every bundled language we claim to
/// support, not just Swift. Each case is a valid top-level construct so the grammar
/// classifies its leading keyword; the assertion is "the token is NOT the base color"
/// (highlighted at all), independent of the exact capture name a grammar emits.
@MainActor
struct DiffSyntaxGrammarFidelityTests {
  struct Lang: CustomStringConvertible, Sendable {
    let name: String
    let path: String
    let line: String
    let probe: Int
    var description: String { name }
  }

  nonisolated static let languages: [Lang] = [
    Lang(name: "swift", path: "a.swift", line: "func greet() {}", probe: 1),
    Lang(name: "javascript", path: "a.js", line: "function greet() {}", probe: 1),
    Lang(name: "typescript", path: "a.ts", line: "interface Shape {}", probe: 1),
    Lang(name: "python", path: "a.py", line: "def greet(): pass", probe: 1),
    Lang(name: "go", path: "a.go", line: "package main", probe: 1),
    Lang(name: "ruby", path: "a.rb", line: "def greet; end", probe: 1),
    Lang(name: "rust", path: "a.rs", line: "fn main() {}", probe: 1),
    Lang(name: "c", path: "a.c", line: "void run() {}", probe: 1),
    Lang(name: "java", path: "a.java", line: "class Foo {}", probe: 1),
  ]

  @Test(arguments: languages)
  func everyBundledGrammarColorsItsLeadingKeyword(_ lang: Lang) async throws {
    let input = HighlightBlobInput(
      blobOID: "grammar-\(lang.name)", utf16: DiffFixture.blob(lang.line + "\n"), path: lang.path)
    let runs = await DiffHighlightClient.liveValue.styleRuns(input, 1..<2)
    #expect(!runs.values.flatMap { $0 }.isEmpty, "\(lang.name): the client produced no runs (grammar missing?)")

    let token = try #require(
      SyntaxRenderHarness.foreground(lang.line, lineNumber: 1, newRuns: runs, at: lang.probe),
      "\(lang.name): no foreground at the probed glyph")
    #expect(
      !CTRunColorProbe.sameColor(token, SyntaxRenderHarness.baseColor),
      "\(lang.name): \"\(lang.line)\" rendered the base color — this language does not highlight")
  }
}
