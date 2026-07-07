import Foundation
import Testing

@testable import supacode

/// Phase 9 producer tests: the libgit2 streaming walk against **real** temp git
/// repos (`GitFixture`, `@Suite(.serialized)`, no mocks). Covers delta-order
/// emission, generation stamping, the raised line cap, blob-OID content identity
/// per diff source, cooperative file-boundary cancel, the strict-UTF-8 binary
/// gate, the CR-only whole-blob buffer, and whitespace-insensitive streaming.
@Suite(.serialized)
struct DiffStreamTests {
  private static let bigCaps = Libgit2Diff.Caps(byteCap: 8 * 1024 * 1024, lineCap: 50_000, longLineCap: 2_000)

  private func readyBatches(_ events: [DiffStreamEvent]) -> [FileDiffBatch] {
    events.compactMap { if case .fileReady(let batch) = $0 { batch } else { nil } }
  }

  private func batch(_ events: [DiffStreamEvent], id: String) -> FileDiffBatch? {
    readyBatches(events).first { $0.file.id == id }
  }

  /// Synchronous collector over the direct walk (custom caps / cancel hooks).
  private func walk(
    root: URL,
    source: DiffSource = .workingTree,
    caps: Libgit2Diff.Caps? = nil,
    contextLines: UInt32 = 3,
    generation: Int = 1,
    ignoreWhitespace: Bool = false,
    isCancelled: @escaping () -> Bool = { false },
    onEvent: ((DiffStreamEvent) -> Void)? = nil
  ) throws -> [DiffStreamEvent] {
    Libgit2Diff.initialize()
    var events: [DiffStreamEvent] = []
    let request = Libgit2Diff.WalkRequest(
      source: source, caps: caps ?? Self.bigCaps, contextLines: contextLines,
      generation: generation, ignoreWhitespace: ignoreWhitespace)
    try Libgit2Diff.streamChangedFiles(at: root, request, isCancelled: isCancelled) { event in
      events.append(event)
      onEvent?(event)
    }
    return events
  }

  /// Async collector over the provider's `AsyncThrowingStream`.
  private func stream(
    _ provider: LibGit2DiffProvider, source: DiffSource, at root: URL, contextLines: UInt32 = 3, generation: Int
  ) async throws -> [DiffStreamEvent] {
    var events: [DiffStreamEvent] = []
    let eventStream = provider.stream(source: source, at: root, contextLines: contextLines, generation: generation)
    for try await event in eventStream {
      events.append(event)
    }
    return events
  }

  // MARK: - Order + generation

  @Test func streamsFilesInDeltaOrder() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    for name in ["a.txt", "b.txt", "c.txt"] {
      try GitFixture.write("orig \(name)\n", to: name, in: root)
    }
    try GitFixture.stage("a.txt", "b.txt", "c.txt", in: root)
    try GitFixture.commit("init", in: root)
    for name in ["a.txt", "b.txt", "c.txt"] {
      try GitFixture.write("edited \(name)\n", to: name, in: root)
    }

