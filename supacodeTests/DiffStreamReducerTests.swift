import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Records the reducer→consumer seam so the streaming reducer arms can assert
/// "the consumer was fed" without a live viewport.
private actor StreamSpy {
  struct BeginRecord: Equatable {
    var key: DiffDocumentKey
    var fileCount: Int
    var generation: Int
  }
  struct ConsumeRecord: Equatable {
    var key: DiffDocumentKey
    var batch: FileDiffBatch
  }

  private(set) var begins: [BeginRecord] = []
  private(set) var consumes: [ConsumeRecord] = []
  private(set) var finishes: [DiffDocumentKey] = []

  func recordBegin(_ key: DiffDocumentKey, _ fileCount: Int, _ generation: Int) {
    begins.append(BeginRecord(key: key, fileCount: fileCount, generation: generation))
  }
  func recordConsume(_ key: DiffDocumentKey, _ batch: FileDiffBatch) {
    consumes.append(ConsumeRecord(key: key, batch: batch))
  }
  func recordFinish(_ key: DiffDocumentKey, _ generation: Int) { finishes.append(key) }

  var consumeCount: Int { consumes.count }
  func identities(for id: String) -> [FileBlobIdentity] {
    consumes.filter { $0.batch.file.id == id }.map(\.batch.identity)
  }
}

/// Pure (static) fixtures so the `@Sendable` stream closures never capture the
/// `@MainActor` test value.
private enum StreamFixture {
  static func worktree() -> Worktree {
    Worktree(
      id: WorktreeID("/tmp/repo/wt"),
      name: "wt",
      detail: "",
      workingDirectory: URL(filePath: "/tmp/repo/wt"),
      repositoryRootURL: URL(filePath: "/tmp/repo")
    )
  }

  static func makeFile(_ path: String) -> FileChange {
    FileChange(
      oldPath: path, newPath: path, status: .modified, addedLines: 1, removedLines: 0,
      isBinary: false, isLargeFileCapped: false, hasLongLines: false, similarity: 0)
  }

  static func hunk(_ contextLine: String, newLine: Int) -> DiffHunk {
    DiffHunk(
      oldStart: 1, oldCount: 1, newStart: 1, newCount: 2, header: "@@",
      lines: [
        DiffLine(
          origin: .context, oldLineNumber: newLine, newLineNumber: newLine, content: contextLine,
          noNewlineAtEof: false),
        DiffLine(
          origin: .addition, oldLineNumber: nil, newLineNumber: newLine + 1, content: "added", noNewlineAtEof: false),
      ])
  }

  static func batch(_ id: String, hunks: [DiffHunk], oldBlobID: String?, generation: Int) -> FileDiffBatch {
    FileDiffBatch(
      file: makeFile(id), hunks: hunks,
      unifiedLineCount: hunks.reduce(0) { $0 + $1.lines.count },
      splitLineCount: hunks.reduce(0) { $0 + max($1.oldCount, $1.newCount) },
      oldBlobID: oldBlobID, newBlobID: nil, oldBlobUTF16: nil, newBlobUTF16: nil, generation: generation)
  }

  static func spyClient(_ spy: StreamSpy) -> DiffStreamConsumerClient {
    DiffStreamConsumerClient(
      begin: { key, fileCount, _, generation in await spy.recordBegin(key, fileCount, generation) },
      consume: { key, batch, _ in await spy.recordConsume(key, batch) },
      finish: { key, generation in await spy.recordFinish(key, generation) })
  }
}

@MainActor
struct DiffStreamReducerTests {
  // MARK: - open → stream → loaded (C 11.10)

