import Foundation
import TreeSitterGrammars

/// Resolves a file path to a bundled tree-sitter grammar (or `nil` ⇒ render plain,
/// no highlight actor is spun up). Owns the extension / filename → grammar map and
/// the plain-text fallback gate for unbundled, over-cap, or binary files.
///
/// Static-only on a caseless `enum` (no top-level funcs, per CLAUDE.md). Each
/// `Grammar.language` returns an `OpaquePointer` from the prebuilt
/// `TreeSitterGrammars` xcframework — exactly what `SwiftTreeSitter.Language(_:)`
/// accepts — so no tree-sitter runtime type crosses into Swift here.
enum GrammarRegistry {
  struct Grammar: Sendable {
    /// The `tree_sitter_<lang>()` C entry point, wrapped `@Sendable` so it can
    /// ride into the parsing actor.
    let language: @Sendable () -> OpaquePointer
    /// The `TreeSitterQueries/<queryName>/highlights.scm` resource subdirectory.
    let queryName: String
  }

  /// Above this byte count a file is treated as plain text (no whole-file parse) —
  /// mirrors the diff data layer's large-file cap (SpecFlow 2.8 / 7.6).
  static let byteCap = 2_000_000

  // MARK: - Grammar constructors

  private static let swift = Grammar(language: { tree_sitter_swift() }, queryName: "swift")
  private static let javascript = Grammar(language: { tree_sitter_javascript() }, queryName: "javascript")
  private static let typescript = Grammar(language: { tree_sitter_typescript() }, queryName: "typescript")
  private static let tsx = Grammar(language: { tree_sitter_tsx() }, queryName: "tsx")
  private static let python = Grammar(language: { tree_sitter_python() }, queryName: "python")
  private static let goLang = Grammar(language: { tree_sitter_go() }, queryName: "go")
  private static let rust = Grammar(language: { tree_sitter_rust() }, queryName: "rust")
  private static let cLang = Grammar(language: { tree_sitter_c() }, queryName: "c")
  private static let cpp = Grammar(language: { tree_sitter_cpp() }, queryName: "cpp")
  private static let csharp = Grammar(language: { tree_sitter_c_sharp() }, queryName: "csharp")
  private static let java = Grammar(language: { tree_sitter_java() }, queryName: "java")
  private static let ruby = Grammar(language: { tree_sitter_ruby() }, queryName: "ruby")
  private static let bash = Grammar(language: { tree_sitter_bash() }, queryName: "bash")
  private static let json = Grammar(language: { tree_sitter_json() }, queryName: "json")
  private static let css = Grammar(language: { tree_sitter_css() }, queryName: "css")
  private static let html = Grammar(language: { tree_sitter_html() }, queryName: "html")
  private static let php = Grammar(language: { tree_sitter_php() }, queryName: "php")
  private static let yaml = Grammar(language: { tree_sitter_yaml() }, queryName: "yaml")
  private static let toml = Grammar(language: { tree_sitter_toml() }, queryName: "toml")
  private static let markdown = Grammar(language: { tree_sitter_markdown() }, queryName: "markdown")
  private static let zig = Grammar(language: { tree_sitter_zig() }, queryName: "zig")
  private static let kotlin = Grammar(language: { tree_sitter_kotlin() }, queryName: "kotlin")
  private static let dockerfile = Grammar(language: { tree_sitter_dockerfile() }, queryName: "dockerfile")
  private static let make = Grammar(language: { tree_sitter_make() }, queryName: "make")

  // MARK: - Lookup tables

  /// Lowercased extension (no leading dot) → grammar.
  private static let byExtension: [String: Grammar] = [
    "swift": swift,
    "js": javascript, "mjs": javascript, "cjs": javascript, "jsx": javascript,
    "ts": typescript, "mts": typescript, "cts": typescript,
    "tsx": tsx,
    "py": python, "pyi": python, "pyw": python,
    "go": goLang,
    "rs": rust,
    "c": cLang, "h": cLang,
    "cc": cpp, "cpp": cpp, "cxx": cpp, "c++": cpp, "hpp": cpp, "hh": cpp, "hxx": cpp,
    "cs": csharp,
    "java": java,
    "rb": ruby, "rake": ruby, "gemspec": ruby,
    "sh": bash, "bash": bash, "zsh": bash,
    "json": json,
    "css": css,
    "html": html, "htm": html,
    "php": php,
    "yaml": yaml, "yml": yaml,
    "toml": toml,
    "md": markdown, "markdown": markdown,
    "zig": zig,
    "kt": kotlin, "kts": kotlin,
  ]

