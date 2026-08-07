import Foundation
import Testing

@testable import supacode

/// Phase 7 — `BlobSliceProvider` / `BlobLineTable`. Reveals hidden unchanged lines
/// by reading the git blob for a file's NEW side — NEVER a `git_diff_*`. Real
/// temp-git repos via `GitFixture`; the DiffSource matrix (`.workingTree` +
/// `.baseBranch`). Serialized (shells `/usr/bin/git`).
@Suite(.serialized)
struct BlobSliceProviderTests {

  private func file(_ path: String) -> FileChange {
    FileChange(
      oldPath: path, newPath: path, status: .modified, addedLines: 0, removedLines: 0,
      isBinary: false, isLargeFileCapped: false, hasLongLines: false, similarity: 0)
  }

  // MARK: - 9.6 line-start table + range slice (both sources) + oldLineDelta property

  @Test func blobSliceLineStartTableAndRange() async throws {
    let repo = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(repo) }
    let content = (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n"
    try GitFixture.write(content, to: "a.txt", in: repo)
    try GitFixture.stage("a.txt", in: repo)
    try GitFixture.commit("add a", in: repo)

    let target = file("a.txt")
    let provider = BlobSliceProvider()

    // The DiffSource matrix: on-disk post-image AND HEAD's committed tree blob.
    for source in [DiffSource.workingTree, .baseBranch(ref: "main")] {
      let sliced = try await provider.slice(
        file: target, worktreeURL: repo, source: source, newLineRange: 3..<7, oldLineDelta: 0)
      #expect(sliced.count == 4)
      #expect(sliced.map(\.newLineNumber) == [3, 4, 5, 6])  // contiguous, matches declared range
      #expect(sliced.map(\.oldLineNumber) == [3, 4, 5, 6])  // old = new + delta(0), lockstep
      #expect(sliced.map(\.content) == ["line3", "line4", "line5", "line6"])
      #expect(sliced.allSatisfy { $0.origin == .context })
      #expect(sliced.allSatisfy { !$0.noNewlineAtEof })
    }

    // oldLineDelta off-by-one property: `old = new + delta` for a non-zero delta.
    let shifted = try await provider.slice(
      file: target, worktreeURL: repo, source: .workingTree, newLineRange: 5..<8, oldLineDelta: -2)
    #expect(shifted.map(\.newLineNumber) == [5, 6, 7])
    #expect(shifted.map(\.oldLineNumber) == [3, 4, 5])  // old = new - 2
  }

  // MARK: - 9.7 the provider reads the blob only — never `git_diff_*`

  @Test func blobSliceNeverCallsGitDiff() async throws {
    let repo = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(repo) }
    let content = (1...5).map { "x\($0)" }.joined(separator: "\n") + "\n"
    try GitFixture.write(content, to: "clean.txt", in: repo)
    try GitFixture.stage("clean.txt", in: repo)
    try GitFixture.commit("clean", in: repo)

