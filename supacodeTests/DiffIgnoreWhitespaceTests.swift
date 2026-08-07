import Foundation
import Testing

@testable import supacode

/// Backfill mirroring pierre `parseDiffFromFile.test.ts` "ignoreWhitespace hides
/// leading/trailing whitespace changes": a whitespace-only edit is a real hunk normally
/// and produces ZERO hunks under the ignore-whitespace option, while a genuine content
/// change in the same file still surfaces.
///
/// Driven against a REAL temp git repo (`GitFixture`) at the streaming-walk seam —
/// `Libgit2Diff.WalkRequest.ignoreWhitespace` (threaded to `GIT_DIFF_IGNORE_WHITESPACE`).
/// The flag is now ALSO plumbed end to end through `DiffProvider.diff` / `.stream` →
/// `DiffClient` → the reducer's ignore-whitespace toggle (see `DiffClientTests`
/// `ignoreWhitespaceThreadedThroughDiffPath` + `DiffReviewFeatureTests`); this suite keeps
/// the low-level walk coverage.
@Suite(.serialized)
struct DiffIgnoreWhitespaceTests {
  private static let caps = Libgit2Diff.Caps(byteCap: 8 * 1024 * 1024, lineCap: 50_000, longLineCap: 2_000)

  /// The hunks for `id` in the working-tree diff, or `nil` when the delta is absent
  /// (e.g. hidden entirely by ignore-whitespace).
  private func hunks(root: URL, id: String, ignoreWhitespace: Bool) throws -> [DiffHunk]? {
    Libgit2Diff.initialize()
    var found: FileDiffBatch?
    let request = Libgit2Diff.WalkRequest(
      source: .workingTree, caps: Self.caps, contextLines: 3, generation: 1, ignoreWhitespace: ignoreWhitespace)
    try Libgit2Diff.streamChangedFiles(
      at: root, request, isCancelled: { false },
      emit: { event in
        if case .fileReady(let batch) = event, batch.file.id == id { found = batch }
      })
    return found?.hunks
  }

  /// Pierre's exact scenario: re-indent the first line only (leading whitespace). Without
  /// the flag it is a real hunk; with the flag the change vanishes → zero hunks.
  @Test func leadingWhitespaceOnlyChangeHiddenByIgnoreWhitespace() throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("hello world\nfoo bar\n", to: "indent.txt", in: root)
    try GitFixture.stage("indent.txt", in: root)
    try GitFixture.commit("init", in: root)
    try GitFixture.write("  hello world\nfoo bar\n", to: "indent.txt", in: root)  // indentation only

    let plain = try hunks(root: root, id: "indent.txt", ignoreWhitespace: false)
    #expect(!(plain?.isEmpty ?? true))  // non-empty without the flag

    let ignored = try hunks(root: root, id: "indent.txt", ignoreWhitespace: true)
    #expect((ignored ?? []).isEmpty)  // ZERO hunks with the flag
  }

  /// Trailing-whitespace-only edit, single file — the other half of pierre's
  /// "leading/trailing" invariant.
  @Test func trailingWhitespaceOnlyChangeHiddenByIgnoreWhitespace() throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("alpha\nbeta\n", to: "trail.txt", in: root)
    try GitFixture.stage("trail.txt", in: root)
    try GitFixture.commit("init", in: root)
    try GitFixture.write("alpha  \nbeta\n", to: "trail.txt", in: root)  // trailing spaces only

    #expect(!((try hunks(root: root, id: "trail.txt", ignoreWhitespace: false))?.isEmpty ?? true))
    #expect(((try hunks(root: root, id: "trail.txt", ignoreWhitespace: true)) ?? []).isEmpty)
  }

  /// A file mixing a whitespace-only line change with a genuine content change: under the
  /// flag the whitespace edit is suppressed but the real change still yields a hunk, and
  /// the parsed counts stay internally consistent (a distinct case from the existing
  /// separate-files coverage in `DiffStreamTests`).
  @Test func realChangeSurvivesIgnoreWhitespaceInSameFile() throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("alpha\nbeta\ngamma\n", to: "mix.txt", in: root)
    try GitFixture.stage("mix.txt", in: root)
    try GitFixture.commit("init", in: root)
    // beta → trailing whitespace only; gamma → GAMMA (a real content change).
    try GitFixture.write("alpha\nbeta  \nGAMMA\n", to: "mix.txt", in: root)

    let ignored = try #require(try hunks(root: root, id: "mix.txt", ignoreWhitespace: true))
    #expect(!ignored.isEmpty)
    #expect(ChunkTreeBuilder.verifyHunkLineValues(ignored).isEmpty)

    let lines = ignored.flatMap(\.lines)
    // The real gamma → GAMMA change is present as a delete + add.
    #expect(lines.contains { $0.origin == .deletion && $0.content == "gamma" })
    #expect(lines.contains { $0.origin == .addition && $0.content == "GAMMA" })
    // The whitespace-only beta change did NOT surface as an add/delete.
    #expect(!lines.contains { $0.origin == .addition && $0.content == "beta  " })
    #expect(!lines.contains { $0.origin == .deletion && $0.content == "beta" })
  }
}
