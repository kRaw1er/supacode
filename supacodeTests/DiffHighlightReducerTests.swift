import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Phase 4 — the reducer's neon highlight driver. `visibleRangeChanged` debounces
/// with the injected `TestClock` (never `Task.sleep`), supersedes any in-flight pass,
/// and a stale-generation `highlightsReady` is dropped (pierre `isCurrentRequest`).
@MainActor
struct DiffHighlightReducerTests {

  private static func file(_ path: String = "a.swift") -> FileChange {
    FileChange(
      oldPath: path, newPath: path, status: .modified, addedLines: 1, removedLines: 1,
      isBinary: false, isLargeFileCapped: false, hasLongLines: false, similarity: 0)
  }

  private static func loadedDoc(oldBlob: HighlightBlobInput?, newBlob: HighlightBlobInput?, disabled: Bool = false)
    -> DiffDocument
  {
    var doc = DiffDocument(file: file(), source: .workingTree)
    doc.loadState = .loaded
    doc.oldBlob = oldBlob
    doc.newBlob = newBlob
    doc.highlightingDisabled = disabled
    return doc
  }

  private static let cannedRuns: [Int: [StyleRun]] = [0: [StyleRun(range: 0..<3, capture: "keyword")]]

  private static func stubHighlight() -> DiffHighlightClient {
    DiffHighlightClient(
      styleRuns: { _, _ in cannedRuns },
      isPlain: { _, _, _, _ in false })
  }

  /// 4.12 — debounce + supersede + generation guard.
  @Test(.dependencies) func highlightDriverDebouncesAndGuardsGeneration() async {
    let key = DiffDocumentKey(path: "a.swift", source: .workingTree)
    let old = HighlightBlobInput(blobOID: "head", utf16: DiffFixture.blob("let x = 1"), path: "a.swift")
    var state = DiffReviewFeature.State()
    state.openDiffs[key] = Self.loadedDoc(oldBlob: old, newBlob: nil)
    let clock = TestClock()

    let store = TestStore(initialState: state) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.diffHighlight = Self.stubHighlight()
    }

    // First range: debounce pending, nothing applied yet.
    await store.send(.highlightVisibleRangeChanged(key: key, range: 0..<10)) {
      $0.openDiffs[key]?.visibleLines = 0..<10
      $0.openDiffs[key]?.highlightGeneration = 1
    }
    // Supersede BEFORE the debounce elapses → the first effect is cancelled.
    await store.send(.highlightVisibleRangeChanged(key: key, range: 5..<20)) {
      $0.openDiffs[key]?.visibleLines = 5..<20
      $0.openDiffs[key]?.highlightGeneration = 2
    }

    await clock.advance(by: .milliseconds(16))
    // Exactly ONE `highlightsReady` arrives (gen 2); the superseded gen-1 pass never
    // delivered (exhaustive TestStore would flag a second unhandled action).
    await store.receive(\.highlightsReady) {
      $0.openDiffs[key]?.oldStyleRuns = Self.cannedRuns
      $0.openDiffs[key]?.newStyleRuns = [:]  // working-tree new side (workdir) not decoded
    }
  }

  /// B §14 — a completed-but-superseded result is discarded via the generation token.
  @Test(.dependencies) func cancelledHighlightNotApplied() async {
    let key = DiffDocumentKey(path: "a.swift", source: .workingTree)
    let old = HighlightBlobInput(blobOID: "head", utf16: DiffFixture.blob("let x = 1"), path: "a.swift")
    var doc = Self.loadedDoc(oldBlob: old, newBlob: nil)
    doc.highlightGeneration = 3  // a newer range already advanced the token
    var state = DiffReviewFeature.State()
    state.openDiffs[key] = doc

    let store = TestStore(initialState: state) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffHighlight = Self.stubHighlight()
    }

    // A stale result (generation 2 < live 3) settles WITHOUT applying — no state
    // change (exhaustive TestStore verifies the guard dropped it).
    await store.send(.highlightsReady(key: key, old: Self.cannedRuns, new: [:], generation: 2))
  }

  /// The size gate short-circuits the driver: a highlighting-disabled document only
  /// records the visible range, issues no effect, and applies no runs.
  @Test(.dependencies) func sizeGateShortCircuitsDriver() async {
    let key = DiffDocumentKey(path: "big.swift", source: .workingTree)
    let old = HighlightBlobInput(blobOID: "head", utf16: DiffFixture.blob("let x = 1"), path: "big.swift")
    var state = DiffReviewFeature.State()
    state.openDiffs[key] = Self.loadedDoc(oldBlob: old, newBlob: nil, disabled: true)

    let store = TestStore(initialState: state) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffHighlight = Self.stubHighlight()
    }

    // Only the visible range updates; no effect, no `highlightsReady`, no runs.
    await store.send(.highlightVisibleRangeChanged(key: key, range: 0..<10)) {
      $0.openDiffs[key]?.visibleLines = 0..<10
    }
  }
}
