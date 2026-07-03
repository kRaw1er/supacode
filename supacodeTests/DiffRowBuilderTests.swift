import Foundation
import Testing

@testable import supacode

/// Unit coverage for the pure `DiffRowBuilder`. Every case builds concrete hunks
/// and asserts the flat row list — no libgit2, no store.
struct DiffRowBuilderTests {
  // MARK: - Fixtures

  private func line(
    _ origin: DiffLineOrigin,
    old: Int? = nil,
    new: Int? = nil,
    _ content: String = "x",
    noNewline: Bool = false
  ) -> DiffLine {
    DiffLine(origin: origin, oldLineNumber: old, newLineNumber: new, content: content, noNewlineAtEof: noNewline)
  }

  private func file(
    status: FileStatus = .modified,
    binary: Bool = false,
    capped: Bool = false
  ) -> FileChange {
    FileChange(
      oldPath: "a.swift",
      newPath: "a.swift",
      status: status,
      addedLines: 1,
      removedLines: 1,
      isBinary: binary,
      isLargeFileCapped: capped,
      hasLongLines: false,
      similarity: 0
    )
  }

  private func hunk(_ lines: [DiffLine], oldStart: Int = 1, newStart: Int = 1, header: String = "@@ -1 +1 @@")
    -> DiffHunk
  {
    let oldCount = lines.filter { $0.origin == .context || $0.origin == .deletion }.count
    let newCount = lines.filter { $0.origin == .context || $0.origin == .addition }.count
    return DiffHunk(
      oldStart: oldStart,
      oldCount: oldCount,
      newStart: newStart,
      newCount: newCount,
      header: header,
      lines: lines
    )
  }

  private func expanders(_ rows: [DiffRow]) -> [DiffRow] {
    rows.filter { if case .expander = $0 { return true } else { return false } }
  }

  // MARK: - modified file, single hunk

  @Test func modifiedSingleHunkInterleavesLinesWithCorrectNumbers() {
    let lines = [
      line(.context, old: 1, new: 1, "keep"),
      line(.deletion, old: 2, "gone"),
      line(.addition, new: 2, "added"),
      line(.context, old: 3, new: 3, "tail"),
    ]
    let rows = DiffRowBuilder.build(
      file: file(), hunks: [hunk(lines, header: "@@ -1,3 +1,3 @@")], mode: .unified, expanded: [])

    guard case .hunkHeader = rows.first else {
      Issue.record("expected header first")
      return
    }
    let content = rows.dropFirst().compactMap { row -> DiffLine? in
      if case .line(let line) = row { return line } else { return nil }
    }
    #expect(content.count == 4)
    #expect(content[0].origin == .context && content[0].oldLineNumber == 1 && content[0].newLineNumber == 1)
    #expect(content[1].origin == .deletion && content[1].oldLineNumber == 2 && content[1].newLineNumber == nil)
    #expect(content[2].origin == .addition && content[2].oldLineNumber == nil && content[2].newLineNumber == 2)
    #expect(content[3].origin == .context && content[3].oldLineNumber == 3 && content[3].newLineNumber == 3)
  }

  // MARK: - no trailing newline

  @Test func noTrailingNewlineEmitsMarkerAfterFlaggedLine() {
    let lines = [
      line(.context, old: 1, new: 1, "keep"),
      line(.addition, new: 2, "last", noNewline: true),
    ]
    let rows = DiffRowBuilder.build(file: file(), hunks: [hunk(lines)], mode: .unified, expanded: [])
    let lineRows = rows.compactMap { row -> DiffLine? in
      if case .line(let line) = row { return line } else { return nil }
    }
    #expect(lineRows.count == 3)
    #expect(lineRows[1].origin == .addition && lineRows[1].newLineNumber == 2)
    #expect(lineRows[2].origin == .noNewlineMarker)
    // Numbering of the real lines is unaffected by the synthetic marker.
    #expect(lineRows[0].newLineNumber == 1 && lineRows[1].newLineNumber == 2)
  }

  // MARK: - inter-hunk gap collapse

