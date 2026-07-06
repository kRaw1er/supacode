import AppKit
import Testing

@testable import supacode

/// Phase 9 consumer tests (NSVIEW-HEADLESS + GIT-FIXTURE): the `@MainActor`
/// `DiffStreamConsumer` scaffolding a `ChunkTree`, reconciling by blob-OID content
/// identity, taking the below-fold append fast path, dropping stale generations on
/// arrival, and re-keying a rename in place (pierre `updateItemId`).
@MainActor
@Suite(.serialized)
struct DiffStreamConsumerTests {
  // MARK: - Fixtures

  /// A modified/added batch with `count` change rows (predictable ≈
  /// `count × 20 + 44 + 32` height), a fixed old-blob identity.
  private func bigBatch(id: String, additions: Int, oldBlobID: String, generation: Int) -> FileDiffBatch {
    let lines = (0..<additions).map {
      DiffLine(
        origin: .addition, oldLineNumber: nil, newLineNumber: $0 + 1, content: "add \($0)", noNewlineAtEof: false)
    }
    let hunk = DiffHunk(
      oldStart: 0, oldCount: 0, newStart: 1, newCount: additions, header: "@@ -0,0 +1 @@", lines: lines)
    let file = FileChange(
      oldPath: nil, newPath: id, status: .added, addedLines: additions, removedLines: 0,
      isBinary: false, isLargeFileCapped: false, hasLongLines: false, similarity: 0)
    return FileDiffBatch(
      file: file, hunks: [hunk], unifiedLineCount: additions, splitLineCount: additions,
      oldBlobID: oldBlobID, newBlobID: nil, oldBlobUTF16: nil, newBlobUTF16: nil, generation: generation)
  }

  private func batches(
    _ provider: LibGit2DiffProvider, source: DiffSource, at root: URL, generation: Int
  ) async throws -> [FileDiffBatch] {
    var out: [FileDiffBatch] = []
    for try await event in provider.stream(source: source, at: root, contextLines: 3, generation: generation) {
      if case .fileReady(let batch) = event { out.append(batch) }
    }
    return out
  }

  private func lineSegmentIDs(_ consumer: DiffStreamConsumer, fileID: String) -> [ChunkID] {
    guard let span = consumer.tree.fileNodeSpan(fileID: fileID) else { return [] }
    return span.nodes.filter { consumer.tree.nodesByID[$0]?.chunk.lineSegment != nil }
  }

  // MARK: - Up-front height estimate (pierre computeEstimatedDiffHeights)

  @Test func upFrontHeightEstimateBothModes() {
    // PURE: count × lineHeight + diffHeaderHeight(44) + separators(32).
    let tenLines: CGFloat = 10 * 20 + 44 + 32
    let zeroLines: CGFloat = 44 + 32
    #expect(DiffStreamConsumer.estimatedFileHeight(lineCount: 10) == tenLines)
    #expect(DiffStreamConsumer.estimatedFileHeight(lineCount: 0) == zeroLines)

    let controller = ViewportTestSupport.controller()
    let consumer = DiffStreamConsumer(viewport: controller)
    // After `.started`, the coarse scaffold gives a non-zero total so the
    // scrollbar frame is stable from frame 1.
    consumer.begin(fileCount: 5, mode: .unified, generation: 1)
    #expect(consumer.tree.totalHeight(.unified) > 0)
    #expect(consumer.tree.totalHeight(.split) > 0)
    let originAfterStart = controller.scrollView.contentView.bounds.origin.y

    // A below-fold file refines the total without moving the anchored top.
    consumer.consume(bigBatch(id: "a.txt", additions: 100, oldBlobID: "oidA", generation: 1))
    consumer.consume(bigBatch(id: "b.txt", additions: 100, oldBlobID: "oidB", generation: 1))
    #expect(controller.scrollView.contentView.bounds.origin.y == originAfterStart)
    #expect(consumer.tree.totalHeight(.unified) > 0)
  }

  // MARK: - Below-fold append fast path (pierre tryAppendItems)

  @Test func consumerBelowFoldAppendFastPath() {
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: 600)
    let consumer = DiffStreamConsumer(viewport: controller)
    consumer.begin(fileCount: 3, mode: .unified, generation: 1)

    // First file is at the top (intersecting → anchored); each ≈ 2076px, so every
    // later file's insertY exceeds `visibleMaxY(600) + overscan(1000)`.
    consumer.consume(bigBatch(id: "a.txt", additions: 100, oldBlobID: "oidA", generation: 1))
    consumer.consume(bigBatch(id: "b.txt", additions: 100, oldBlobID: "oidB", generation: 1))
    consumer.consume(bigBatch(id: "c.txt", additions: 100, oldBlobID: "oidC", generation: 1))