  @Test(.dependencies) func streamingLoadFinishesDocument() async {
    let file = StreamFixture.makeFile("a.swift")
    let hunks = [StreamFixture.hunk("keep", newLine: 1)]
    let spy = StreamSpy()
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = StreamFixture.worktree()
    initialState.files = [file]
    initialState.loadState = .loaded
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.terminalClient.send = { _ in }
      $0.diffStreamingEnabled = true
      $0.diffStreamConsumer = StreamFixture.spyClient(spy)
      $0.diffClient.stream = { _, _, _, gen, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.started(fileCount: 1, operation: .none, generation: gen))
          continuation.yield(
            .fileReady(StreamFixture.batch("a.swift", hunks: hunks, oldBlobID: "old", generation: gen)))
          continuation.yield(.finished(generation: gen))
          continuation.finish()
        }
      }
    }

    let key = DiffDocumentKey(path: "a.swift", source: .workingTree)
    await store.send(.openFile(path: "a.swift", source: .workingTree)) {
      $0.diffLoadToken = 1
      $0.openDiffs[key] = DiffDocument(file: file, loadState: .loading, generation: 1)
    }
    await store.receive(\.streamStarted)  // consumer.begin
    await store.receive(\.streamFileReady) {
      var document = DiffDocument(file: file, loadState: .loading, generation: 1)
      document.hunks = hunks
      document.loadState = .loaded
      document.isStale = false
      // Post-P13 seam swap: the tree-backed viewport projects `hunks` directly —
      // no flat `rows`, no `revision` bump. Syntax runs are a render-layer pull off the
      // span cache now, so nothing highlight-related lands on the document.
      $0.openDiffs[key] = document
    }
    await store.receive(\.streamFinished)

    #expect(await spy.begins.count == 1)
    #expect(await spy.consumeCount == 1)
    #expect(await spy.finishes.count == 1)
    #expect(await spy.begins.first?.generation == 1)
  }

  // MARK: - stale token dropped (C 11.11 / E seam 5.2)

  @Test(.dependencies) func staleGenerationBatchDroppedReducer() async {
    let file = StreamFixture.makeFile("a.swift")
    let key = DiffDocumentKey(path: "a.swift", source: .workingTree)
    // The document is already on generation 2 (a re-open superseded token 1).
    var document = DiffDocument(file: file, loadState: .loading, generation: 2)
    document.hunks = [StreamFixture.hunk("keep", newLine: 1)]
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = StreamFixture.worktree()
    initialState.openDiffs = [key: document]
    initialState.diffLoadToken = 2
    let spy = StreamSpy()
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffStreamConsumer = StreamFixture.spyClient(spy)
    }

    // A superseded token is a no-op — state unchanged, consumer NOT fed.
    await store.send(
      .streamFileReady(
        key: key, batch: StreamFixture.batch("a.swift", hunks: [], oldBlobID: "x", generation: 1), token: 1)
    )
    #expect(await spy.consumeCount == 0)
  }

  // MARK: - refresh re-streams; unchanged file keeps a stable identity (C 16.3 / E seam 5.3)

  @Test(.dependencies) func refreshReusesUnchangedFiles() async {
    let fileA = StreamFixture.makeFile("a.txt")
    let fileB = StreamFixture.makeFile("b.txt")
    let spy = StreamSpy()
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = StreamFixture.worktree()
    initialState.files = [fileA, fileB]
    initialState.loadState = .loaded
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.terminalClient.send = { _ in }
      $0.diffStreamingEnabled = true
      $0.diffStreamConsumer = StreamFixture.spyClient(spy)
      $0.diffClient.changedFiles = { _, _ in
        WorktreeDiff(files: [fileA, fileB], isUnbornHead: false, operation: .none)
      }
      // Whole-worktree stream: a.txt unchanged across generations; b.txt is the
      // edited file (its old-blob identity changes on the refresh, gen 2).
      $0.diffClient.stream = { _, _, _, gen, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.started(fileCount: 2, operation: .none, generation: gen))
          continuation.yield(.fileReady(StreamFixture.batch("a.txt", hunks: [], oldBlobID: "a1", generation: gen)))
          continuation.yield(
            .fileReady(StreamFixture.batch("b.txt", hunks: [], oldBlobID: gen <= 1 ? "b1" : "b2", generation: gen)))
          continuation.yield(.finished(generation: gen))
          continuation.finish()
        }
      }
    }
    store.exhaustivity = .off

    // Initial open streams the whole worktree (gen 1) into the consumer.
    await store.send(.openFile(path: "a.txt", source: .workingTree))
    await store.receive(\.streamStarted)
    await store.receive(\.streamFileReady)
    await store.receive(\.streamFileReady)
    await store.receive(\.streamFinished)

    // A list reload re-streams the open doc (still `.cancellable` per key), gen 2.
    await store.send(.load)
    await store.receive(\.loaded)
    await store.receive(\.streamStarted)
    await store.receive(\.streamFileReady)
    await store.receive(\.streamFileReady)
    await store.receive(\.streamFinished)
    await store.finish()

    // The unchanged file keeps a STABLE identity across the re-stream (what lets
    // the consumer reuse its sub-tree); the edited file's identity changes (the
    // consumer re-splices). Reuse itself is proven in `consumerContentIdentityReuse`.
    let aIdentities = await spy.identities(for: "a.txt")
    let bIdentities = await spy.identities(for: "b.txt")
    #expect(aIdentities.map(\.oldBlobID) == ["a1", "a1"])  // stable ⇒ reuse
    #expect(bIdentities.map(\.oldBlobID) == ["b1", "b2"])  // changed ⇒ re-splice
  }

  // MARK: - re-diff relocates comments + preserves expansion (E seam 5.4)

  @Test(.dependencies) func reDiffRelocatesCommentsAndPreservesExpansion() async {
    let file = StreamFixture.makeFile("a.swift")
    let key = DiffDocumentKey(path: "a.swift", source: .workingTree)
    let tracked = ReviewComment(
      filePath: "a.swift", source: .workingTree, side: .new, startLine: 3, endLine: 3,
      anchorSnippet: "target", contextBefore: "", createdAt: Date(timeIntervalSince1970: 1))
    let vanishing = ReviewComment(
      filePath: "a.swift", source: .workingTree, side: .new, startLine: 9, endLine: 9,
      anchorSnippet: "gone-forever", contextBefore: "", createdAt: Date(timeIntervalSince1970: 2))
    var document = DiffDocument(file: file, loadState: .loaded, generation: 1)
    document.expansion = .regions([1: HunkExpansionRegion(fromStart: 20)])  // a GapKey(1) expansion in effect
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = StreamFixture.worktree()
    initialState.openDiffs = [key: document]
    initialState.comments = [tracked, vanishing]
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffStreamConsumer = StreamFixture.spyClient(StreamSpy())
    }
    store.exhaustivity = .off

    // The re-diffed hunk moves "target" to line 5; "gone-forever" is absent.
    let movedHunk = DiffHunk(
      oldStart: 1, oldCount: 5, newStart: 1, newCount: 6, header: "@@",
      lines: [
        DiffLine(origin: .context, oldLineNumber: 4, newLineNumber: 4, content: "ctx", noNewlineAtEof: false),
        DiffLine(origin: .context, oldLineNumber: 5, newLineNumber: 5, content: "target", noNewlineAtEof: false),
      ])
    await store.send(
      .streamFileReady(
        key: key, batch: StreamFixture.batch("a.swift", hunks: [movedHunk], oldBlobID: "n", generation: 1), token: 1))
    await store.finish()

    #expect(store.state.comments[id: tracked.id]?.startLine == 5)  // relocated 3 → 5
    #expect(store.state.comments[id: tracked.id]?.orphaned == false)
    #expect(store.state.comments[id: vanishing.id]?.orphaned == true)  // orphaned, NEVER dropped
    #expect(store.state.comments[id: vanishing.id] != nil)
    // GapKey(1) survives the line shift — hunk-INDEX keying (a line-number `Set<Int>`
    // would have drifted when "target" moved 3 → 5).
    #expect(store.state.openDiffs[key]?.expansion == .regions([1: HunkExpansionRegion(fromStart: 20)]))
  }

  // MARK: - Phase 13 seam swap — mode toggle is a global re-seek, no per-doc work

  @Test(.dependencies)
  func modeToggleIsGlobalReseekNoDiff() async {
    let file = StreamFixture.makeFile("a.swift")
    let hunks = [StreamFixture.hunk("keep", newLine: 1)]
    var document = DiffDocument(file: file, loadState: .loaded, generation: 1)
    document.hunks = hunks
    let key = DiffDocumentKey(path: "a.swift", source: .workingTree)
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = StreamFixture.worktree()
    initialState.openDiffs = [key: document]
    let diffCalled = LockIsolated(false)
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.diff = { _, _, _, _, _ in
        diffCalled.setValue(true)
        return []
      }
    }
    store.exhaustivity = .off

    await store.send(.diffModeChanged(.split))
    // Post-P13: the tree is dual-mode, so the toggle only persists the global
    // preference — no per-doc row rebuild, no diff call, document unchanged.
    #expect(store.state.diffViewMode == .split)
    #expect(store.state.openDiffs[key]?.hunks == hunks)
    #expect(diffCalled.value == false)
  }
}