  @Test func interHunkLeadingAndTrailingGapsCollapseToExpanders() {
    let first = hunk(
      [
        line(.context, old: 10, new: 10, "c"),
        line(.addition, new: 11, "a"),
        line(.context, old: 11, new: 12, "c"),
      ],
      oldStart: 10, newStart: 10
    )
    let second = hunk(
      [line(.context, old: 200, new: 206, "c"), line(.deletion, old: 201, "d")],
      oldStart: 200, newStart: 206
    )
    let rows = DiffRowBuilder.build(
      file: file(),
      hunks: [first, second],
      mode: .unified,
      expanded: [],
      options: .init(totalNewLines: 210)
    )

    let gaps = expanders(rows)
    // leading (before first) + between (first→second) + trailing (after second).
    #expect(gaps.count == 3)
    // The between-hunk gap hides first's newEnd(13)..<206 = 193 lines.
    let between = gaps.first { if case .expander(let anchor, _, _) = $0 { return anchor == 13 } else { return false } }
    if case .expander(_, _, let hidden) = between { #expect(hidden == 193) } else { Issue.record("no between gap") }
  }

  @Test func expandedGapAnchorSuppressesExpander() {
    let first = hunk([line(.addition, new: 1, "a")], oldStart: 1, newStart: 1)
    let second = hunk([line(.addition, new: 202, "a")], oldStart: 1, newStart: 202)
    // first newEnd = 1 + 1 = 2 → between-gap anchor is 2.
    let collapsed = DiffRowBuilder.build(file: file(), hunks: [first, second], mode: .unified, expanded: [])
    let expanded = DiffRowBuilder.build(file: file(), hunks: [first, second], mode: .unified, expanded: [2])
    #expect(expanders(collapsed).count == 1)
    #expect(expanders(expanded).isEmpty)
  }

  // MARK: - intra-run collapse

  @Test func longInteriorContextRunCollapses() {
    var lines = [line(.addition, new: 1, "a")]
    for offset in 0..<40 {
      lines.append(line(.context, old: offset + 1, new: offset + 2, "ctx"))
    }
    lines.append(line(.deletion, old: 41, "d"))
    let rows = DiffRowBuilder.build(
      file: file(),
      hunks: [hunk(lines, header: "@@ -1,41 +1,41 @@")],
      mode: .unified,
      expanded: [],
      options: .init(collapseThreshold: 10, edgeContext: 3)
    )
    let gaps = expanders(rows)
    #expect(gaps.count == 1)
    if case .expander(_, _, let hidden) = gaps[0] { #expect(hidden == 34) } else { Issue.record("no run gap") }
    // 3 head + 3 tail context lines survive around the expander.
    let contextRows = rows.filter {
      if case .line(let line) = $0 { return line.origin == .context } else { return false }
    }
    #expect(contextRows.count == 6)
  }

  // MARK: - split pairing

  @Test func splitPairsDeletionsAndAdditions() {
    let lines = [
      line(.deletion, old: 1, "d0"),
      line(.deletion, old: 2, "d1"),
      line(.deletion, old: 3, "d2"),
      line(.addition, new: 1, "a0"),
      line(.addition, new: 2, "a1"),
    ]
    let rows = DiffRowBuilder.build(file: file(), hunks: [hunk(lines)], mode: .split, expanded: [])
    let pairs = rows.compactMap { row -> (DiffLine?, DiffLine?)? in
      if case .splitLine(_, let old, let new) = row { return (old, new) } else { return nil }
    }
    #expect(pairs.count == 3)
    #expect(pairs[0].0?.content == "d0" && pairs[0].1?.content == "a0")
    #expect(pairs[1].0?.content == "d1" && pairs[1].1?.content == "a1")
    #expect(pairs[2].0?.content == "d2" && pairs[2].1 == nil)
  }

  @Test func splitPureAddAndPureDelete() {
    let addRows = DiffRowBuilder.build(
      file: file(status: .added),
      hunks: [hunk([line(.addition, new: 1, "a"), line(.addition, new: 2, "b")])],
      mode: .split,
      expanded: []
    )
    let addPairs = addRows.compactMap { row -> (DiffLine?, DiffLine?)? in
      if case .splitLine(_, let old, let new) = row { return (old, new) } else { return nil }
    }
    #expect(addPairs.count == 2)
    #expect(addPairs.allSatisfy { $0.0 == nil && $0.1 != nil })

    let delRows = DiffRowBuilder.build(
      file: file(status: .deleted),
      hunks: [hunk([line(.deletion, old: 1, "a"), line(.deletion, old: 2, "b")])],
      mode: .split,
      expanded: []
    )
    let delPairs = delRows.compactMap { row -> (DiffLine?, DiffLine?)? in
      if case .splitLine(_, let old, let new) = row { return (old, new) } else { return nil }
    }
    #expect(delPairs.count == 2)
    #expect(delPairs.allSatisfy { $0.0 != nil && $0.1 == nil })
  }

  @Test func splitContextPairsBothSides() {
    let rows = DiffRowBuilder.build(
      file: file(),
      hunks: [hunk([line(.context, old: 1, new: 1, "c"), line(.addition, new: 2, "a")])],
      mode: .split,
      expanded: []
    )
    let contextPair = rows.first {
      if case .splitLine(_, let old, let new) = $0 {
        return old?.origin == .context && new?.origin == .context
      } else {
        return false
      }
    }
    #expect(contextPair != nil)
  }

  // MARK: - placeholders

  @Test func placeholderCases() {
    #expect(
      DiffRowBuilder.build(file: file(binary: true), hunks: [], mode: .unified, expanded: []) == [
        .placeholder(.binaryFile)
      ]
    )
    #expect(
      DiffRowBuilder.build(file: file(status: .deleted), hunks: [], mode: .unified, expanded: []) == [
        .placeholder(.deletedFile)
      ]
    )
    #expect(
      DiffRowBuilder.build(file: file(status: .modeChanged), hunks: [], mode: .unified, expanded: [])
        == [.placeholder(.modeChangeOnly(oldMode: "", newMode: ""))]
    )
    #expect(
      DiffRowBuilder.build(file: file(status: .added), hunks: [], mode: .unified, expanded: []) == [
        .placeholder(.addedEmpty)
      ]
    )
    #expect(
      DiffRowBuilder.build(file: file(status: .submodule), hunks: [], mode: .unified, expanded: [])
        == [.placeholder(.submodule(oldSHA: "", newSHA: ""))]
    )
  }

  // MARK: - large-file cap

  @Test func largeFileCapProducesOnlyPlainFallback() {
    let lines = [line(.context, old: 1, new: 1, "a"), line(.addition, new: 2, "b"), line(.deletion, old: 2, "c")]
    let rows = DiffRowBuilder.build(file: file(capped: true), hunks: [hunk(lines)], mode: .unified, expanded: [])
    #expect(rows.count == 3)
    for row in rows {
      guard case .plainFallback = row else {
        Issue.record("expected plainFallback, got \(row)")
        return
      }
    }
    // Deletions keep the old number; additions/context use the new number.
    #expect(rows[2] == .plainFallback(lineNumber: 2, text: "c"))
  }

  // MARK: - row identity

  @Test func identicalBuildsAreEqualAndContentEditKeepsLogicalID() {
    let base = [line(.context, old: 1, new: 1, "keep"), line(.addition, new: 2, "added")]
    let first = DiffRowBuilder.build(file: file(), hunks: [hunk(base)], mode: .unified, expanded: [])
    let second = DiffRowBuilder.build(file: file(), hunks: [hunk(base)], mode: .unified, expanded: [])
    // Two builds of the same hunk are fully equal → empty CollectionDifference.
    #expect(first == second)
    #expect(first.difference(from: second).isEmpty)

    let edited = [line(.context, old: 1, new: 1, "keep"), line(.addition, new: 2, "CHANGED")]
    let third = DiffRowBuilder.build(file: file(), hunks: [hunk(edited)], mode: .unified, expanded: [])
    // The edited line differs by ==, but its logical id (line numbers) is stable.
    #expect(first != third)
    #expect(first.map(\.id) == third.map(\.id))
  }
}
