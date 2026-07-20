import Foundation
import Testing

@testable import supacode

/// EOF-adjacent line-table edge cases for `BlobLineTable` — the reveal-slice line
/// numbering near a file's trailing newline(s). Mirrors the INVARIANT behind pierre
/// `iterateOverFile.test.ts` "last new line is not iterated over": interior blank
/// lines are retained; only the phantom line AFTER the final newline is not a row.
///
/// GIT-ALIGNMENT (why our count is not literally pierre's iteration count). Pierre's
/// `iterateOverFile` is a full-file VIEW render and drops the last bare `\n` entry, so
/// it renders 4 lines for `"l1\nl2\nl3\n\n\n"`. `BlobLineTable` is instead the
/// git-line-numbered reveal table: `slice` maps a `newLineNumber` (a git line number)
/// to its content, so `lineCount` MUST equal git's own line count. Verified against
/// git: `"l1\nl2\nl3\n\n\n"` is `@@ -1,5` (5 lines, the trailing blank is git line 5);
/// `"l1\nl2\nl3\n\n"` is 4; single/no trailing newline is 3. Matching git — not
/// pierre's view iteration — is what keeps EOF-adjacent revealed lines correctly
/// numbered (an off-by-one here misnumbers revealed context near EOF).
struct BlobLineTableEdgeTests {

  private func table(_ text: String) -> BlobLineTable {
    BlobLineTable.build(utf16: Array(text.utf16))
  }

  /// Multiple trailing newlines: every interior blank is retained and only the phantom
  /// line after the FINAL newline is collapsed. `"l1\nl2\nl3\n\n\n"` → 5 git lines
  /// (`l1`, `l2`, `l3`, ``, ``) — NOT pierre's view-render count of 4, and NOT a
  /// collapse of all trailing blanks.
  @Test func multiTrailingNewlinesRetainInteriorBlanks() {
    let multi = table("l1\nl2\nl3\n\n\n")
    #expect(multi.lineCount == 5)  // matches git `@@ -1,5`
    #expect(multi.content(line: 1) == "l1")
    #expect(multi.content(line: 2) == "l2")
    #expect(multi.content(line: 3) == "l3")
    #expect(multi.content(line: 4) == "")  // interior blank retained
    #expect(multi.content(line: 5) == "")  // last real (blank) line retained
    // Only the phantom line AFTER the final newline is not a row.
    #expect(multi.content(line: 6) == "")  // out of range → empty, no line 6
  }

  /// Two trailing newlines → one blank line survives (the phantom after the final
  /// newline is dropped). Git line count 4.
  @Test func twoTrailingNewlinesRetainOneBlank() {
    let two = table("l1\nl2\nl3\n\n")
    #expect(two.lineCount == 4)  // matches git line count
    #expect(two.content(line: 3) == "l3")
    #expect(two.content(line: 4) == "")  // the single trailing blank is a real row
    #expect(two.content(line: 5) == "")  // no phantom line 5
  }

  /// Contrast — a SINGLE trailing newline collapses ONLY the phantom (no trailing blank
  /// row): `"l1\nl2\nl3\n"` is 3 lines, not 4.
  @Test func singleTrailingNewlineCollapsesPhantomOnly() {
    let single = table("l1\nl2\nl3\n")
    #expect(single.lineCount == 3)
    #expect(single.content(line: 3) == "l3")
    #expect(single.content(line: 4) == "")  // no phantom trailing-blank row
  }

  /// Contrast — no trailing newline: the final content is the last line, 3 lines.
  @Test func noTrailingNewlineKeepsFinalContent() {
    let none = table("l1\nl2\nl3")
    #expect(none.lineCount == 3)
    #expect(none.content(line: 3) == "l3")
  }

  /// An INTERIOR blank line (not at EOF) is always a real row regardless of trailing
  /// handling — the "only the LAST newline is skipped" half of the pierre invariant.
  @Test func interiorBlankLineIsARow() {
    let interior = table("l1\n\nl3\n")
    #expect(interior.lineCount == 3)
    #expect(interior.content(line: 1) == "l1")
    #expect(interior.content(line: 2) == "")  // interior blank retained as its own row
    #expect(interior.content(line: 3) == "l3")
  }

  /// The reveal off-by-one guard: slicing a window that spans the trailing blank lines
  /// numbers them by their git line number and never invents a phantom line past EOF.
  /// This is the concrete failure the edge case protects — misnumbered revealed lines
  /// near EOF.
  @Test func sliceAcrossTrailingBlanksIsGitNumbered() {
    let multi = table("l1\nl2\nl3\n\n\n")  // 5 git lines: l1, l2, l3, "", ""

    // A window covering `l3` and the two trailing blanks → exact git numbers 3, 4, 5.
    let acrossEOF = BlobSliceProvider.slice(multi, newLineRange: 3..<6, oldLineDelta: 0)
    #expect(acrossEOF.map(\.newLineNumber) == [3, 4, 5])
    #expect(acrossEOF.map(\.content) == ["l3", "", ""])
    #expect(acrossEOF.allSatisfy { $0.origin == .context })

    // A window running PAST EOF clamps at the last real line — no phantom line 6.
    let pastEOF = BlobSliceProvider.slice(multi, newLineRange: 4..<10, oldLineDelta: 0)
    #expect(pastEOF.map(\.newLineNumber) == [4, 5])
    #expect(pastEOF.map(\.content) == ["", ""])
  }
}
