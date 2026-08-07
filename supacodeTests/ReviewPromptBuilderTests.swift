import Foundation
import Testing

@testable import supacode

struct ReviewPromptBuilderTests {
  private func comment(
    file: String,
    start: Int,
    end: Int? = nil,
    snippet: String = "code",
    body: String,
    side: DiffSide = .new,
    orphaned: Bool = false
  ) -> ReviewComment {
    ReviewComment(
      id: UUID(),
      filePath: file,
      side: side,
      startLine: start,
      endLine: end ?? start,
      anchorSnippet: snippet,
      contextBefore: "",
      body: body,
      orphaned: orphaned,
      createdAt: Date(timeIntervalSince1970: 0)
    )
  }

  @Test func groupsByFileAlphabeticallyAndByStartLine() throws {
    let comments = [
      comment(file: "z.swift", start: 5, body: "last file"),
      comment(file: "a.swift", start: 20, body: "second in a"),
      comment(file: "a.swift", start: 3, body: "first in a"),
    ]
    let markdown = try #require(ReviewPromptBuilder.build(comments)).markdown

    let aHeader = try #require(markdown.range(of: "## a.swift"))
    let zHeader = try #require(markdown.range(of: "## z.swift"))
    // a.swift precedes z.swift.
    #expect(aHeader.lowerBound < zHeader.lowerBound)
    // Within a.swift, L3 precedes L20.
    let firstRange = try #require(markdown.range(of: "L3"))
    let secondRange = try #require(markdown.range(of: "L20"))
    #expect(firstRange.lowerBound < secondRange.lowerBound)
  }

  @Test func backtickHeavySnippetGetsUnbreakableFence() throws {
    // Snippet contains a triple-backtick run → fence must be ≥ 4 backticks.
    let snippet = "before ``` after"
    let markdown = try #require(
      ReviewPromptBuilder.build([comment(file: "a.swift", start: 1, snippet: snippet, body: "fix")])
    ).markdown
    #expect(markdown.contains("````"))
    // The fence strictly exceeds the max interior run (3) → block can't break early.
    #expect(!markdown.contains("\n```\n"))
  }

  @Test func emojiAndMultilineBodyRoundTrip() throws {
    let body = "First line 🚀\nSecond line ✅"
    let markdown = try #require(
      ReviewPromptBuilder.build([comment(file: "a.swift", start: 1, body: body)])
    ).markdown
    #expect(markdown.contains("🚀"))
    #expect(markdown.contains("✅"))
    #expect(markdown.contains("> First line 🚀"))
    #expect(markdown.contains("> Second line ✅"))
  }

  @Test func controlCharsStrippedFromBodyAndSnippet() throws {
    let body = "red \u{1b}[31mtext\u{202E}reversed"
    let snippet = "line\rwith cr"
    let markdown = try #require(
      ReviewPromptBuilder.build([comment(file: "a.swift", start: 1, snippet: snippet, body: body)])
    ).markdown
    #expect(!markdown.contains("\u{1b}"))
    #expect(!markdown.contains("\u{202E}"))
    #expect(!markdown.contains("\r"))
  }

  @Test func emptyBatchReturnsNil() {
    #expect(ReviewPromptBuilder.build([]) == nil)
  }

  @Test func allEmptyBodiesReturnNil() {
    let comments = [
      comment(file: "a.swift", start: 1, body: "   "),
      comment(file: "a.swift", start: 2, body: "\n\t"),
    ]
    #expect(ReviewPromptBuilder.build(comments) == nil)
  }

  @Test func oversizeInputFlagsWarningButStillProduces() throws {
    let big = String(repeating: "x", count: 200)
    let comments = (0..<60).map { comment(file: "a.swift", start: $0 + 1, body: big) }
    let output = try #require(ReviewPromptBuilder.build(comments))
    #expect(output.isOversize == true)
    #expect(!output.markdown.isEmpty)
  }

  @Test func oldSideRendersDeletionMarker() throws {
    let markdown = try #require(
      ReviewPromptBuilder.build([comment(file: "a.swift", start: 4, body: "gone", side: .old)])
    ).markdown
    #expect(markdown.contains("-L4"))
  }

  @Test func orphanedCommentIsAnnotated() throws {
    let markdown = try #require(
      ReviewPromptBuilder.build([comment(file: "a.swift", start: 4, body: "note", orphaned: true)])
    ).markdown
    #expect(markdown.contains("orphaned"))
  }
}
