import Testing

@testable import supacode

/// Phase 12 — `DiffAXText`: the VoiceOver strings ported verbatim out of the deleted
/// `DiffCellView.axLabel` / `lineLabel` / `commentAnchor`. PURE (no AppKit), so this
/// locks the ported strings (added / removed / context, split both-sides, comment
/// thread + orphaned prefix, expander, hunk header, plain fallback, placeholder) and
/// the `commentAnchor` side / line resolution against regressions.
@MainActor
struct DiffAXTextTests {
  private func line(_ origin: DiffLineOrigin, old: Int?, new: Int?, _ content: String) -> DiffLine {
    DiffLine(origin: origin, oldLineNumber: old, newLineNumber: new, content: content, noNewlineAtEof: false)
  }

  private func comment(
    side: DiffSide, start: Int, end: Int, body: String, orphaned: Bool = false
  ) -> ReviewComment {
    ReviewComment(
      filePath: "f.swift", side: side, startLine: start, endLine: end, anchorSnippet: "", contextBefore: "",
      body: body, orphaned: orphaned)
  }

  // MARK: - axTextParityWithPortedStrings

  @Test func lineLabelsMatchPortedStrings() {
    #expect(
      DiffAXText.label(for: .line(line(.addition, old: nil, new: 42, "foo()")), mode: .unified)
        == "added line 42: foo()")
    #expect(
      DiffAXText.label(for: .line(line(.deletion, old: 10, new: nil, "bar")), mode: .unified) == "removed line 10: bar")
    #expect(
      DiffAXText.label(for: .line(line(.context, old: 5, new: 5, "baz")), mode: .unified) == "context line 5: baz")
    // A line with no number on either side (degenerate) still reads its origin.
    #expect(DiffAXText.label(for: .line(line(.addition, old: nil, new: nil, "x")), mode: .unified) == "added: x")
    // A no-newline marker reads its content verbatim.
    #expect(
      DiffAXText.label(for: .line(line(.noNewlineMarker, old: 3, new: 3, "No newline at end of file")), mode: .unified)
        == "No newline at end of file")
  }

  @Test func splitLabelNamesBothSides() {
    let row: DiffAXRow = .splitLine(
      pairID: 1, old: line(.deletion, old: 3, new: nil, "old"), new: line(.addition, old: nil, new: 3, "new"))
    #expect(DiffAXText.label(for: row, mode: .split) == "old, removed line 3: old, new, added line 3: new")
    // A fully-blank split pair reads "blank line".
    #expect(DiffAXText.label(for: .splitLine(pairID: 2, old: nil, new: nil), mode: .split) == "blank line")
    // A one-sided split names just that side.
    #expect(
      DiffAXText.label(
        for: .splitLine(pairID: 3, old: line(.deletion, old: 7, new: nil, "gone"), new: nil), mode: .split)
        == "old, removed line 7: gone")
  }

  @Test func commentThreadLabelsIncludeOrphanedPrefix() {
    #expect(
      DiffAXText.label(for: .commentThread(comment(side: .new, start: 7, end: 7, body: "hi")), mode: .unified)
        == "Comment on new line 7: hi")
    #expect(
      DiffAXText.label(for: .commentThread(comment(side: .old, start: 3, end: 5, body: "note")), mode: .unified)
        == "Comment on old line 3 to 5: note")
    #expect(
      DiffAXText.label(
        for: .commentThread(comment(side: .new, start: 9, end: 9, body: "gone", orphaned: true)), mode: .unified)
        == "Orphaned — original line no longer present. Comment on new line 9: gone")
  }

  @Test func widgetAndFallbackLabelsMatchPortedStrings() {
    #expect(
      DiffAXText.label(for: .expander(anchor: 1, collapsedRange: 1..<15, hiddenCount: 14), mode: .unified)
        == "Show 14 hidden lines")
    #expect(
      DiffAXText.label(for: .expander(anchor: 1, collapsedRange: 1..<2, hiddenCount: 1), mode: .unified)
        == "Show 1 hidden line")
    #expect(
      DiffAXText.label(for: .hunkHeader(anchor: 1, text: "@@ -1,3 +1,4 @@"), mode: .unified)
        == "Hunk header, @@ -1,3 +1,4 @@")
    #expect(
      DiffAXText.label(for: .plainFallback(lineNumber: 8, text: "long line"), mode: .unified) == "line 8: long line")
    #expect(DiffAXText.label(for: .placeholder(.binaryFile), mode: .unified) == "Binary file not shown")
    #expect(DiffAXText.label(for: .placeholder(.deletedFile), mode: .unified) == "File deleted")
  }

  @Test func fileHeaderLabelIsNetNewAndReadsPathStatusCounts() {
    let model = FileHeaderWidget.Model(path: "src/App.swift", statusText: "Modified", addedLines: 3, removedLines: 1)
    #expect(DiffAXText.fileHeaderLabel(model) == "File src/App.swift, Modified, 3 added, 1 removed")
    // No counts → path + status only.
    let clean = FileHeaderWidget.Model(path: "README.md", statusText: "Renamed")
    #expect(DiffAXText.fileHeaderLabel(clean) == "File README.md, Renamed")
  }

  // MARK: - commentAnchor side / line resolution

  @Test func commentAnchorResolvesSideAndLine() {
    #expect(DiffAXText.commentAnchor(for: .line(line(.addition, old: nil, new: 42, "a")))?.side == .new)
    #expect(DiffAXText.commentAnchor(for: .line(line(.addition, old: nil, new: 42, "a")))?.line == 42)
    #expect(DiffAXText.commentAnchor(for: .line(line(.deletion, old: 10, new: nil, "d")))?.side == .old)
    #expect(DiffAXText.commentAnchor(for: .line(line(.deletion, old: 10, new: nil, "d")))?.line == 10)
    // Context anchors on the new side.
    #expect(DiffAXText.commentAnchor(for: .line(line(.context, old: 5, new: 5, "c")))?.side == .new)
    // A no-newline marker has no anchor.
    #expect(DiffAXText.commentAnchor(for: .line(line(.noNewlineMarker, old: 3, new: 3, "x"))) == nil)
    // Split prefers the new side when present, else falls back to old.
    let bothSides: DiffAXRow = .splitLine(
      pairID: 1, old: line(.deletion, old: 3, new: nil, "o"), new: line(.addition, old: nil, new: 3, "n"))
    #expect(DiffAXText.commentAnchor(for: bothSides)?.side == .new)
    #expect(DiffAXText.commentAnchor(for: bothSides)?.line == 3)
    let oldOnly: DiffAXRow = .splitLine(pairID: 2, old: line(.deletion, old: 7, new: nil, "o"), new: nil)
    #expect(DiffAXText.commentAnchor(for: oldOnly)?.side == .old)
    #expect(DiffAXText.commentAnchor(for: oldOnly)?.line == 7)
    // Non-line rows have no gutter anchor.
    #expect(DiffAXText.commentAnchor(for: .hunkHeader(anchor: 1, text: "@@")) == nil)
    #expect(DiffAXText.commentAnchor(for: .expander(anchor: 1, collapsedRange: 1..<3, hiddenCount: 2)) == nil)
  }
}
