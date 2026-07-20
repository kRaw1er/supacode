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

  /// Render one row and PULL its runs from `engine`'s warmed span cache (the TRUE pull
  /// path) — the base foreground is the "white" everything collapsed to on the pre-fix
  /// nil-blob bug.
  private func renderedTokenColor(
    _ content: String, newLineNumber: Int, engine: DiffHighlightEngine, input: HighlightBlobInput, offset: Int
  ) throws -> (token: CGColor, base: CGColor) {
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
        cache: CTLineCache(), palette: .shared, styleGeneration: 0, syntaxProvider: .live(engine), oldBlobOID: nil,
        newBlobOID: input.blobOID, oldQueryName: nil,
        newQueryName: DiffHighlightEngine.grammarQueryName(forPath: input.path)))
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
    // Warm a REAL engine over the 0-based blob window, filling the span cache the row pulls from.
    let engine = DiffHighlightEngine()
    let runs = await engine.styleRuns(for: input, visibleLines: 0..<lineCount)
    #expect(runs.contains { $0.value.contains { $0.capture.hasPrefix("keyword") } }, "new side must produce keywords")

    // Line 1 "struct Sample {" — `struct` keyword at 0..<6; render it and assert it is
    // NOT the base color (i.e. the new side is no longer white).
    let colors = try renderedTokenColor("struct Sample {", newLineNumber: 1, engine: engine, input: input, offset: 1)
    #expect(!CTRunColorProbe.sameColor(colors.token, colors.base), "the working-tree new side rendered white")
  }

  /// The ON-DEMAND (`.diffLoaded` / production) blob read — `Libgit2Diff.fileHighlightBlobs`
  /// — reads BOTH sides for a working-tree modified file: old from the object DB, new
  /// from the workdir file. This is the path the app actually uses (streaming is off).
  @Test func onDemandFileHighlightBlobsReadsBothSides() throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("struct Sample {\n  let value = 1\n}\n", to: "Sample.swift", in: root)
    try GitFixture.stage("Sample.swift", in: root)
    try GitFixture.commit("init", in: root)
    let workdir = "struct Sample {\n  let value = 2\n}\n"
    try GitFixture.write(workdir, to: "Sample.swift", in: root)

    Libgit2Diff.initialize()
    let blobs = try Libgit2Diff.fileHighlightBlobs(
      for: DiffFixture.file(path: "Sample.swift"), at: root, source: .workingTree, caps: Self.caps)
    let new = try #require(blobs.new, "on-demand load must read the workdir new side")
    #expect(new.utf16 == Array(workdir.utf16), "the new side is the on-disk workdir content")
    #expect(blobs.old != nil, "the old side reads from the object DB")
  }

  /// Bug #1 end-to-end for a base-branch (three-dot) review: the OLD (base) side must
  /// highlight the MERGE-BASE blob read from the object DB — NOT the on-disk workdir
  /// file. A trap workdir (different from both merge-base and HEAD) is left uncommitted;
  /// a regression that read the workdir would surface the trap content instead. Asserts
  /// both sides carry the committed blob content and that a `struct` keyword span lands
  /// on the base-side line (spans land on the base blob, not the workdir).
  @Test func baseBranchHighlightReadsBaseBlob() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    // Merge-base content on main (the base side of the three-dot diff).
    let baseSource = "struct Base {\n  let value = 1\n}\n"
    try GitFixture.write(baseSource, to: "Sample.swift", in: root)
    try GitFixture.stage("Sample.swift", in: root)
    try GitFixture.commit("init", in: root)
    // HEAD content on feature (the new side).
    try GitFixture.checkout("feature", create: true, in: root)
    let headSource = "struct Feature {\n  let value = 2\n  func run() {}\n}\n"
    try GitFixture.write(headSource, to: "Sample.swift", in: root)
    try GitFixture.stage("Sample.swift", in: root)
    try GitFixture.commit("edit on feature", in: root)
    // A DIFFERENT uncommitted workdir — the trap the wrong-blob bug would read.
    let trapWorkdir = "enum Trap {\n  case boom\n}\n"
    try GitFixture.write(trapWorkdir, to: "Sample.swift", in: root)

    Libgit2Diff.initialize()
    let blobs = try Libgit2Diff.fileHighlightBlobs(
      for: DiffFixture.file(path: "Sample.swift"), at: root, source: .baseBranch(ref: "main"), caps: Self.caps)
    let old = try #require(blobs.old, "base diff must read the merge-base old side")
    let new = try #require(blobs.new, "base diff must read the HEAD new side")
    // The base (old) side is the MERGE-BASE blob — NOT the on-disk workdir file.
    #expect(old.utf16 == Array(baseSource.utf16), "base side must be the merge-base blob, not the workdir")
    #expect(old.utf16 != Array(trapWorkdir.utf16), "base side must not read the uncommitted workdir file")
    // The new side is the committed HEAD (three-dot) blob, also not the workdir.
    #expect(new.utf16 == Array(headSource.utf16), "new side is the committed HEAD blob")
    #expect(new.utf16 != Array(trapWorkdir.utf16))

    // Highlight the base blob: keyword spans must land on the base-side lines — the
    // highlighter parsed the MERGE-BASE blob (every run here is a base-side span,
    // since `old` IS the base input). Pre-fix this side read the workdir instead.
    let lineCount = baseSource.split(separator: "\n", omittingEmptySubsequences: false).count
    let runs = await SyntaxRenderHarness.liveRuns(old, lineNumbers: 0..<lineCount)
    #expect(
      runs.contains { $0.value.contains { $0.capture.hasPrefix("keyword") } },
      "the base blob must produce keyword spans on the base side")
  }
}
