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

  /// A stub whose SYNC fast path answers (with `cannedRuns`) only for the given warm
  /// blob OIDs, and returns `nil` (pending) for the rest — so a test can drive the
  /// warm / pending / partial sync branches of `.highlightVisibleRangeChanged`.
  private static func stubHighlight(syncWarmOIDs: Set<String>) -> DiffHighlightClient {
    DiffHighlightClient(
      styleRuns: { _, _ in cannedRuns },
      syncStyleRuns: { input, _ in syncWarmOIDs.contains(input.blobOID) ? cannedRuns : nil },
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
    await store.send(.highlightVisibleRangeChanged(key: key, window: VisibleLineWindow(old: 0..<10, new: 0..<10))) {
      $0.openDiffs[key]?.visibleLineWindow = VisibleLineWindow(old: 0..<10, new: 0..<10)
      $0.openDiffs[key]?.highlightGeneration = 1
    }
    // Supersede BEFORE the debounce elapses → the first effect is cancelled.
    await store.send(.highlightVisibleRangeChanged(key: key, window: VisibleLineWindow(old: 5..<20, new: 5..<20))) {
      $0.openDiffs[key]?.visibleLineWindow = VisibleLineWindow(old: 5..<20, new: 5..<20)
      $0.openDiffs[key]?.highlightGeneration = 2
    }

    await clock.advance(by: .milliseconds(16))
    // Exactly ONE `highlightsReady` arrives (gen 2); the superseded gen-1 pass never
    // delivered (exhaustive TestStore would flag a second unhandled action).
    await store.receive(\.highlightsReady) {
      $0.openDiffs[key]?.oldStyleRuns = Self.cannedRuns
      $0.openDiffs[key]?.newStyleRuns = [:]  // working-tree new side (workdir) not decoded
      $0.openDiffs[key]?.styleRunsVersion = 1  // runs ARRIVED → the view-delivery revision bumps
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
    await store.send(.highlightVisibleRangeChanged(key: key, window: VisibleLineWindow(old: 0..<10, new: 0..<10))) {
      $0.openDiffs[key]?.visibleLineWindow = VisibleLineWindow(old: 0..<10, new: 0..<10)
    }
  }

  /// Phase 1 sync fast path — a WARM parse colors the same reduction and NO async pass
  /// is scheduled (the flash-killer). Old side warm, new side absent (working tree).
  @Test(.dependencies) func syncFastPathPaintsWarmSideAndSkipsAsync() async {
    let key = DiffDocumentKey(path: "a.swift", source: .workingTree)
    let old = HighlightBlobInput(blobOID: "head", utf16: DiffFixture.blob("let x = 1"), path: "a.swift")
    var state = DiffReviewFeature.State()
    state.openDiffs[key] = Self.loadedDoc(oldBlob: old, newBlob: nil)

    let store = TestStore(initialState: state) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffHighlight = Self.stubHighlight(syncWarmOIDs: ["head"])
    }

    // Runs land SYNCHRONOUSLY in the send reduction; no `highlightsReady` follows
    // (exhaustive TestStore would flag a leftover async effect).
    await store.send(.highlightVisibleRangeChanged(key: key, window: VisibleLineWindow(old: 0..<10, new: 0..<10))) {
      $0.openDiffs[key]?.visibleLineWindow = VisibleLineWindow(old: 0..<10, new: 0..<10)
      $0.openDiffs[key]?.highlightGeneration = 1
      $0.openDiffs[key]?.oldStyleRuns = Self.cannedRuns
      $0.openDiffs[key]?.styleRunsVersion = 1
    }
  }

  /// Phase 1 sync fast path — a PENDING side (sync returns nil) falls back to the
  /// async pass, byte-identical to the pre-sync behaviour.
  @Test(.dependencies) func syncFastPathPendingFallsBackToAsync() async {
    let key = DiffDocumentKey(path: "a.swift", source: .workingTree)
    let old = HighlightBlobInput(blobOID: "head", utf16: DiffFixture.blob("let x = 1"), path: "a.swift")
    var state = DiffReviewFeature.State()
    state.openDiffs[key] = Self.loadedDoc(oldBlob: old, newBlob: nil)
    let clock = TestClock()

    let store = TestStore(initialState: state) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.diffHighlight = Self.stubHighlight(syncWarmOIDs: [])  // nothing warm ⇒ all pending
    }

    await store.send(.highlightVisibleRangeChanged(key: key, window: VisibleLineWindow(old: 0..<10, new: 0..<10))) {
      $0.openDiffs[key]?.visibleLineWindow = VisibleLineWindow(old: 0..<10, new: 0..<10)
      $0.openDiffs[key]?.highlightGeneration = 1
    }
    await clock.advance(by: .milliseconds(16))
    await store.receive(\.highlightsReady) {
      $0.openDiffs[key]?.oldStyleRuns = Self.cannedRuns
      $0.openDiffs[key]?.newStyleRuns = [:]
      $0.openDiffs[key]?.styleRunsVersion = 1
    }
  }

  /// Phase 1 sync fast path — PARTIAL warmth: the warm old side paints immediately,
  /// the pending new side still resolves through the async pass.
  @Test(.dependencies) func syncFastPathPartialWarmthPaintsThenAsyncFillsPending() async {
    let key = DiffDocumentKey(path: "a.swift", source: .workingTree)
    let old = HighlightBlobInput(blobOID: "head", utf16: DiffFixture.blob("let x = 1"), path: "a.swift")
    let new = HighlightBlobInput(blobOID: "work", utf16: DiffFixture.blob("let x = 2"), path: "a.swift")
    var state = DiffReviewFeature.State()
    state.openDiffs[key] = Self.loadedDoc(oldBlob: old, newBlob: new)
    let clock = TestClock()

    let store = TestStore(initialState: state) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.diffHighlight = Self.stubHighlight(syncWarmOIDs: ["head"])  // old warm, new pending
    }

    // Old paints synchronously (v1); the async pass then delivers both sides (v2).
    await store.send(.highlightVisibleRangeChanged(key: key, window: VisibleLineWindow(old: 0..<10, new: 0..<10))) {
      $0.openDiffs[key]?.visibleLineWindow = VisibleLineWindow(old: 0..<10, new: 0..<10)
      $0.openDiffs[key]?.highlightGeneration = 1
      $0.openDiffs[key]?.oldStyleRuns = Self.cannedRuns
      $0.openDiffs[key]?.styleRunsVersion = 1
    }
    await clock.advance(by: .milliseconds(16))
    await store.receive(\.highlightsReady) {
      $0.openDiffs[key]?.newStyleRuns = Self.cannedRuns
      $0.openDiffs[key]?.styleRunsVersion = 2
    }
  }
}