    let events = try await stream(LibGit2DiffProvider(), source: .workingTree, at: root, generation: 7)
    guard case .started(let fileCount, _, let startGen) = events.first else {
      Issue.record("first event is not .started")
      return
    }
    #expect(fileCount == 3)
    #expect(startGen == 7)
    #expect(readyBatches(events).map(\.file.id) == ["a.txt", "b.txt", "c.txt"])  // delta order
    #expect(events.last == .finished(generation: 7))
  }

  @Test func stampsGenerationOnEveryBatch() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("a\nb\nc\n", to: "a.txt", in: root)
    try GitFixture.stage("a.txt", in: root)
    try GitFixture.commit("init", in: root)
    try GitFixture.write("a\nB\nc\n", to: "a.txt", in: root)
    try GitFixture.write("new\n", to: "b.txt", in: root)

    let events = try await stream(LibGit2DiffProvider(), source: .workingTree, at: root, generation: 42)
    #expect(!events.isEmpty)
    for event in events {
      switch event {
      case .started(_, _, let generation): #expect(generation == 42)
      case .fileReady(let batch): #expect(batch.generation == 42)
      case .finished(let generation): #expect(generation == 42)
      }
    }
  }

  // MARK: - Raised cap (the streaming point)

  @Test func raisedCapStreamsFormerlyCappedFile() throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    let original = (1...20).map { "line \($0)\n" }.joined()
    try GitFixture.write(original, to: "big.txt", in: root)
    try GitFixture.stage("big.txt", in: root)
    try GitFixture.commit("init", in: root)
    // 12 more added lines — well over the injected `lineCap: 5`.
    try GitFixture.write(original + (21...32).map { "line \($0)\n" }.joined(), to: "big.txt", in: root)

    // A deliberately-tiny line cap that the non-stream path would cap on.
    let tinyLineCap = Libgit2Diff.Caps(byteCap: 8 * 1024 * 1024, lineCap: 5, longLineCap: 2_000)
    let events = try walk(root: root, caps: tinyLineCap)
    let big = try #require(batch(events, id: "big.txt"))
    // `streamingCaps` raises the line cap to `.max`, so the formerly-capped file
    // still materializes its hunks.
    #expect(!big.hunks.isEmpty)
    #expect(!big.file.isLargeFileCapped)
  }

  // MARK: - Blob-OID content identity per diff source (E seam 9 matrix)

  @Test(arguments: [DiffSource.workingTree, DiffSource.baseBranch(ref: "main")])
  func carriesOldBlobOIDForModifiedFile(source: DiffSource) async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("a\nb\nc\n", to: "a.txt", in: root)
    try GitFixture.stage("a.txt", in: root)
    try GitFixture.commit("init", in: root)

    try GitFixture.checkout("feature", create: true, in: root)
    try GitFixture.write("a\nB\nc\n", to: "a.txt", in: root)  // committed change → base diff sees it
    try GitFixture.stage("a.txt", in: root)
    try GitFixture.commit("edit a", in: root)
    try GitFixture.write("a\nB\nc2\n", to: "a.txt", in: root)  // uncommitted → working diff sees it

    let events = try await stream(LibGit2DiffProvider(), source: source, at: root, generation: 1)
    let change = try #require(batch(events, id: "a.txt"))
    // The OLD side is a real blob for every diff kind.
    #expect(change.oldBlobID != nil)
    // The NEW side is a real content blob for BOTH kinds: a tree/base diff reads it
    // from the object DB, and a working-tree diff reads the workdir file from disk
    // (the Phase-4 fix — without it the new side never highlights, i.e. all white).
    #expect(change.newBlobID != nil)
    if source.isWorkingTree {
      #expect(change.newBlobUTF16 == Array("a\nB\nc2\n".utf16), "working-tree new side is the on-disk content")
    }
  }

  // MARK: - Cooperative file-boundary cancel

  @Test func cancelStopsAtFileBoundary() throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    for name in ["a.txt", "b.txt", "c.txt"] {
      try GitFixture.write("orig\n", to: name, in: root)
    }
    try GitFixture.stage("a.txt", "b.txt", "c.txt", in: root)
    try GitFixture.commit("init", in: root)
    for name in ["a.txt", "b.txt", "c.txt"] {
      try GitFixture.write("edited\n", to: name, in: root)
    }

    // Cancel once the first `.fileReady` has been emitted; the walk polls at the
    // next file boundary and returns before emitting any further file or `.finished`.
    var readyCount = 0
    let events = try walk(
      root: root,
      isCancelled: { readyCount >= 1 },
      onEvent: { if case .fileReady = $0 { readyCount += 1 } })
    #expect(readyBatches(events).count == 1)
    #expect(!events.contains { if case .finished = $0 { true } else { false } })
  }

  // MARK: - Version gate (blob-OID as the version — A §13)

  @Test func versionGatedReconcile() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("a1\n", to: "a.txt", in: root)
    try GitFixture.write("b1\n", to: "b.txt", in: root)
    try GitFixture.stage("a.txt", "b.txt", in: root)
    try GitFixture.commit("init on main", in: root)

    try GitFixture.checkout("feature", create: true, in: root)
    try GitFixture.write("a2\n", to: "a.txt", in: root)
    try GitFixture.write("b2\n", to: "b.txt", in: root)
    try GitFixture.stage("a.txt", "b.txt", in: root)
    try GitFixture.commit("edit both", in: root)

    let provider = LibGit2DiffProvider()
    let first = try await stream(provider, source: .baseBranch(ref: "main"), at: root, generation: 1)
    let firstA = try #require(batch(first, id: "a.txt")).identity
    let firstB = try #require(batch(first, id: "b.txt")).identity
    #expect(readyBatches(first).map(\.file.id) == ["a.txt", "b.txt"])  // order

    // Change ONLY a.txt again (a new commit on feature).
    try GitFixture.write("a3\n", to: "a.txt", in: root)
    try GitFixture.stage("a.txt", in: root)
    try GitFixture.commit("edit a again", in: root)

    let second = try await stream(provider, source: .baseBranch(ref: "main"), at: root, generation: 2)
    let secondA = try #require(batch(second, id: "a.txt")).identity
    let secondB = try #require(batch(second, id: "b.txt")).identity
    #expect(readyBatches(second).map(\.file.id) == ["a.txt", "b.txt"])  // order preserved

    #expect(secondB == firstB)  // unchanged version ⇒ no-op sync
    #expect(secondA != firstA)  // changed version ⇒ apply
  }

  // MARK: - Strict-UTF-8 binary gate (D §7)

  @Test(arguments: [
    ("loneSurrogate", [UInt8]([0xED, 0xA0, 0x80])),
    ("overlongNUL", [UInt8]([0xC0, 0x80])),
    ("bareContinuation", [UInt8]([0x80])),
    ("invalidFF", [UInt8]([0xFF, 0xFE, 0xFD])),
    ("truncatedMultibyte", [UInt8]([0xE2, 0x82])),
    ("nul", [UInt8]([0x00, 0x41, 0x42])),
  ])
  func decodeStrictUTF8BinaryGate(name: String, bytes: [UInt8]) async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("base\n", to: "weird.dat", in: root)
    try GitFixture.stage("weird.dat", in: root)
    try GitFixture.commit("init", in: root)
    try GitFixture.writeBytes(bytes, to: "weird.dat", in: root)

    let events = try await stream(LibGit2DiffProvider(), source: .workingTree, at: root, generation: 1)
    let weird = try #require(batch(events, id: "weird.dat"))
    #expect(weird.file.isBinary)
    #expect(weird.hunks.isEmpty)
    // Zero materialized line rows: the classifier emits only a placeholder widget.
    let chunks = ChunkTreeBuilder.classify(file: weird.file, hunks: weird.hunks, expanded: [])
    #expect(chunks.allSatisfy { $0.lineSegment == nil })
  }

  // MARK: - CR-only whole-blob buffer (D G1)

  @Test func crOnlyWholeBlobBufferConsequence() throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("a\rb\rc", to: "cr.txt", in: root)  // lone-CR line breaks, no LF
    try GitFixture.stage("cr.txt", in: root)
    try GitFixture.commit("init", in: root)
    try GitFixture.write("z\rb\rc", to: "cr.txt", in: root)  // change so it appears in the diff

    let events = try walk(root: root)
    let crBatch = try #require(batch(events, id: "cr.txt"))
    // The whole-blob `[UInt16]` handed to search / highlight is the RAW old blob,
    // un-split on the lone `\r` — the buildLineStarts decision (P3 owns the store).
    #expect(crBatch.oldBlobUTF16 == Array("a\rb\rc".utf16))
  }

  // MARK: - Whitespace-insensitive streaming (A §17)

  @Test func ignoreWhitespaceSurfacedAndCountsConsistent() throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("a\nb\nc\n", to: "ws.txt", in: root)
    try GitFixture.write("x\ny\nz\n", to: "real.txt", in: root)
    try GitFixture.stage("ws.txt", "real.txt", in: root)
    try GitFixture.commit("init", in: root)
    try GitFixture.write("a  \nb\nc\n", to: "ws.txt", in: root)  // whitespace-only change
    try GitFixture.write("x\nY\nz\n", to: "real.txt", in: root)  // real change

    // Without the flag, the whitespace-only change is a real hunk.
    let plain = try walk(root: root)
    #expect(!(batch(plain, id: "ws.txt")?.hunks.isEmpty ?? true))

    // With the flag threaded through, git drops the whitespace-only hunk, and the
    // real file's counts stay internally consistent.
    let ignored = try walk(root: root, ignoreWhitespace: true)
    #expect(batch(ignored, id: "ws.txt")?.hunks.isEmpty ?? true)
    let real = try #require(batch(ignored, id: "real.txt"))
    #expect(!real.hunks.isEmpty)
    #expect(ChunkTreeBuilder.verifyHunkLineValues(real.hunks).isEmpty)
  }

  // MARK: - 🔴 RED until Phase 4: the GF confirmation of the P4 blob-bucketing regression

  @Test(
    .disabled("RED until Phase 4 lands the pure blob-bucketing arm"),
    arguments: [DiffSource.workingTree, DiffSource.baseBranch(ref: "main")]
  )
  func correctBlobPerDiffSource(source: DiffSource) async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("a\nb\nc\n", to: "a.txt", in: root)
    try GitFixture.write("gone\n", to: "gone.txt", in: root)
    try GitFixture.stage("a.txt", "gone.txt", in: root)
    try GitFixture.commit("init", in: root)
    try GitFixture.checkout("feature", create: true, in: root)
    try GitFixture.write("a\nB\nc\n", to: "a.txt", in: root)
    try GitFixture.remove("gone.txt", in: root)
    try GitFixture.stage("a.txt", "gone.txt", in: root)
    try GitFixture.commit("edit + delete", in: root)

    let events = try await stream(LibGit2DiffProvider(), source: source, at: root, generation: 1)
    let modified = try #require(batch(events, id: "a.txt"))
    #expect(modified.oldBlobID != nil)
    let deleted = try #require(batch(events, id: "gone.txt"))
    #expect(deleted.oldBlobID != nil)
    #expect(deleted.newBlobID == nil)  // deletion has no new side
  }
}
