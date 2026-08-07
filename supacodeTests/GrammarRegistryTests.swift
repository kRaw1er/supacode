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

  /// The 0.25 re-audit: the extension / alias / filename map must still reach every
  /// one of the 24 bundled grammars after the neon bump (extensions are our own
  /// mapping, unaffected by the tree-sitter version, but this locks the full set so
  /// a dropped entry surfaces). One representative path per lock `queryName`.
  @Test func grammarRegistryExtensions() {
    let expected: [String: String] = [
      "Sources/App.swift": "swift",
      "app.js": "javascript", "bundle.mjs": "javascript", "legacy.cjs": "javascript", "ui.jsx": "javascript",
      "index.ts": "typescript", "types.mts": "typescript", "types.cts": "typescript",
      "App.tsx": "tsx",
      "main.py": "python", "stub.pyi": "python", "script.pyw": "python",
      "cmd/main.go": "go",
      "lib.rs": "rust",
      "core.c": "c", "core.h": "c",
      "engine.cc": "cpp", "engine.cpp": "cpp", "engine.cxx": "cpp", "engine.hpp": "cpp",
      "Model.cs": "csharp",
      "Main.java": "java",
      "app.rb": "ruby", "tasks.rake": "ruby", "gem.gemspec": "ruby",
      "run.sh": "bash", "setup.bash": "bash", "prof.zsh": "bash",
      "data.json": "json",
      "styles.css": "css",
      "index.html": "html", "page.htm": "html",
      "index.php": "php",
      "config.yaml": "yaml", "ci.yml": "yaml",
      "Cargo.toml": "toml",
      "README.md": "markdown", "NOTES.markdown": "markdown",
      "build.zig": "zig",
      "Main.kt": "kotlin", "script.kts": "kotlin",
      "build/Dockerfile": "dockerfile",
      "Makefile": "make", "GNUmakefile": "make",
      "Gemfile": "ruby", "Rakefile": "ruby",
    ]
    for (path, queryName) in expected {
      #expect(
        GrammarRegistry.grammar(forPath: path)?.queryName == queryName,
        "path '\(path)' should resolve to '\(queryName)'")
    }
    // The deduped set is exactly the 24 lock entries, each reachable above.
    let reached = Set(expected.values)
    #expect(reached.count == 24)
    #expect(Set(GrammarRegistry.allGrammars.map(\.queryName)) == reached)
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
