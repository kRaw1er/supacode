import AppKit
import CoreText
import Testing

@testable import supacode

/// Phase 11 — offscreen diff-body search over the frozen `[UInt16]` blob stores
/// (`DiffSearchController.scan` over `UTF16LineStore.nsString`), NOT the rendered
/// views. Covers: an offscreen (folded) match found via the blob scan; the
/// context-line no-double-report (old scan restricted to `deletedOldLines`); an
/// unresolvable (`.widget`-row) match skipped + logged, never a crash; the
/// expand→reveal→highlight seam ordering with no full-file re-diff; coverage as a
/// first-class value on every bound (binary / capped / not-streamed / match ceiling);
/// and invisibles searchable without drop or duplication.
@MainActor
struct DiffSearchControllerTests {
  // MARK: - Helpers

  /// A store built from a Swift string's UTF-16 (Phase 9 blob analog).
  private func store(_ text: String) -> UTF16LineStore { UTF16LineStore(bridging: text) }

  private func file(
    id: FileChange.ID = "a.swift",
    binary: Bool = false,
    capped: Bool = false,
    newStore: UTF16LineStore? = nil,
    oldStore: UTF16LineStore? = nil,
    deletedOldLines: Set<Int> = []
  ) -> SearchableFile {
    SearchableFile(
      id: id, isBinary: binary, isLargeFileCapped: capped,
      newStore: newStore, oldStore: oldStore, deletedOldLines: deletedOldLines)
  }

  /// A controller whose nav closures record into the given sinks; `rowForLine`
  /// defaults to "everything folded" so nav exercises the expand path.
  private func controller(
    reveal: @escaping (Int) -> Void = { _ in },
    expandToReveal: @escaping (DiffSide, Int) -> Int? = { _, _ in nil },
    rowForLine: @escaping (DiffSide, Int) -> Int? = { _, _ in nil }
  ) -> DiffSearchController {
    DiffSearchController(
      tree: ChunkTree(), reveal: reveal, expandToReveal: expandToReveal, rowForLine: rowForLine)
  }

  // MARK: - C 13.1 offscreen match found via the blob scan

  @Test func offscreenMatchFoundViaBlobScan() {
    // NEEDLE lives on store line index 2, which `rowForLine` reports as folded
    // (offscreen) — the match is found from the buffer, not from a rendered row.
    let newStore = store("alpha\nbeta\nNEEDLE_here\ngamma\n")
    var revealed: [Int] = []
    var expanded: [Int] = []
    let subject = controller(
      reveal: { revealed.append($0) },
      expandToReveal: { _, line in
        expanded.append(line)
        return 42
      },
      rowForLine: { _, _ in nil })

    subject.search("needle", files: [file(newStore: newStore)])  // case-insensitive

    #expect(subject.matches.count == 1)
    #expect(subject.matches.first?.side == .new)
    #expect(subject.matches.first?.lineNumber == 2)  // 0-based store index of the folded line
    #expect(subject.coverage.scannedFiles == 1)
    #expect(subject.coverage.isCapped == false)

    subject.next()  // folded → expand THEN reveal
    #expect(expanded == [2])
    #expect(revealed == [42])
    #expect(subject.current == 0)
  }

  // MARK: - C 13.3 context line is not double-reported

  @Test func contextLineNotDoubleReported() {
    // "keep foo" is byte-identical context on BOTH sides (new line 0 / old line 0).
    // "add foo" is a new-only addition; "del foo" is an old-only deletion.
    let newStore = store("keep foo\nadd foo\n")
    let oldStore = store("keep foo\ndel foo\n")
    let subject = controller()

    subject.search(
      "foo",
      files: [file(newStore: newStore, oldStore: oldStore, deletedOldLines: [1])])  // old line 1 is the only deletion

    let newMatches = subject.matches.filter { $0.side == .new }
    let oldMatches = subject.matches.filter { $0.side == .old }
    #expect(newMatches.count == 2)  // keep foo + add foo, BOTH from the new blob
    #expect(oldMatches.count == 1)  // del foo only
    #expect(oldMatches.first?.lineNumber == 1)
    // The old-side "keep foo" (line 0) is NOT reported — it is not a deletion, so the
    // context match found on the new side is never duplicated.
    #expect(!oldMatches.contains { $0.lineNumber == 0 })
  }

