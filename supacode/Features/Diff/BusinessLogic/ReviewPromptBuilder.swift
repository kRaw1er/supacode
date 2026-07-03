import Foundation

/// Serializes a batch of review comments into the structured Markdown prompt
/// injected into the agent's terminal. Pure, deterministic, and injection-safe:
/// file content is treated as data (only ever quoted inside a length-adaptive
/// fence) and all control characters are stripped (5.10 / 5.11). Static-only on
/// a caseless enum (no free funcs).
enum ReviewPromptBuilder {
  struct Output: Equatable {
    let markdown: String
    let isOversize: Bool
  }

  /// Chars above which the send button shows a non-blocking "large prompt"
  /// caption. A warning, never a gate (5.8).
  static let sizeWarningThreshold = 8_000

  /// Builds the prompt, or returns `nil` when every comment has an empty body
  /// (an empty batch never sends — 5.5).
  static func build(_ comments: [ReviewComment], sizeWarningThreshold: Int = sizeWarningThreshold) -> Output? {
    // 1. Drop empty (whitespace-only) bodies; an empty composer never contributes.
    let effective = comments.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    guard !effective.isEmpty else { return nil }

    // 3. Group by file (alphabetical), comments within a file by start line.
    let grouped = Dictionary(grouping: effective, by: \.filePath)
    let files = grouped.keys.sorted()

    var markdown = "Review comments on your changes:\n"
    for file in files {
      markdown += "\n## \(file)\n"
      let sorted = (grouped[file] ?? []).sorted { $0.startLine < $1.startLine }
      for comment in sorted {
        markdown += "\n\(commentBlock(comment))"
      }
    }
    markdown += "\nPlease address these.\n"

    return Output(markdown: markdown, isOversize: markdown.count > sizeWarningThreshold)
  }

  // MARK: - Rendering

  private static func commentBlock(_ comment: ReviewComment) -> String {
    let range =
      comment.startLine == comment.endLine ? "\(comment.startLine)" : "\(comment.startLine)–\(comment.endLine)"
    let sideMarker = comment.side == .old ? "-L" : "L"
    let orphanSuffix = comment.orphaned ? " (orphaned — original line no longer present)" : ""

    let snippet = sanitizeControlChars(comment.anchorSnippet)
    let fence = String(repeating: "`", count: fenceLength(for: snippet))
    let body = sanitizeControlChars(comment.body)
    let quotedBody =
      body
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { "> \($0)" }
      .joined(separator: "\n")

    return """
      — \(sideMarker)\(range)\(orphanSuffix):
      \(fence)
      \(snippet)
      \(fence)
      \(quotedBody)

      """
  }

  /// 5.11 — the fence is always at least one backtick longer than the longest
  /// consecutive-backtick run inside the snippet, so a backtick-heavy snippet
  /// can never terminate the block early. Computed per block.
  private static func fenceLength(for snippet: String) -> Int {
    max(3, longestBacktickRun(in: snippet) + 1)
  }

  private static func longestBacktickRun(in text: String) -> Int {
    var longest = 0
    var current = 0
    for character in text {
      if character == "`" {
        current += 1
        longest = max(longest, current)
      } else {
        current = 0
      }
    }
    return longest
  }

  // MARK: - Sanitize (5.10)

  /// Strips C0 controls (except `\n` / `\t`), `\r`, and bidi / zero-width
  /// overrides so a pasted snippet or body can't inject an ANSI/OSC escape into
  /// the PTY. This is the sole reason file content is safe to inject.
  static func sanitizeControlChars(_ text: String) -> String {
    var result = String()
    result.reserveCapacity(text.count)
    for scalar in text.unicodeScalars {
      if scalar == "\n" || scalar == "\t" {
        result.unicodeScalars.append(scalar)
        continue
      }
      // C0 controls (includes \r via 0x0D) and DEL.
      if scalar.value < 0x20 || scalar.value == 0x7F { continue }
      // Bidi overrides / isolates and zero-width space.
      if (0x202A...0x202E).contains(scalar.value)
        || (0x2066...0x2069).contains(scalar.value)
        || scalar.value == 0x200B
      {
        continue
      }
      result.unicodeScalars.append(scalar)
    }
    return result
  }
}
