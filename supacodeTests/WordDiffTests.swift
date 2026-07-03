import Foundation
import Testing

@testable import supacode

/// Unit coverage for the pure intra-line `WordDiff`. UTF-16 char offsets, caps,
/// and mode-agnostic pairing (SpecFlow 6.3 / 7.5).
struct WordDiffTests {
  @Test func singleTokenSubstitution() {
    let result = WordDiff.diff(old: "foo(1)", new: "foo(2)")
    // Only the `1` / `2` differ.
    #expect(result.oldSpans == [WordDiff.Span(range: 4..<5)])
    #expect(result.newSpans == [WordDiff.Span(range: 4..<5)])
  }

  @Test func multiTokenEdit() {
    let result = WordDiff.diff(old: "let x = a + b", new: "let x = a - c")
    // `+`→`-` (offset 10) and `b`→`c` (offset 12); untouched identifiers excluded.
    #expect(result.oldSpans == [WordDiff.Span(range: 10..<11), WordDiff.Span(range: 12..<13)])
    #expect(result.newSpans == [WordDiff.Span(range: 10..<11), WordDiff.Span(range: 12..<13)])
  }

  @Test func pureInsertion() {
    let result = WordDiff.diff(old: "f(a)", new: "f(a, b)")
    #expect(result.oldSpans.isEmpty)
    // The inserted `, b` is one contiguous merged span.
    #expect(result.newSpans == [WordDiff.Span(range: 3..<6)])
  }

  @Test func identicalLinesAreEmpty() {
    let result = WordDiff.diff(old: "let x = 1", new: "let x = 1")
    #expect(result == .empty)
  }

  @Test func longLineCapReturnsEmpty() {
    let old = String(repeating: "a", count: WordDiff.maxLineLength + 1)
    let new = String(repeating: "b", count: WordDiff.maxLineLength + 1)
    #expect(WordDiff.diff(old: old, new: new) == .empty)
  }

  @Test func tokenCountCapReturnsEmpty() {
    // Each `.` is its own punctuation token; > maxTokens ⇒ skipped.
    let old = String(repeating: ".", count: WordDiff.maxTokens + 10)
    let new = String(repeating: ".", count: WordDiff.maxTokens + 5)
    #expect(WordDiff.diff(old: old, new: new) == .empty)
  }

  @Test func unifiedAndSplitUseIdenticalSpans() {
    // The diff takes one (old, new) pair, so unified and split callers consume the
    // exact same result — split routes oldSpans→left / newSpans→right, unified
    // routes oldSpans→`-` / newSpans→`+`. Same spans either way.
    let pair = ("value = compute(a)", "value = compute(b)")
    let asUnified = WordDiff.diff(old: pair.0, new: pair.1)
    let asSplit = WordDiff.diff(old: pair.0, new: pair.1)
    #expect(asUnified == asSplit)
    #expect(!asUnified.oldSpans.isEmpty)
    #expect(!asUnified.newSpans.isEmpty)
  }

  @Test func unicodeScalarBoundariesDoNotCrash() {
    let result = WordDiff.diff(old: "café", new: "cafe")
    // Each side is a single identifier token spanning the four scalars.
    #expect(result.oldSpans == [WordDiff.Span(range: 0..<4)])
    #expect(result.newSpans == [WordDiff.Span(range: 0..<4)])
  }
}
