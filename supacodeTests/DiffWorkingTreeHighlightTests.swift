import AppKit
import CoreText
import Foundation
import Testing

@testable import supacode

/// CAT 0 — the LIVE-app regression guard the headless keystone could not see: a
/// WORKING-TREE diff (uncommitted changes — exactly what the review panel shows) had
/// a NIL new-side blob (`new_file.id` is a zero OID; the content is on disk, not in
/// the object DB), so the new (right) side — context + additions, i.e. most of what
/// you see — never highlighted. `Libgit2Diff.workdirBlobUTF16` now reads the workdir
/// file, so the new side has grammar input. This drives the REAL streaming walk over
/// a REAL temp git repo into the REAL highlight client and asserts the new side is
/// both decoded AND rendered in color.
@Suite(.serialized)
@MainActor
struct DiffWorkingTreeHighlightTests {
  private static let caps = Libgit2Diff.Caps(byteCap: 8 * 1024 * 1024, lineCap: 50_000, longLineCap: 2_000)

  private func workingTreeBatch(for path: String, in root: URL) throws -> FileDiffBatch {
    Libgit2Diff.initialize()
    var batches: [FileDiffBatch] = []
    let request = Libgit2Diff.WalkRequest(
      source: .workingTree, caps: Self.caps, contextLines: 3, generation: 1, ignoreWhitespace: false)
    try Libgit2Diff.streamChangedFiles(
      at: root, request, isCancelled: { false },
      emit: { event in
        if case .fileReady(let batch) = event { batches.append(batch) }
      })
    return try #require(batches.first { $0.file.id == path }, "no working-tree batch for \(path)")
  }

  /// The base foreground a plain glyph renders — the "white" everything collapsed to.
  private func renderedTokenColor(_ content: String, newLineNumber: Int, runs: [Int: [StyleRun]], offset: Int)
    throws -> (token: CGColor, base: CGColor)
  {
    let segment = LineSegment(
      hunkID: HunkID(fileID: "f", index: 0),
      lines: [
        DiffLine(
          origin: .context, oldLineNumber: newLineNumber, newLineNumber: newLineNumber, content: content,
          noNewlineAtEof: false)
      ],
      window: 0..<1,
      classification: .context)
    let view = LineRowView()
    view.configure(
      segment: segment,
      chunkID: ChunkID(raw: UInt64(newLineNumber)),
      context: LineRowRenderContext(
        metrics: .resolve(), rowHeight: ChunkLayoutMetrics.production.lineHeight, mode: .unified, width: 4000,
        cache: CTLineCache(), palette: .shared, styleGeneration: 0, oldStyleRuns: [:], newStyleRuns: runs))
    let ctLine = try #require(view.firstRowCTLines?.first)
    let token = try #require(CTRunColorProbe.foreground(ctLine, at: offset))
    return (token, DiffPalette.shared.codeForeground.cgColor)
  }

  /// End-to-end: commit a Swift file, modify it uncommitted, stream the working-tree
  /// diff, and assert the new side carries a real content blob whose runs color the
  /// rendered row. Pre-fix `newBlobUTF16` was nil ⇒ no runs ⇒ white.
  @Test func workingTreeNewSideHighlightsEndToEnd() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("struct Sample {\n  let value = 1\n}\n", to: "Sample.swift", in: root)
    try GitFixture.stage("Sample.swift", in: root)
    try GitFixture.commit("init", in: root)
    // Uncommitted edit → the working-tree diff's new side is this on-disk content.
    let workdir = "struct Sample {\n  let value = 1\n  func run() {}\n}\n"
    try GitFixture.write(workdir, to: "Sample.swift", in: root)

    let batch = try workingTreeBatch(for: "Sample.swift", in: root)
    let oid = try #require(batch.newBlobID, "working-tree new side must carry a content OID now")
    let utf16 = try #require(batch.newBlobUTF16, "working-tree new side must carry decoded content now")
    #expect(utf16 == Array(workdir.utf16), "the new side is the on-disk workdir content")

    let input = HighlightBlobInput(blobOID: oid, utf16: utf16, path: "Sample.swift")
    let lineCount = workdir.split(separator: "\n", omittingEmptySubsequences: false).count
    let runs = await DiffHighlightClient.liveValue.styleRuns(input, 1..<lineCount)
    #expect(runs.contains { $0.value.contains { $0.capture.hasPrefix("keyword") } }, "new side must produce keywords")

    // Line 1 "struct Sample {" — `struct` keyword at 0..<6; render it and assert it is
    // NOT the base color (i.e. the new side is no longer white).
    let colors = try renderedTokenColor("struct Sample {", newLineNumber: 1, runs: runs, offset: 1)
    #expect(!CTRunColorProbe.sameColor(colors.token, colors.base), "the working-tree new side rendered white")
  }
}