  /// Exact filename (no extension) → grammar.
  private static let byFilename: [String: Grammar] = [
    "Dockerfile": dockerfile,
    "Makefile": make,
    "GNUmakefile": make,
    "Gemfile": ruby,
    "Rakefile": ruby,
  ]

  /// Injected-language name → grammar. tree-sitter injection queries name the
  /// embedded language via `@injection.language` / `(#set! injection.language …)`
  /// (`QueryDefinitions.swift:87-108`); neon's `LanguageProvider` hands that name
  /// here to resolve the sublayer's config (e.g. `<script>` in HTML → `javascript`,
  /// `<style>` → `css`). Lowercased keys; only names whose target grammar is bundled
  /// resolve — an unbundled injection target returns `nil` (embedded region plain).
  private static let byInjectionName: [String: Grammar] = [
    "javascript": javascript, "js": javascript, "jsx": javascript,
    "typescript": typescript, "ts": typescript,
    "tsx": tsx,
    "css": css,
    "html": html,
    "python": python, "py": python,
    "go": goLang,
    "rust": rust, "rs": rust,
    "c": cLang,
    "cpp": cpp, "c++": cpp,
    "csharp": csharp, "c_sharp": csharp, "cs": csharp,
    "java": java,
    "ruby": ruby, "rb": ruby,
    "bash": bash, "sh": bash, "shell": bash, "zsh": bash,
    "json": json,
    "php": php,
    "yaml": yaml, "yml": yaml,
    "toml": toml,
    "markdown": markdown, "md": markdown,
    "zig": zig,
    "kotlin": kotlin, "kt": kotlin,
  ]

  // MARK: - API

  /// Every distinct bundled grammar, deduplicated by `queryName` (aliases like
  /// `js`/`mjs`/`jsx` collapse to one `javascript` entry). One entry per
  /// `treesitter-grammars.lock` line — the canonical set a build/ABI audit must
  /// touch exactly once. Sorted by `queryName` for deterministic iteration.
  static var allGrammars: [Grammar] {
    var byQueryName: [String: Grammar] = [:]
    for grammar in Array(byExtension.values) + Array(byFilename.values) {
      byQueryName[grammar.queryName] = grammar
    }
    return byQueryName.values.sorted { $0.queryName < $1.queryName }
  }

  /// Resolves a path to a grammar: exact filename special first, then extension.
  /// `nil` ⇒ no bundled grammar (caller renders plain text).
  static func grammar(forPath path: String) -> Grammar? {
    let name = (path as NSString).lastPathComponent
    if let special = byFilename[name] { return special }
    let ext = (name as NSString).pathExtension.lowercased()
    guard !ext.isEmpty else { return nil }
    return byExtension[ext]
  }

  /// Resolves an injected-language name (from an `injections.scm` query) to its
  /// bundled grammar — the `LanguageProvider` lookup neon calls to highlight an
  /// embedded region. `nil` ⇒ the target grammar isn't bundled (embedded region
  /// renders plain; the engine logs it, never silently pretends to highlight).
  static func grammar(forInjectionName name: String) -> Grammar? {
    byInjectionName[name.lowercased()]
  }

  /// The plain-text fallback gate: no bundled grammar, over the byte cap, or a
  /// binary file ⇒ skip highlighting entirely (SpecFlow 2.8 / 2.10 / 7.6).
  static func isPlainText(path: String, byteCount: Int, isBinary: Bool) -> Bool {
    if isBinary { return true }
    if byteCount > byteCap { return true }
    return grammar(forPath: path) == nil
  }
}
