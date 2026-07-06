import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

/// Phase 5 — the word-diff upstream gate (E 3.4). `WordDiff` enforces only the
/// per-line 1000-char cap; the whole-file ">1000 changed lines per side → no
/// word-diff" decision lives at the DISPATCHER (`WordDiffPolicy`, surfaced onto
/// `DiffDocument.wordDiffDisabled` by the reducer at load), so the render path never
/// invokes `WordDiff` for a massively-changed file. The GIT-FIXTURE arm drives a
/// REAL temp repo through the libgit2 streaming walk into `.streamFileReady`.
@MainActor
@Suite(.serialized)
struct WordDiffGateReducerTests {

  // MARK: - Pure policy boundary

  @Test func policyBoundaryIsPerSideThousand() {
    #expect(WordDiffPolicy.maxChangedLinesPerSide == 1_000)
    #expect(WordDiffPolicy.isDisabled(oldChangedLines: 1_000, newChangedLines: 1_000) == false)
    #expect(WordDiffPolicy.isDisabled(oldChangedLines: 1_001, newChangedLines: 0) == true)  // old side trips
    #expect(WordDiffPolicy.isDisabled(oldChangedLines: 0, newChangedLines: 1_001) == true)  // new side trips
    #expect(WordDiffPolicy.isDisabled(oldChangedLines: 0, newChangedLines: 0) == false)
  }

  // MARK: - GIT-FIXTURE seam

  private static let caps = Libgit2Diff.Caps(byteCap: 8 * 1024 * 1024, lineCap: 50_000, longLineCap: 2_000)

  /// A real working-tree `FileDiffBatch` for `rel` in a temp repo, via the libgit2
  /// streaming walk (no mocks).
  private func batch(root: URL, rel: String) throws -> FileDiffBatch {
    Libgit2Diff.initialize()
    var events: [DiffStreamEvent] = []
    let request = Libgit2Diff.WalkRequest(
      source: .workingTree, caps: Self.caps, contextLines: 3, generation: 1, ignoreWhitespace: false)
    let notCancelled: () -> Bool = { false }
    try Libgit2Diff.streamChangedFiles(at: root, request, isCancelled: notCancelled) { events.append($0) }
    let ready = events.compactMap { if case .fileReady(let batch) = $0 { batch } else { nil } }
    return try #require(ready.first { $0.file.id == rel })
  }

  private func store(document: DiffDocument, key: DiffDocumentKey) -> TestStoreOf<DiffReviewFeature> {
    var state = DiffReviewFeature.State()
    state.openDiffs[key] = document
    let store = TestStore(initialState: state) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffHighlight = DiffHighlightClient(styleRuns: { _, _ in [:] }, isPlain: { _, _, _, _ in false })
      $0.diffStreamConsumer = DiffStreamConsumerClient(
        begin: { _, _, _, _ in }, consume: { _, _, _ in }, finish: { _, _ in })
    }
    store.exhaustivity = .off
    return store
  }

  /// A file whose new side has > 1000 changed lines gates word-diff OFF at load, so
  /// `WordDiff` is never invoked for it on the render path.
  @Test func wordDiffGateEnforcedUpstream() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    let original = (1...1_200).map { "old line \($0)" }.joined(separator: "\n") + "\n"
    try GitFixture.write(original, to: "big.txt", in: root)
    try GitFixture.stage("big.txt", in: root)
    try GitFixture.commit("seed", in: root)
    // Replace every line → > 1000 changed lines on both sides.
    let edited = (1...1_200).map { "new line \($0)" }.joined(separator: "\n") + "\n"
    try GitFixture.write(edited, to: "big.txt", in: root)

    let bigBatch = try batch(root: root, rel: "big.txt")
    #expect(max(bigBatch.file.removedLines, bigBatch.file.addedLines) > 1_000)

    let key = DiffDocumentKey(path: "big.txt", source: .workingTree)
    let store = store(
      document: DiffDocument(file: bigBatch.file, source: .workingTree, loadState: .loading, generation: 1), key: key)
    await store.send(.streamFileReady(key: key, batch: bigBatch, token: 1))
    // The dispatcher gated it: the render path reads this and never calls `WordDiff`.
    #expect(store.state.openDiffs[key]?.wordDiffDisabled == true)
  }

  /// A small change keeps word-diff ENABLED (the gate is not over-eager).
  @Test func smallChangeKeepsWordDiffEnabled() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("alpha\nbeta\ngamma\n", to: "small.txt", in: root)
    try GitFixture.stage("small.txt", in: root)
    try GitFixture.commit("seed", in: root)
    try GitFixture.write("alpha\nBETA\ngamma\n", to: "small.txt", in: root)

    let smallBatch = try batch(root: root, rel: "small.txt")
    #expect(max(smallBatch.file.removedLines, smallBatch.file.addedLines) <= 1_000)

    let key = DiffDocumentKey(path: "small.txt", source: .workingTree)
    let store = store(
      document: DiffDocument(file: smallBatch.file, source: .workingTree, loadState: .loading, generation: 1),
      key: key)
    await store.send(.streamFileReady(key: key, batch: smallBatch, token: 1))
    #expect(store.state.openDiffs[key]?.wordDiffDisabled == false)
  }
}
