import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import SupacodeSettingsShared
@testable import supacode

/// Phase 13 seam-swap coverage: the reducer scope-down (deleted `rows`/`revision`/
/// `buildRows`), the KEPT pipelines proven against the tree-backed seam, the
/// merge-conflict parse/strip, the conflict-widget chunk emission, and the
/// grep-gate that the retired render symbols have zero live references.
@MainActor
struct DiffSeamSwapReducerTests {
  // MARK: - Fixtures

  private func worktree() -> Worktree {
    Worktree(
      id: WorktreeID("/tmp/repo/wtree"), name: "wtree", detail: "",
      workingDirectory: URL(filePath: "/tmp/repo/wtree"), repositoryRootURL: URL(filePath: "/tmp/repo"))
  }

  private func file(_ path: String = "a.swift", status: FileStatus = .modified) -> FileChange {
    FileChange(
      oldPath: path, newPath: path, status: status, addedLines: 1, removedLines: 1,
      isBinary: false, isLargeFileCapped: false, hasLongLines: false, similarity: 0)
  }

  private func modifiedHunk() -> DiffHunk {
    DiffHunk(
      oldStart: 1, oldCount: 2, newStart: 1, newCount: 2, header: "@@ -1,2 +1,2 @@",
      lines: [
        DiffLine(origin: .context, oldLineNumber: 1, newLineNumber: 1, content: "keep", noNewlineAtEof: false),
        DiffLine(origin: .deletion, oldLineNumber: 2, newLineNumber: nil, content: "old", noNewlineAtEof: false),
        DiffLine(origin: .addition, oldLineNumber: nil, newLineNumber: 2, content: "new", noNewlineAtEof: false),
      ])
  }

  // MARK: - C 16.6 — the scope-down arms never touch a flat row / revision

  @Test(.dependencies) func scopeDownArmsDoNotTouchRowsRevision() async {
    let wtree = worktree()
    let fileChange = file()
    let hunks = [modifiedHunk()]
    let key = DiffDocumentKey(path: fileChange.id, source: .workingTree)
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = wtree
    initialState.files = [fileChange]
    initialState.loadState = .loaded
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
      $0.terminalClient.send = { _ in }
      $0.diffClient.diff = { _, _, _, _ in hunks }
    }
    store.exhaustivity = .off

    // open → diffLoaded stores hunks for the tree viewport; there is no `rows` /
    // `revision` field to write (deleted), and the document projects from hunks.
    await store.send(.openFile(path: fileChange.id, source: .workingTree))
    await store.receive(\.diffLoaded)
    #expect(store.state.openDiffs[key]?.hunks == hunks)
    #expect(store.state.openDiffs[key]?.loadState == .loaded)

    // mode toggle is a global re-seek: the document (its hunks) is untouched.
    await store.send(.diffModeChanged(.split))
    #expect(store.state.diffViewMode == .split)
    #expect(store.state.openDiffs[key]?.hunks == hunks)

