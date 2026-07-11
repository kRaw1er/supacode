import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

/// Phase 13 (C 15.6, reducer seam) — the fully-changed-huge-file gate wired into
/// `.streamFileReady`: `LargeFileRenderPolicy` sets `highlightingDisabled` /
/// `wordDiffDisabled` AND surfaces a header `renderBannerKey` so a dropped render
/// feature is NEVER a silent drop. Drives the streaming arm with a synthetic
/// `FileDiffBatch` (no libgit2 needed — the arithmetic is the unit under test).
@MainActor
@Suite(.serialized)
struct LargeFileRenderGateReducerTests {

  private func file(
    path: String, removed: Int, added: Int, capped: Bool = false, hasLongLines: Bool = false
  ) -> FileChange {
    FileChange(
      oldPath: path, newPath: path, status: .modified,
      addedLines: added, removedLines: removed, isBinary: false,
      isLargeFileCapped: capped, hasLongLines: hasLongLines, similarity: 0)
  }

  private func batch(file: FileChange, lines: [DiffLine] = []) -> FileDiffBatch {
    let hunk = DiffHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, header: "@@", lines: lines)
    return FileDiffBatch(
      file: file, hunks: lines.isEmpty ? [] : [hunk], unifiedLineCount: lines.count, splitLineCount: lines.count,
      oldBlobID: nil, newBlobID: nil, oldBlobUTF16: nil, newBlobUTF16: nil, generation: 1)
  }

  private func store(_ document: DiffDocument, key: DiffDocumentKey) -> TestStoreOf<DiffReviewFeature> {
    var state = DiffReviewFeature.State()
    state.openDiffs[key] = document
    let store = TestStore(initialState: state) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffStreamConsumer = DiffStreamConsumerClient(
        begin: { _, _, _, _ in }, consume: { _, _, _ in }, finish: { _, _ in })
    }
    store.exhaustivity = .off
    return store
  }

  @Test func fullyChangedHugeFileGatesWordDiffWithBanner() async throws {
    let key = DiffDocumentKey(path: "big.txt", source: .workingTree)
    let bigFile = file(path: "big.txt", removed: 1_200, added: 1_200)
    let doc = DiffDocument(file: bigFile, source: .workingTree, loadState: .loading, generation: 1)
    let store = store(doc, key: key)
    await store.send(.streamFileReady(key: key, batch: batch(file: bigFile), token: 1))
    let updated = store.state.openDiffs[key]
    #expect(updated?.wordDiffDisabled == true)
    #expect(updated?.renderBannerKey == .wordDiffOff)  // header affordance — not silent
  }

  @Test func longSingleLineGatesToPlainWithBanner() async throws {
    let key = DiffDocumentKey(path: "min.js", source: .workingTree)
    let minFile = file(path: "min.js", removed: 2, added: 2)
    let longLine = DiffLine(
      origin: .addition, oldLineNumber: nil, newLineNumber: 1,
      content: String(repeating: "x", count: 1_001), noNewlineAtEof: false)
    let doc = DiffDocument(file: minFile, source: .workingTree, loadState: .loading, generation: 1)
    let store = store(doc, key: key)
    await store.send(.streamFileReady(key: key, batch: batch(file: minFile, lines: [longLine]), token: 1))
    let updated = store.state.openDiffs[key]
    #expect(updated?.highlightingDisabled == true)
    #expect(updated?.wordDiffDisabled == true)
    #expect(updated?.renderBannerKey == .plain)
  }

  @Test func normalFileHasNoBanner() async throws {
    let key = DiffDocumentKey(path: "small.txt", source: .workingTree)
    let smallFile = file(path: "small.txt", removed: 1, added: 1)
    let normalLine = DiffLine(
      origin: .addition, oldLineNumber: nil, newLineNumber: 1, content: "hello", noNewlineAtEof: false)
    let doc = DiffDocument(file: smallFile, source: .workingTree, loadState: .loading, generation: 1)
    let store = store(doc, key: key)
    await store.send(.streamFileReady(key: key, batch: batch(file: smallFile, lines: [normalLine]), token: 1))
    let updated = store.state.openDiffs[key]
    #expect(updated?.renderBannerKey == nil)
    #expect(updated?.wordDiffDisabled == false)
    #expect(updated?.highlightingDisabled == false)
  }
}
