import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// CAT 6 — regression guards that pin the SHAPE of the fix so the specific "all white"
/// defects cannot silently return: each blob side must be queried with ITS OWN 1-based
/// line range (defect A was one shared rendered-row range fed to both sides), and a
/// side with no visible lines must not be queried at all. Complements the pure
/// `DiffHighlightClientConversionTests` (the ±1 line↔blob boundary) and
/// `DiffVisibleLineRangeTests` (rows → per-side line numbers).
@MainActor
struct DiffHighlightRegressionGuardTests {
  private static func file(_ path: String = "a.swift") -> FileChange {
    FileChange(
      oldPath: path, newPath: path, status: .modified, addedLines: 1, removedLines: 1,
      isBinary: false, isLargeFileCapped: false, hasLongLines: false, similarity: 0)
  }

  private static func loadedDoc(old: Bool, new: Bool) -> DiffDocument {
    var doc = DiffDocument(file: file(), source: .workingTree)
    doc.loadState = .loaded
    if old { doc.oldBlob = HighlightBlobInput(blobOID: "OLD", utf16: DiffFixture.blob("let x = 1"), path: "a.swift") }
    if new { doc.newBlob = HighlightBlobInput(blobOID: "NEW", utf16: DiffFixture.blob("let y = 2"), path: "a.swift") }
    return doc
  }

  private let key = DiffDocumentKey(path: "a.swift", source: .workingTree)

  private func store(
    _ clock: TestClock<Duration>, old: Bool = true, new: Bool = true,
    recorder: LockIsolated<[(oid: String, range: Range<Int>)]>
  ) -> TestStoreOf<DiffReviewFeature> {
    var state = DiffReviewFeature.State()
    state.openDiffs[key] = Self.loadedDoc(old: old, new: new)
    let store = TestStore(initialState: state) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.diffHighlight = DiffHighlightClient(
        styleRuns: { input, range in
          recorder.withValue { $0.append((input.blobOID, range)) }
          return [:]
        },
        isPlain: { _, _, _, _ in false })
    }
    store.exhaustivity = .off
    return store
  }

  /// Defect A guard: the OLD blob is queried with the OLD visible line range and the
  /// NEW blob with the NEW range — never one shared range for both sides.
  @Test(.dependencies) func eachSideQueriedWithItsOwnLineRange() async {
    let clock = TestClock()
    let recorder = LockIsolated<[(oid: String, range: Range<Int>)]>([])
    let store = store(clock, recorder: recorder)

    await store.send(
      .highlightVisibleRangeChanged(key: key, window: VisibleLineWindow(old: 10..<15, new: 100..<105)))
    await clock.advance(by: .milliseconds(16))
    await store.receive(\.highlightsReady)

    let calls = recorder.value
    #expect(calls.contains { $0.oid == "OLD" && $0.range == 10..<15 }, "old side must be queried with the OLD range")
    #expect(calls.contains { $0.oid == "NEW" && $0.range == 100..<105 }, "new side must be queried with the NEW range")
    #expect(
      !calls.contains { $0.oid == "OLD" && $0.range == 100..<105 }, "the new range must not be fed to the old blob")
  }

  /// A side with no visible lines (e.g. an addition-only hunk shows no old lines) is
  /// not queried at all — no wasted parse, no empty-window round trip.
  @Test(.dependencies) func emptySideIsNotQueried() async {
    let clock = TestClock()
    let recorder = LockIsolated<[(oid: String, range: Range<Int>)]>([])
    let store = store(clock, recorder: recorder)

    await store.send(
      .highlightVisibleRangeChanged(key: key, window: VisibleLineWindow(old: 0..<0, new: 5..<9)))
    await clock.advance(by: .milliseconds(16))
    await store.receive(\.highlightsReady)

    let calls = recorder.value
    #expect(!calls.contains { $0.oid == "OLD" }, "an empty old side must not issue a query")
    #expect(calls.contains { $0.oid == "NEW" && $0.range == 5..<9 }, "the non-empty new side is still queried")
  }
}