    // committing a comment mutates only `state.comments` (the viewport reconciles
    // its widget); the document's hunks are never rebuilt into a flat row list.
    let comment = ReviewComment(
      id: UUID(), filePath: fileChange.id, side: .new, startLine: 2, endLine: 2,
      anchorSnippet: "new", contextBefore: "", body: "fix", createdAt: Date(timeIntervalSince1970: 0))
    await store.send(.commitComment(comment))
    #expect(store.state.comments[id: comment.id] != nil)
    #expect(store.state.openDiffs[key]?.hunks == hunks)
    await store.finish()
  }

  // MARK: - C 16.4 — the highlight driver's generation guard survives the swap

  @Test(.dependencies) func highlightDriverScopeDown() async {
    let fileChange = file()
    let key = DiffDocumentKey(path: fileChange.id, source: .workingTree)
    var document = DiffDocument(file: fileChange, loadState: .loaded, generation: 1)
    document.hunks = [modifiedHunk()]
    document.highlightGeneration = 5
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = worktree()
    initialState.openDiffs = [key: document]
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off

    // A visible-range change bumps the generation + records the range. Both blobs
    // are nil (plain file) so no highlight effect is issued — deterministic.
    await store.send(.highlightVisibleRangeChanged(key: key, window: VisibleLineWindow(old: 0..<40, new: 0..<40)))
    #expect(store.state.openDiffs[key]?.visibleLineWindow == VisibleLineWindow(old: 0..<40, new: 0..<40))
    #expect(store.state.openDiffs[key]?.highlightGeneration == 6)

    // A stale `.highlightsReady` (superseded generation) is dropped (pierre
    // isCurrentRequest); a live one applies.
    let runs = [0: [StyleRun(range: 0..<3, capture: "keyword")]]
    await store.send(.highlightsReady(key: key, old: runs, new: [:], generation: 3))
    #expect(store.state.openDiffs[key]?.oldStyleRuns.isEmpty == true)
    await store.send(.highlightsReady(key: key, old: runs, new: [:], generation: 6))
    #expect(store.state.openDiffs[key]?.oldStyleRuns == runs)
  }

  // MARK: - C 16.5 — expand uses the blob-slice path, never a raised-context re-diff

  @Test(.dependencies) func expansionReplacesMillionContext() async {
    let fileChange = file()
    let key = DiffDocumentKey(path: fileChange.id, source: .workingTree)
    // Two hunks with an inter-hunk gap → GapKey(1).
    let hunk0 = DiffHunk(
      oldStart: 1, oldCount: 1, newStart: 1, newCount: 1, header: "@@",
      lines: [DiffLine(origin: .context, oldLineNumber: 1, newLineNumber: 1, content: "a", noNewlineAtEof: false)])
    let hunk1 = DiffHunk(
      oldStart: 40, oldCount: 1, newStart: 40, newCount: 1, header: "@@",
      lines: [DiffLine(origin: .context, oldLineNumber: 40, newLineNumber: 40, content: "z", noNewlineAtEof: false)])
    var document = DiffDocument(file: fileChange, loadState: .loaded, generation: 1)
    document.hunks = [hunk0, hunk1]
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = worktree()
    initialState.files = [fileChange]
    initialState.openDiffs = [key: document]
    initialState.diffLoadToken = 1
    let diffCalls = LockIsolated(0)
    let sliceCalls = LockIsolated(0)
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.diffClient.diff = { _, _, _, _ in
        diffCalls.withValue { $0 += 1 }
        return []
      }
      $0.blobSliceClient.slice = { _, _, _, range, _ in
        sliceCalls.withValue { $0 += 1 }
        return range.map {
          DiffLine(origin: .context, oldLineNumber: $0, newLineNumber: $0, content: "ctx", noNewlineAtEof: false)
        }
      }
    }
    store.exhaustivity = .off

    await store.send(.expandGap(key: key, gap: 1, step: .fine, direction: .up))
    await store.receive(\.gapSliceLoaded)
    await store.finish()

    #expect(sliceCalls.value == 1)  // the incremental blob slice fired
    #expect(diffCalls.value == 0)  // NEVER a `DiffClient.diff` at raised context
  }

  // MARK: - E 12.1 — the send-to-agent pipeline survives the render swap

  @Test(.dependencies) func sendBatchSurvivesRenderSwap() async {
    let wtree = worktree()
    let comment = ReviewComment(
      id: UUID(), filePath: "a.swift", side: .new, startLine: 2, endLine: 2,
      anchorSnippet: "new", contextBefore: "", body: "please fix", createdAt: Date(timeIntervalSince1970: 0))
    let sent = LockIsolated<[TerminalClient.Command]>([])
    var initialState = DiffReviewFeature.State()
    initialState.selectedWorktree = wtree
    initialState.comments = [comment]
    let store = TestStore(initialState: initialState) {
      DiffReviewFeature()
    } withDependencies: {
      $0.continuousClock = TestClock()
      $0.terminalClient.hasAgentTerminalSurface = { _ in true }
      $0.terminalClient.send = { command in sent.withValue { $0.append(command) } }
    }

    await store.send(.sendBatchToAgent) { $0.batchLocked = true }
    await store.receive(.sendBatchFinished(.sent)) {
      $0.comments.removeAll()
      $0.batchLocked = false
    }
    await store.finish()
    #expect(sent.value.count == 1)  // the rebuild targets the model, not deleted rows
  }

  // MARK: - E 12.2 — sanitize still strips the injection surface

  @Test func sanitizeControlCharsHolds() {
    let raw = "keep\n\ttab\u{1B}[31mesc\u{7F}del\u{202E}bidi\u{200B}zw"
    let clean = ReviewPromptBuilder.sanitizeControlChars(raw)
    #expect(clean == "keep\n\ttab[31mescdelbidizw")  // \n / \t kept; C0 / DEL / bidi / zero-width stripped
    #expect(!clean.unicodeScalars.contains { $0.value == 0x1B })
    #expect(!clean.unicodeScalars.contains { $0.value == 0x7F })
    #expect(!clean.unicodeScalars.contains { $0.value == 0x202E })
    #expect(!clean.unicodeScalars.contains { $0.value == 0x200B })
  }

  // MARK: - B §22 — merge-conflict line classification (2-way / 3-way / nested)

  @Test func mergeConflictLineTypesClassify() {
    let twoWay = ["<<<<<<< ours", "a", "=======", "b", ">>>>>>> theirs"]
    #expect(
      MergeConflict.lineTypes(twoWay) == [.markerStart, .current, .markerSeparator, .incoming, .markerEnd])

    let threeWay = ["<<<<<<< ours", "a", "||||||| base", "o", "=======", "b", ">>>>>>> theirs"]
    #expect(
      MergeConflict.lineTypes(threeWay)
        == [.markerStart, .current, .markerBase, .base, .markerSeparator, .incoming, .markerEnd])

    // Nested via a stack: an inner conflict inside the ours section.
    let nested = ["<<<<<<< A", "x", "<<<<<<< B", "y", "=======", "z", ">>>>>>> B", "=======", "w", ">>>>>>> A"]
    let types = MergeConflict.lineTypes(nested)
    #expect(types.first == .markerStart)
    #expect(types.last == .markerEnd)
    #expect(types.filter { $0 == .markerStart }.count == 2)  // both opens recognized
    #expect(types.filter { $0 == .markerEnd }.count == 2)  // both closes popped

    // A bare `=======` outside any region is ordinary content, not a marker.
    #expect(MergeConflict.lineTypes(["=======", "plain"]) == [.none, .none])
  }

  // MARK: - B §23 — resolve strips ALL separators (incl. a multi-conflict hunk)

  @Test func resolveConflictStripsAllSeparators() {
    let lines = [
      "top",
      "<<<<<<< ours", "a1", "=======", "b1", ">>>>>>> theirs",
      "middle",
      "<<<<<<< ours", "a2", "||||||| base", "o2", "=======", "b2", ">>>>>>> theirs",
      "bottom",
    ]
    let ours = MergeConflict.resolve(lines, keeping: .current)
    #expect(ours == ["top", "a1", "middle", "a2", "bottom"])  // both conflicts resolved, every marker gone
    #expect(!ours.contains { $0.hasPrefix("<<<<<<<") || $0.hasPrefix("=======") || $0.hasPrefix(">>>>>>>") })
    #expect(!ours.contains { $0.hasPrefix("|||||||") })  // 3-way base section stripped too
  }

  // MARK: - B §21 — a second conflict in the same hunk stays independently resolvable

  /// Pure proxy for the sequential-resolve regression. The reducer/`gitClient`
  /// accept-WRITE-to-disk is a DEFERRED follow-up (§442), so this pins the parse
  /// layer both resolutions ride: resolving conflict 0 to ours and conflict 1 to
  /// theirs keeps each side independently — the second is never dropped.
  @Test func sequentialResolveKeepsSecondConflictLive() {
    let hunk = [
      "<<<<<<< ours", "keepOurs", "=======", "dropTheirs", ">>>>>>> theirs",
      "<<<<<<< ours", "dropOurs", "=======", "keepTheirs", ">>>>>>> theirs",
    ]
    // Region 0 alone → resolvable to ours.
    let first = Array(hunk[0..<5])
    #expect(MergeConflict.resolve(first, keeping: .current) == ["keepOurs"])
    #expect(ConflictRegion.parse(first.map { DiffLine.context($0) }).canAutoResolve)
    // Region 1 alone (the *second* conflict) → still a live, resolvable region.
    let second = Array(hunk[5..<10])
    #expect(MergeConflict.resolve(second, keeping: .incoming) == ["keepTheirs"])
    #expect(ConflictRegion.parse(second.map { DiffLine.context($0) }).canAutoResolve)
  }

  // MARK: - B §16 / C 15.9 — the conflict widget leaf renders with the tinted body

  @Test func conflictActionRowPlacement() {
    let conflicted = file("merge.txt", status: .conflicted)
    let hunk = DiffHunk(
      oldStart: 1, oldCount: 3, newStart: 1, newCount: 5, header: "@@",
      lines: [
        DiffLine(origin: .context, oldLineNumber: 1, newLineNumber: 1, content: "<<<<<<< ours", noNewlineAtEof: false),
        DiffLine(origin: .addition, oldLineNumber: nil, newLineNumber: 2, content: "ours", noNewlineAtEof: false),
        DiffLine(origin: .context, oldLineNumber: 2, newLineNumber: 3, content: "=======", noNewlineAtEof: false),
        DiffLine(origin: .addition, oldLineNumber: nil, newLineNumber: 4, content: "theirs", noNewlineAtEof: false),
        DiffLine(
          origin: .context, oldLineNumber: 3, newLineNumber: 5, content: ">>>>>>> theirs", noNewlineAtEof: false),
      ])
    let chunks = ChunkTreeBuilder.classify(file: conflicted, hunks: [hunk], expanded: [])

    // File header first, then the conflict action widget, then the tinted body.
    #expect(chunks.first?.widget?.reuseKind == .fileHeader)
    let conflictIndex = chunks.firstIndex {
      if case .placeholder(.conflict) = $0.widget?.payload { return true }
      return false
    }
    #expect(conflictIndex == 1)  // action row anchored just after the header/start
    #expect(chunks.contains { $0.lineSegment != nil })  // the marker body lines render (line-type tint)
  }

  // MARK: - E 13.2 — grep gate: the retired render symbols have zero live refs

  @Test func noDanglingReferenceGrepGate() throws {
    let diffRoot = URL(filePath: #filePath)  // …/supacodeTests/DiffSeamSwapReducerTests.swift
      .deletingLastPathComponent()  // …/supacodeTests
      .deletingLastPathComponent()  // repo root
      .appending(path: "supacode/Features/Diff")
    let forbidden = ["DiffTableController", "DiffCellView", "RowHighlight", "DiffRowBuilder"]
    let fileManager = FileManager.default
    let enumerator = try #require(fileManager.enumerator(at: diffRoot, includingPropertiesForKeys: nil))
    var offenders: [String] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
      let source = try String(contentsOf: url, encoding: .utf8)
      for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
        let code = String(rawLine).components(separatedBy: "//").first ?? ""  // drop comments
        for symbol in forbidden where code.contains(symbol) {
          offenders.append("\(url.lastPathComponent): \(symbol)")
        }
        // `DiffRow` as a whole word (not `DiffRowBuilder`, not `DiffAXRow*`).
        if let range = code.range(of: #"(?<![A-Za-z0-9_])DiffRow(?![A-Za-z0-9_])"#, options: .regularExpression) {
          _ = range
          offenders.append("\(url.lastPathComponent): DiffRow")
        }
      }
    }
    #expect(offenders.isEmpty, "dangling references to retired render symbols: \(offenders)")
  }
}

extension DiffLine {
  /// A context `DiffLine` carrying just `content` — a terse fixture builder for the
  /// pure conflict-parse tests.
  fileprivate static func context(_ content: String) -> DiffLine {
    DiffLine(origin: .context, oldLineNumber: nil, newLineNumber: nil, content: content, noNewlineAtEof: false)
  }
}