  // MARK: - C 13.2 unresolvable (widget) match skipped, never crashes

  @Test func unresolvableMatchSkippedNotCrash() {
    // A hit whose line is neither a materialized row (`rowForLine` → nil) nor
    // expandable (`expandToReveal` → nil) is skipped on nav — logged, no reveal, no
    // crash. This is the `.widget`-row case (a header/comment line has no `DiffSide`).
    let newStore = store("header widget line\n")
    var revealed: [Int] = []
    let subject = controller(
      reveal: { revealed.append($0) },
      expandToReveal: { _, _ in nil },
      rowForLine: { _, _ in nil })

    subject.search("widget", files: [file(newStore: newStore)])
    #expect(subject.matches.count == 1)

    subject.next()  // must not crash
    #expect(subject.current == 0)  // the cursor still advances
    #expect(revealed.isEmpty)  // but nothing is revealed (unresolvable)
  }

  // MARK: - E 7.1 = C 13.2 expand → reveal → highlight seam order (no re-diff)

  private enum SeamEvent: Equatable {
    case blobSlice(Int)  // BlobSliceClient.slice (Phase 7) — NOT a full re-diff
    case reDiff  // DiffClient.diff — must NEVER happen on expand
    case reveal(Int)  // Phase 10
    case searchRect  // SearchMatchLayer paint
  }

  @Test func expandThenRevealThenHighlightOrder() {
    var events: [SeamEvent] = []
    // HIT is folded on store line 2; `rowForLine` → nil forces the expand path.
    let newStore = store("a\nb\nHIT here\nc\n")
    let subject = controller(
      reveal: { events.append(.reveal($0)) },
      expandToReveal: { _, line in
        events.append(.blobSlice(line))  // Phase-7 incremental slice, not a re-diff
        return 7
      },
      rowForLine: { _, _ in nil })

    subject.search("hit", files: [file(newStore: newStore)])
    subject.next()

    // Highlight pass: paint the current match's rect via `SearchMatchLayer` (CT).
    guard let index = subject.current else {
      Issue.record("no current match")
      return
    }
    let match = subject.matches[index]
    let lineContent = newStore.line(match.lineNumber)
    let ctLine = CoreTextHarness.ctLine(lineContent)
    let sub = WrappedSubLine(
      line: ctLine, origin: CGPoint(x: 0, y: 100),
      ascent: CoreTextHarness.font.ascender, descent: -CoreTextHarness.font.descender)
    let recording = RecordingContext()
    SearchMatchLayer.paint(
      SearchMatchLayer.LineMatches(content: lineContent, ranges: [match.utf16Range], active: match.utf16Range),
      subLines: [sub],
      colors: .init(match: DiffPalette.shared.searchMatch.cgColor, active: DiffPalette.shared.searchCurrent.cgColor),
      scale: 2, in: recording)
    #expect(!recording.fills.isEmpty)
    events.append(.searchRect)

    // The gap expands FIRST (blob slice), THEN reveal, THEN the highlight rect.
    #expect(events == [.blobSlice(2), .reveal(7), .searchRect])
    // Regression: no full-file re-diff was triggered by the expand.
    #expect(!events.contains(.reDiff))
  }

  // MARK: - E 7.2 = C 13.4 coverage is never a silent cut

  @Test func searchCoverageNeverSilentCutBinary() {
    let subject = controller()
    subject.search("x", files: [file(id: "bin", binary: true, newStore: store("x\n"))])
    #expect(subject.matches.isEmpty)
    #expect(subject.coverage.scannedFiles == 0)
    #expect(subject.coverage.isCapped)
    #expect(subject.coverage.skipped == [.init(fileID: "bin", reason: .binary)])
  }

