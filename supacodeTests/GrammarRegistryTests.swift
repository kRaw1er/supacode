import Foundation
import Testing

@testable import supacode

/// Unit coverage for the extension / filename → grammar mapping and the
/// plain-text fallback gate. Asserts on the resolved `queryName` (the grammar's
/// bundled query subdirectory) rather than the opaque C function pointer.
struct GrammarRegistryTests {
  @Test func knownExtensionsResolveToGrammars() {
    #expect(GrammarRegistry.grammar(forPath: "Sources/App.swift")?.queryName == "swift")
    #expect(GrammarRegistry.grammar(forPath: "src/index.ts")?.queryName == "typescript")
    #expect(GrammarRegistry.grammar(forPath: "src/App.tsx")?.queryName == "tsx")
    #expect(GrammarRegistry.grammar(forPath: "main.py")?.queryName == "python")
    #expect(GrammarRegistry.grammar(forPath: "cmd/main.go")?.queryName == "go")
    #expect(GrammarRegistry.grammar(forPath: "lib.rs")?.queryName == "rust")
  }

  @Test func javascriptAliasesMapToJavascript() {
    #expect(GrammarRegistry.grammar(forPath: "bundle.mjs")?.queryName == "javascript")
    #expect(GrammarRegistry.grammar(forPath: "legacy.cjs")?.queryName == "javascript")
    #expect(GrammarRegistry.grammar(forPath: "app.jsx")?.queryName == "javascript")
  }

  @Test func filenameSpecialsResolve() {
    #expect(GrammarRegistry.grammar(forPath: "build/Dockerfile")?.queryName == "dockerfile")
    #expect(GrammarRegistry.grammar(forPath: "Makefile")?.queryName == "make")
  }

  @Test func unknownExtensionFallsBackToPlain() {
    #expect(GrammarRegistry.grammar(forPath: "notes.xyz") == nil)
    #expect(GrammarRegistry.grammar(forPath: "no-extension-file") == nil)
  }

  @Test func isPlainTextGatesUnbundledOverCapAndBinary() {
    // A normal, known, in-cap file highlights.
    #expect(GrammarRegistry.isPlainText(path: "App.swift", byteCount: 1_000, isBinary: false) == false)
    // Binary short-circuits regardless of extension.
    #expect(GrammarRegistry.isPlainText(path: "App.swift", byteCount: 1_000, isBinary: true) == true)
    // Over the byte cap falls back to plain.
    #expect(
      GrammarRegistry.isPlainText(path: "App.swift", byteCount: GrammarRegistry.byteCap + 1, isBinary: false) == true
    )
    // Unbundled extension falls back to plain.
    #expect(GrammarRegistry.isPlainText(path: "notes.xyz", byteCount: 10, isBinary: false) == true)
  }
}