    // The working tree is CLEAN — `git diff` for this file returns NOTHING.
    let provider = BlobSliceProvider()
    let sliced = try await provider.slice(
      file: file("clean.txt"), worktreeURL: repo, source: .workingTree, newLineRange: 1..<4, oldLineDelta: 0)
    // Slicing STILL returns the lines → proof it reads the blob directly, not a diff.
    #expect(sliced.map(\.content) == ["x1", "x2", "x3"])
    let diagnostics = await provider.diagnostics
    #expect(diagnostics.diffBuilds == 0)  // never builds a git_diff
    #expect(diagnostics.blobReads == 1)  // read the blob once
  }

  // MARK: - A §2 plain-file line iteration semantics (in the line-start table)

  @Test func plainFileLineIterationSemantics() {
    // Trailing newline is collapsed: "l1\nl2\nl3\n" is 3 lines, not 4.
    let trailing = BlobLineTable.build(utf16: Array("l1\nl2\nl3\n".utf16))
    #expect(trailing.lineCount == 3)
    #expect(trailing.content(line: 3) == "l3")

    // No trailing newline: the same 3 lines, the last is the final content.
    let noTrailing = BlobLineTable.build(utf16: Array("l1\nl2\nl3".utf16))
    #expect(noTrailing.lineCount == 3)
    #expect(noTrailing.content(line: 3) == "l3")

    // Single-line file → 1 line; empty file → 0 lines.
    let single = BlobLineTable.build(utf16: Array("only line".utf16))
    #expect(single.lineCount == 1)
    #expect(single.content(line: 1) == "only line")
    #expect(BlobLineTable.build(utf16: []).lineCount == 0)

    // `\r\n` line endings strip the `\r` from the content.
    let crlf = BlobLineTable.build(utf16: Array("a\r\nb\r\n".utf16))
    #expect(crlf.lineCount == 2)
    #expect(crlf.content(line: 1) == "a")
    #expect(crlf.content(line: 2) == "b")

    // A window past EOF returns only the in-range lines (no crash, no empty rows).
    let past = BlobSliceProvider.slice(trailing, newLineRange: 2..<10, oldLineDelta: 0)
    #expect(past.map(\.newLineNumber) == [2, 3])
    #expect(past.map(\.content) == ["l2", "l3"])
    // A window entirely past EOF is empty.
    #expect(BlobSliceProvider.slice(trailing, newLineRange: 10..<20, oldLineDelta: 0).isEmpty)
    // A zero / negative lower bound clamps to line 1.
    #expect(BlobSliceProvider.slice(trailing, newLineRange: 0..<2, oldLineDelta: 0).map(\.newLineNumber) == [1])
  }

  // MARK: - D I5 an expanded region's first/last line begins/ends at a line-start entry

  @Test func expanderBoundaryOnLineStarts() {
    // Unicode content — a `\n` can never fall inside a grapheme cluster, so a
    // whole-line collapse/expand is inherently grapheme-safe.
    let text = "héllo\nwörld\n😀line\ntail"
    let table = BlobLineTable.build(utf16: Array(text.utf16))
    #expect(table.lineCount == 4)

    let region = BlobSliceProvider.slice(table, newLineRange: 2..<4, oldLineDelta: 0)
    #expect(region.count == 2)

    // The first materialized line begins exactly at `lineStarts[1]` (line 2) and its
    // content is the raw UTF-16 slice `[lineStarts[1], lineEnds[1])`.
    let firstStart = table.lineStarts[1]
    let firstEnd = table.lineEnds[1]
    let reconstructed = String(decoding: table.utf16[firstStart..<firstEnd], as: UTF16.self)
    #expect(region.first?.content == reconstructed)
    #expect(region.first?.content == table.content(line: 2))

    // The emoji line round-trips intact — the boundary landed on a line start, not
    // inside the cluster.
    let emoji = BlobSliceProvider.slice(table, newLineRange: 3..<4, oldLineDelta: 0)
    #expect(emoji.first?.content == "😀line")
    #expect(emoji.first.map { table.utf16[table.lineStarts[2]] == Array($0.content.utf16)[0] } == true)
  }

  // MARK: - B §23 partial resolve stays lazy — no materializing the collapsed context

  @Test func partialPatchResolutionStaysPartial() async throws {
    let repo = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(repo) }
    let content = (1...500).map { "row\($0)" }.joined(separator: "\n") + "\n"
    try GitFixture.write(content, to: "big.txt", in: repo)
    try GitFixture.stage("big.txt", in: repo)
    try GitFixture.commit("big", in: repo)

    let provider = BlobSliceProvider()
    // A partial reveal slices ONLY the requested 5-line window — NOT the 500-line file.
    let sliced = try await provider.slice(
      file: file("big.txt"), worktreeURL: repo, source: .workingTree, newLineRange: 100..<105, oldLineDelta: 0)
    #expect(sliced.count == 5)
    #expect(sliced.map(\.content) == ["row100", "row101", "row102", "row103", "row104"])

    // A second slice of a different window reuses the cached table — O(range), NOT a
    // second O(fileLen) decode.
    _ = try await provider.slice(
      file: file("big.txt"), worktreeURL: repo, source: .workingTree, newLineRange: 200..<203, oldLineDelta: 0)
    let diagnostics = await provider.diagnostics
    #expect(diagnostics.blobReads == 1)  // built the line table once
    #expect(diagnostics.cacheHits == 1)  // the second slice reused it
  }
}
