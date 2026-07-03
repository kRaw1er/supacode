import AppKit

/// Maps a tree-sitter capture name (`"keyword.control"`, `"string"`, …) to a
/// foreground `NSColor`. Per CLAUDE.md this is **system colors only** — no custom
/// hex — so the theme reads correctly in light and dark and honors accessibility
/// contrast settings for free.
///
/// Resolution is longest-prefix: a capture like `function.method` that has no
/// exact entry falls back to `function`, then to the default `labelColor`. Static
/// on a caseless `enum` (no top-level funcs / stored singletons).
enum HighlightTheme {
  /// Capture (or capture prefix) → system color. Ordered by how tree-sitter
  /// grammars name their captures; the resolver strips trailing `.segments` until
  /// it finds a match.
  static let map: [String: NSColor] = [
    "keyword": .systemPink,
    "string": .systemRed,
    "comment": .secondaryLabelColor,
    "number": .systemBlue,
    "boolean": .systemBlue,
    "constant": .systemPurple,
    "constant.builtin": .systemPurple,
    "function": .systemTeal,
    "type": .systemTeal,
    "constructor": .systemTeal,
    "variable.builtin": .systemPurple,
    "property": .labelColor,
    "attribute": .systemGreen,
    "tag": .systemGreen,
    "operator": .labelColor,
    "punctuation": .secondaryLabelColor,
    "label": .systemOrange,
    "escape": .systemOrange,
    "embedded": .labelColor,
  ]

  /// The color for a capture, resolving `a.b.c` → `a.b` → `a` → default.
  static func color(for capture: String) -> NSColor {
    var key = capture
    while true {
      if let color = map[key] { return color }
      guard let dot = key.lastIndex(of: ".") else { return .labelColor }
      key = String(key[key.startIndex..<dot])
    }
  }
}
