import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// CAT 5 — async ordering + staleness of the highlight driver. Highlighting is a
/// debounced, superseding, generation-guarded effect whose result arrives AFTER the
/// content already rendered; the view keys delivery off `styleRunsVersion` (the
/// delivery revision) — NOT `highlightGeneration` (the request token), the exact
/// confusion that once "skipped the arriving colors". These pin: every real arrival
/// bumps the delivery revision, a superseded/stale generation is dropped, and both
/// blob sides deliver independently. All virtual-time (`TestClock`), no `Task.sleep`.
@MainActor
struct DiffHighlightAsyncOrderingTests {
  private static func file(_ path: String = "a.swift") -> FileChange {
    FileChange(
      oldPath: path, newPath: path, status: .modified, addedLines: 1, removedLines: 1,
      isBinary: false, isLargeFileCapped: false, hasLongLines: false, similarity: 0)
  }

  private static func loadedDoc() -> DiffDocument {
    var doc = DiffDocument(file: file(), source: .workingTree)
    doc.loadState = .loaded
    doc.oldBlob = HighlightBlobInput(blobOID: "old", utf16: DiffFixture.blob("let x = 1"), path: "a.swift")
    doc.newBlob = HighlightBlobInput(blobOID: "new", utf16: DiffFixture.blob("let y = 2"), path: "a.swift")
    return doc
  }

  private static let oldRuns: [Int: [StyleRun]] = [1: [StyleRun(range: 0..<3, capture: "keyword")]]
  private static let newRuns: [Int: [StyleRun]] = [2: [StyleRun(range: 0..<3, capture: "keyword")]]

  private static func stub() -> DiffHighlightClient {
    DiffHighlightClient(
      styleRuns: { input, _ in input.blobOID == "old" ? oldRuns : newRuns },
      isPlain: { _, _, _, _ in false })
  }

  private func store(_ clock: TestClock<Duration>) -> TestStoreOf<DiffReviewFeature> {
    let key = DiffDocumentKey(path: "a.swift", source: .workingTree)
    var state = DiffReviewFeature.State()
    state.openDiffs[key] = Self.loadedDoc()
    return TestStore(initialState: state) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.diffHighlight = Self.stub()
    }
  }

  private let key = DiffDocumentKey(path: "a.swift", source: .workingTree)
  private func window(_ range: Range<Int>) -> VisibleLineWindow { VisibleLineWindow(old: range, new: range) }

  /// Each real arrival bumps `styleRunsVersion` (the view-delivery revision) and stores
  /// BOTH sides' runs — even though the content rendered long before.
  @Test(.dependencies) func eachArrivalBumpsDeliveryVersionAndStoresBothSides() async {
    let clock = TestClock()
    let store = store(clock)

    await store.send(.highlightVisibleRangeChanged(key: key, window: window(1..<10))) {
      $0.openDiffs[self.key]?.visibleLineWindow = self.window(1..<10)
      $0.openDiffs[self.key]?.highlightGeneration = 1
    }
    await clock.advance(by: .milliseconds(16))
    await store.receive(\.highlightsReady) {
      $0.openDiffs[self.key]?.oldStyleRuns = Self.oldRuns
      $0.openDiffs[self.key]?.newStyleRuns = Self.newRuns
      $0.openDiffs[self.key]?.styleRunsVersion = 1
    }

    // A second visible range → a second delivery bumps the revision again.
    await store.send(.highlightVisibleRangeChanged(key: key, window: window(20..<30))) {
      $0.openDiffs[self.key]?.visibleLineWindow = self.window(20..<30)
      $0.openDiffs[self.key]?.highlightGeneration = 2
    }
    await clock.advance(by: .milliseconds(16))
    await store.receive(\.highlightsReady) {
      $0.openDiffs[self.key]?.styleRunsVersion = 2
    }
  }

  /// A burst of scroll changes supersedes in-flight passes: only the LAST generation
  /// delivers, and a straggler `highlightsReady` from a superseded generation is
  /// dropped (pierre `isCurrentRequest`).
  @Test(.dependencies) func supersededAndStaleGenerationsAreDropped() async {
    let clock = TestClock()
    let store = store(clock)

    await store.send(.highlightVisibleRangeChanged(key: key, window: window(1..<10))) {
      $0.openDiffs[self.key]?.visibleLineWindow = self.window(1..<10)
      $0.openDiffs[self.key]?.highlightGeneration = 1
    }
    await store.send(.highlightVisibleRangeChanged(key: key, window: window(5..<15))) {
      $0.openDiffs[self.key]?.visibleLineWindow = self.window(5..<15)
      $0.openDiffs[self.key]?.highlightGeneration = 2
    }
    await clock.advance(by: .milliseconds(16))
    // Exactly ONE delivery (gen 2); gen 1 was cancelled in flight.
    await store.receive(\.highlightsReady) {
      $0.openDiffs[self.key]?.oldStyleRuns = Self.oldRuns
      $0.openDiffs[self.key]?.newStyleRuns = Self.newRuns
      $0.openDiffs[self.key]?.styleRunsVersion = 1
    }
    // A straggler from the superseded gen 1 settles WITHOUT applying (no state change).
    await store.send(.highlightsReady(key: key, old: [:], new: [:], generation: 1))
  }

  /// A visible-range change on a file with NOTHING to highlight (both blobs nil —
  /// plain-text / no bundled grammar) must still CLEAR any previously-arrived style runs
  /// AND bump the delivery revision so the view repaints plain. The handler's comment
  /// always promised this; it used to only bump `highlightGeneration` and skip, leaving
  /// stale colors keyed off the unchanged `styleRunsVersion`. No async effect fires.
  @Test(.dependencies) func noBlobRangeChangeClearsStaleRunsAndBumpsDeliveryVersion() async {
    let clock = TestClock()
    var doc = Self.loadedDoc()
    doc.oldBlob = nil  // nothing to highlight on either side
    doc.newBlob = nil
    doc.oldStyleRuns = Self.oldRuns  // stale runs from an earlier highlight still linger
    doc.newStyleRuns = Self.newRuns
    doc.styleRunsVersion = 7
    var state = DiffReviewFeature.State()
    state.openDiffs[key] = doc
    let store = TestStore(initialState: state) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.diffHighlight = Self.stub()
    }

    await store.send(.highlightVisibleRangeChanged(key: key, window: window(1..<10))) {
      $0.openDiffs[self.key]?.visibleLineWindow = self.window(1..<10)
      $0.openDiffs[self.key]?.highlightGeneration = 1
      $0.openDiffs[self.key]?.oldStyleRuns = [:]  // the promised clear now actually happens
      $0.openDiffs[self.key]?.newStyleRuns = [:]
      $0.openDiffs[self.key]?.styleRunsVersion = 8  // bumped so the view keys the plain repaint
    }
    // Both blobs nil ⇒ the async highlight effect is skipped entirely (nothing to receive).
    await store.finish()
  }
}
