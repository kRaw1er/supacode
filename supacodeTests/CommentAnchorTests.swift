import Foundation
import Testing

@testable import supacode

struct CommentAnchorTests {
  // MARK: - Fixtures

  private func newLine(_ number: Int, _ content: String, origin: DiffLineOrigin = .context) -> DiffLine {
    DiffLine(origin: origin, oldLineNumber: nil, newLineNumber: number, content: content, noNewlineAtEof: false)
  }

  private func comment(
    start: Int,
    end: Int,
    snippet: String,
    context: String = "",
    side: DiffSide = .new,
    orphaned: Bool = false
  ) -> ReviewComment {
    ReviewComment(
      id: UUID(),
      filePath: "a.swift",
      side: side,
      startLine: start,
      endLine: end,
      anchorSnippet: snippet,
      contextBefore: context,
      body: "note",
      orphaned: orphaned,
      createdAt: Date(timeIntervalSince1970: 0)
    )
  }

  // MARK: - Tests

  @Test func anchorSurvivesInsertionAbove() {
    // Comment on "target" at line 3; agent inserts 2 lines above → now line 5.
    let original = comment(start: 3, end: 3, snippet: "target")
    let lines = [
      newLine(1, "inserted a"),
      newLine(2, "inserted b"),
      newLine(3, "one"),
      newLine(4, "two"),
      newLine(5, "target"),
    ]
    let relocated = CommentAnchor.relocate(original, in: lines, side: .new)
    #expect(relocated.startLine == 5)
    #expect(relocated.endLine == 5)
    #expect(relocated.orphaned == false)
  }

  @Test func duplicatedSnippetPicksClosestToOldLine() {
    // "dup" appears at lines 2 and 8; the comment was at line 7 → pick line 8.
    let original = comment(start: 7, end: 7, snippet: "dup")
    let lines = [
      newLine(1, "x"),
      newLine(2, "dup"),
      newLine(3, "y"),
      newLine(4, "z"),
      newLine(5, "p"),
      newLine(6, "q"),
      newLine(7, "r"),
      newLine(8, "dup"),
    ]
    let relocated = CommentAnchor.relocate(original, in: lines, side: .new)
    #expect(relocated.startLine == 8)
    #expect(relocated.orphaned == false)
  }

  @Test func contextDisambiguatesIdenticalSnippet() {
    // Identical "same" at lines 2 and 5; context "beta" picks the second.
    let original = comment(start: 5, end: 5, snippet: "same", context: "beta")
    let lines = [
      newLine(1, "alpha"),
      newLine(2, "same"),
      newLine(3, "mid"),
      newLine(4, "beta"),
      newLine(5, "same"),
    ]
    let relocated = CommentAnchor.relocate(original, in: lines, side: .new)
    #expect(relocated.startLine == 5)
  }

  @Test func removedLineOrphansWithoutDropping() {
    let original = comment(start: 3, end: 3, snippet: "gone")
    let lines = [
      newLine(1, "one"),
      newLine(2, "two"),
      newLine(3, "three"),
    ]
    let relocated = CommentAnchor.relocate(original, in: lines, side: .new)
    #expect(relocated.orphaned == true)
    // Range left intact; the comment still exists (not deleted).
    #expect(relocated.startLine == 3)
    #expect(relocated.endLine == 3)
    #expect(relocated.id == original.id)
  }

  @Test func orphanUnOrphansWhenSnippetReturns() {
    let original = comment(start: 3, end: 3, snippet: "restored", orphaned: true)
    let lines = [
      newLine(1, "one"),
      newLine(2, "restored"),
      newLine(3, "three"),
    ]
    let relocated = CommentAnchor.relocate(original, in: lines, side: .new)
    #expect(relocated.orphaned == false)
    #expect(relocated.startLine == 2)
  }

  @Test func multiLineRangeClampsAtHunkBoundary() {
    // Snippet "a\nb\nc" but the new lines are non-contiguous (3,4 then jump to 9).
    let original = comment(start: 3, end: 5, snippet: "a\nb\nc")
    let lines = [
      newLine(3, "a"),
      newLine(4, "b"),
      newLine(9, "c"),
    ]
    let relocated = CommentAnchor.relocate(original, in: lines, side: .new)
    #expect(relocated.startLine == 3)
    // Clamp to the last contiguous line (4), never spanning the 4→9 gap.
    #expect(relocated.endLine == 4)
    #expect(relocated.orphaned == false)
  }
}