    #expect(consumer.diagnostics.anchoredAppends == 1)  // only the first, at the top
    #expect(consumer.diagnostics.belowFoldAppends == 2)  // the rest grew the scaffold only
    #expect(controller.scrollView.contentView.bounds.origin.y == 0)  // no jump
  }

  // MARK: - Stale-generation drop on arrival (E seam 5.2)

  @Test func consumerDropsStaleGenerationOnArrival() {
    let controller = ViewportTestSupport.controller()
    let consumer = DiffStreamConsumer(viewport: controller)
    consumer.begin(fileCount: 1, mode: .unified, generation: 5)

    // A superseded generation is a no-op on arrival.
    consumer.consume(bigBatch(id: "a.txt", additions: 3, oldBlobID: "oidStale", generation: 4))
    #expect(consumer.diagnostics.staleDrops == 1)
    #expect(consumer.fileOrder.isEmpty)

    // The current generation materializes.
    consumer.consume(bigBatch(id: "a.txt", additions: 3, oldBlobID: "oidLive", generation: 5))
    #expect(consumer.fileOrder == ["a.txt"])
  }

  // MARK: - Content-identity reuse (GIT-FIXTURE; heights survive)

  @Test(arguments: [DiffSource.workingTree, DiffSource.baseBranch(ref: "main")])
  func consumerContentIdentityReuse(source: DiffSource) async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("a\nb\nc\nd\ne\n", to: "a.txt", in: root)
    try GitFixture.stage("a.txt", in: root)
    try GitFixture.commit("init", in: root)
    try GitFixture.checkout("feature", create: true, in: root)
    try GitFixture.write("a\nB\nc\nd\ne\n", to: "a.txt", in: root)
    try GitFixture.stage("a.txt", in: root)
    try GitFixture.commit("edit a", in: root)
    if source.isWorkingTree {
      try GitFixture.write("a\nB\nc\nd\nE\n", to: "a.txt", in: root)  // uncommitted for the working diff
    }

    let provider = LibGit2DiffProvider()
    let controller = ViewportTestSupport.controller()
    let consumer = DiffStreamConsumer(viewport: controller)

    let first = try await batches(provider, source: source, at: root, generation: 1)
    consumer.begin(fileCount: first.count, mode: .unified, generation: 1)
    for batch in first { consumer.consume(batch) }
    consumer.finish()

    // Pin a measured height on the file's first line segment.
    let segmentIDs = lineSegmentIDs(consumer, fileID: "a.txt")
    let segment = try #require(segmentIDs.first)
    consumer.tree.setMeasuredHeight(55, chunk: segment, localRow: 0, mode: .unified)
    let measuredBefore = try #require(consumer.tree.nodesByID[segment]).summary.height(.unified)
    let idsBefore = lineSegmentIDs(consumer, fileID: "a.txt")

    // Re-diff with the SAME content ⇒ same `(oldBlobID,newBlobID)` identity. Assert
    // BEFORE `finish()`, since `finish()`'s viewport apply re-measures real CoreText
    // heights (a legitimate viewport pass) that would overwrite the injected delta.
    let second = try await batches(provider, source: source, at: root, generation: 2)
    consumer.begin(fileCount: second.count, mode: .unified, generation: 2)
    for batch in second { consumer.consume(batch) }

    #expect(consumer.diagnostics.reuses >= 1)  // cache hit, not miss
    #expect(consumer.diagnostics.splices == 0)  // no O(n) row diff / re-splice
    #expect(lineSegmentIDs(consumer, fileID: "a.txt") == idsBefore)  // same instances
    // Heights survive the reuse (the whole point of content identity): the reuse
    // path is a no-op, so the injected measured delta on the kept node is intact.
    #expect(consumer.tree.nodesByID[segment]?.summary.height(.unified) == measuredBefore)
    consumer.finish()
  }

  // MARK: - Rename re-keys in place (pierre updateItemId)

  @Test func renameReusesAndRetargetsSelection() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    let content = (1...20).map { "line \($0)\n" }.joined()
    try GitFixture.write(content, to: "a.txt", in: root)
    try GitFixture.stage("a.txt", in: root)
    try GitFixture.commit("init", in: root)
    try GitFixture.checkout("feature", create: true, in: root)
    try GitFixture.write(content + "extra\n", to: "a.txt", in: root)  // modify so it appears
    try GitFixture.stage("a.txt", in: root)
    try GitFixture.commit("edit a", in: root)

    let provider = LibGit2DiffProvider()
    let controller = ViewportTestSupport.controller()
    let consumer = DiffStreamConsumer(viewport: controller)

    let first = try await batches(provider, source: .baseBranch(ref: "main"), at: root, generation: 1)
    consumer.begin(fileCount: first.count, mode: .unified, generation: 1)
    for batch in first { consumer.consume(batch) }
    consumer.finish()
    let headerBefore = try #require(consumer.tree.fileNode(id: "a.txt")).id

    // Rename a.txt → b.txt (git mv detects it), commit.
    try GitFixture.rename("a.txt", "b.txt", in: root)
    try GitFixture.commit("rename", in: root)

    let second = try await batches(provider, source: .baseBranch(ref: "main"), at: root, generation: 2)
    #expect(second.contains { $0.file.id == "b.txt" && $0.file.status == .renamed })
    consumer.begin(fileCount: second.count, mode: .unified, generation: 2)
    for batch in second { consumer.consume(batch) }
    consumer.finish()

    // The old id is gone; the new id reuses the SAME header element/instance.
    #expect(consumer.tree.fileNode(id: "a.txt") == nil)
    #expect(consumer.fileOrder.contains("b.txt"))
    #expect(!consumer.fileOrder.contains("a.txt"))
    #expect(consumer.tree.fileNode(id: "b.txt")?.id == headerBefore)  // same instance under the new id
  }
}
