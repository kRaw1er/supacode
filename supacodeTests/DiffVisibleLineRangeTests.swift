import AppKit
import Testing

@testable import supacode

/// CAT 1 — the coordinate-mapping invariants that the "all text white" bug violated.
/// `fireVisibleRange` used to hand the highlighter `tree.indexRange` — RENDERED-ROW
/// indices, shifted by every file-header / hunk-header / expander widget and shared
/// across both blob sides. `tree.visibleLineRange` resolves the visible rows back to
/// the 1-based `DiffLine.old/newLineNumber` space the blob highlighter must be queried
/// with. These pin that resolution so the wrong coordinate can never be fed again.
@MainActor
struct DiffVisibleLineRangeTests {
  /// A rect tall enough to cover the whole tree (the walk stops at `maxY`).
  private let fullRect = CGRect(x: 0, y: 0, width: 800, height: 1_000_000)

  private func fullContextFile(path: String, oldStart: Int, newStart: Int, contents: [String]) -> ChunkTree {
    let lines = contents.enumerated().map { offset, text in
      DiffFixture.line(.context, old: oldStart + offset, new: newStart + offset, text)
    }
    let hunk = DiffFixture.hunk(
      lines, oldStart: oldStart, newStart: newStart, header: "@@ -\(oldStart) +\(newStart) @@")
    return ChunkTreeFixture.files([.init(file: DiffFixture.file(path: path), hunks: [hunk])])
  }

  /// The visible window is the 1-based SOURCE line numbers on screen — NOT the
  /// rendered-row indices. A leading file-header (and hunk-header) widget shifts the
  /// rendered indices to start at 0 while the source lines start at 10; the two must
  /// NOT coincide, which is exactly why feeding `indexRange` to a blob query was wrong.
  @Test func visibleWindowIsSourceLineNumbersNotRenderedRowIndices() {
    let tree = fullContextFile(
      path: "a.swift", oldStart: 10, newStart: 10, contents: ["let a = 1", "let b = 2", "let c = 3"])

    let window = tree.visibleLineRange(in: fullRect, mode: .unified)
    #expect(window.new == 10..<13, "the new side must span the visible NEW line numbers 10...12")
    #expect(window.old == 10..<13, "context rows carry both sides, so the old side spans 10...12 too")

    // The rendered-row index range starts at 0 (the file-header widget), proving the
    // two coordinates diverge — the crux of the bug.
    let rendered = tree.indexRange(in: fullRect, mode: .unified).rows
    #expect(rendered.lowerBound == 0)
    #expect(rendered != window.new, "rendered-row indices must NOT be mistaken for source line numbers")
  }

  /// An addition-only hunk shows no OLD lines, so the old side is empty (the reducer
  /// then skips the old-blob query) while the new side spans the added lines.
  @Test func additionOnlyHunkHasEmptyOldSide() {
    let adds = [
      DiffFixture.line(.addition, old: nil, new: 5, "added one"),
      DiffFixture.line(.addition, old: nil, new: 6, "added two"),
    ]
    let hunk = DiffFixture.hunk(adds, oldStart: 4, newStart: 5, header: "@@ -4,0 +5,2 @@")
    let tree = ChunkTreeFixture.files([.init(file: DiffFixture.file(path: "b.swift"), hunks: [hunk])])

    let window = tree.visibleLineRange(in: fullRect, mode: .unified)
    #expect(window.old.isEmpty, "no old lines are visible in an addition-only hunk")
    #expect(window.new == 5..<7, "the new side spans the two added lines 5...6")
  }

  /// An empty tree resolves to the empty window (no crash, no phantom lines).
  @Test func emptyTreeYieldsEmptyWindow() {
    #expect(ChunkTree().visibleLineRange(in: fullRect, mode: .unified) == .empty)
  }
}