  @Test func searchCoverageNeverSilentCutCapped() {
    let subject = controller()
    subject.search("x", files: [file(id: "big", capped: true, newStore: store("x\n"))])
    #expect(subject.coverage.isCapped)
    #expect(subject.coverage.skipped.map(\.reason) == [.largeFileCapped])
  }

  @Test func searchCoverageNeverSilentCutNotMaterialized() {
    let subject = controller()
    // Batch not streamed in yet: both stores nil → a re-runnable skip, never silent.
    subject.search("x", files: [file(id: "pending", newStore: nil, oldStore: nil)])
    #expect(subject.coverage.isCapped)
    #expect(subject.coverage.skipped.map(\.reason) == [.blobNotMaterialized])
  }

  @Test func searchCoverageNeverSilentCutMatchCeiling() {
    // A corpus with MORE than `maxMatches` (20_000) hits: the scan stops at the
    // ceiling and REPORTS it (Coverage + log) rather than silently truncating.
    let bigStore = store(String(repeating: "x\n", count: 20_005))
    let subject = controller()
    subject.search("x", files: [file(newStore: bigStore)])
    #expect(subject.matches.count == 20_000)  // exactly the ceiling
    #expect(subject.coverage.matchCeilingReached)
    #expect(subject.coverage.isCapped)
  }

  // MARK: - listFilterSubstringNotSubsequence — the matcher is SUBSTRING, not subsequence

  @Test func listFilterSubstringNotSubsequence() {
    // "foobar" on one store line. A subsequence matcher would match "fb" (f…b); the
    // shipped matcher is case-insensitive SUBSTRING (`.literal`), so only contiguous
    // runs match — "fb" must NOT match, "oob"/"BAR" must.
    let newStore = store("foobar\n")
    let target = file(newStore: newStore)

    // "fb" is an in-order SUBSEQUENCE of "foobar" (f…b) but not a substring ⇒ NO match.
    let subsequence = controller()
    subsequence.search("fb", files: [target])
    #expect(subsequence.matches.isEmpty)

    // A contiguous substring in the middle matches (case-insensitive).
    let mid = controller()
    mid.search("oob", files: [target])
    #expect(mid.matches.count == 1)
    #expect(mid.matches.first?.utf16Range == 1..<4)  // "oob" at offset 1

    // Case-insensitive substring, not subsequence, at the tail.
    let tail = controller()
    tail.search("BAR", files: [target])
    #expect(tail.matches.count == 1)
    #expect(tail.matches.first?.utf16Range == 3..<6)  // "bar" at offset 3

    // Reversed order ("rab") is neither a substring nor an in-order subsequence ⇒ none.
    let reversed = controller()
    reversed.search("rab", files: [target])
    #expect(reversed.matches.isEmpty)
  }

  // MARK: - D §6 SRCH invisibles searchable (no drop, no duplication)

  @Test func invisiblesSearchable() {
    let zwsp = UnicodeFixtures.zwsp
    let bom = UnicodeFixtures.bom
    let nbsp = UnicodeFixtures.nbsp
    // Each invisible appears EXACTLY once across the blob.
    let newStore = store("a\(zwsp)b\n\(bom)x\ny\(nbsp)z\n")
    let subject = controller()
    let target = file(newStore: newStore)

    subject.search(zwsp, files: [target])
    #expect(subject.matches.count == 1)  // found, not dropped
    #expect(subject.matches.first?.lineNumber == 0)

    subject.search(bom, files: [target])
    #expect(subject.matches.count == 1)
    #expect(subject.matches.first?.lineNumber == 1)

    subject.search(nbsp, files: [target])
    #expect(subject.matches.count == 1)  // nbsp is NOT folded into a normal space (.literal)
    #expect(subject.matches.first?.lineNumber == 2)

    // A zero-width match still progresses `from` (max(1,len)) — a single occurrence is
    // reported once, never an infinite duplicate.
    #expect(subject.matches.count == 1)
  }
}
