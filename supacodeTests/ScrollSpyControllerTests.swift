import CoreGraphics
import Testing

@testable import supacode

/// Phase 10 — `FileOffsetIndex` (the shared file↔y cache) + `ScrollSpyController`
/// (body → list dedupe, list → body offsets). PURE: a controlled 3-file tree with
/// exact header y's (header 44, line 20): A@0, B@104, C@248.
@MainActor
struct ScrollSpyControllerTests {
  // MARK: - Fixture

  /// A 3-file tree with file headers at y = 0 / 104 / 248 and the ids in order.
  private func threeFileTree() -> (tree: ChunkTree, files: [FileChange.ID]) {
    let tree = ChunkTree(metrics: .production)  // diffHeaderHeight 44, lineHeight 20
    var after: ChunkID?
    func header(_ id: String) {
      after = tree.insert(
        .widget(Widget(key: .fileHeader(fileID: id), estimatedHeight: 44, payload: .fileHeader(fileID: id))),
        after: after)
    }
    func lines(_ id: String, _ count: Int) {
      let diffLines = (0..<count).map {
        DiffLine(origin: .context, oldLineNumber: $0 + 1, newLineNumber: $0 + 1, content: "x", noNewlineAtEof: false)
      }
      let segment = LineSegment(
        hunkID: HunkID(fileID: id, index: 0), lines: diffLines, window: 0..<count, classification: .context)
      after = tree.insert(.lineSegment(segment), after: after)
    }
    header("A")
    lines("A", 3)  // A: header 0..44, body 44..104
    header("B")
    lines("B", 5)  // B: header 104..148, body 148..248
    header("C")
    lines("C", 2)  // C: header 248..292
    return (tree, ["A", "B", "C"])
  }

  // MARK: - 12.1–12.3 FileOffsetIndex resolves file↔y

  @Test func fileOffsetIndexResolvesFileAndY() {
    let (tree, files) = threeFileTree()
    let index = FileOffsetIndex(files: files, tree: tree, mode: .unified)

    // top(of:) is the header top.
    #expect(index.top(of: "A") == 0)
    #expect(index.top(of: "B") == 104)
    #expect(index.top(of: "C") == 248)
    #expect(index.top(of: "missing") == nil)

    // file(atOrAbove:) is the last header ≤ y.
    #expect(index.file(atOrAbove: 0) == "A")
    #expect(index.file(atOrAbove: 50) == "A")
    #expect(index.file(atOrAbove: 104) == "B")
    #expect(index.file(atOrAbove: 200) == "B")
    #expect(index.file(atOrAbove: 248) == "C")
    #expect(index.file(atOrAbove: 600) == "C")
    #expect(index.file(atOrAbove: -1) == nil)  // above the first file's header

    // nextTop(after:) drives the sticky push-out.
    #expect(index.nextTop(after: "A") == 104)
    #expect(index.nextTop(after: "B") == 248)
    #expect(index.nextTop(after: "C") == nil)  // last file
  }

  // MARK: - 12.4 empty index — every query nil

  @Test func fileOffsetIndexEmpty() {
    let empty = FileOffsetIndex()
    #expect(empty.isEmpty)
    #expect(empty.file(atOrAbove: 0) == nil)
    #expect(empty.top(of: "A") == nil)
    #expect(empty.nextTop(after: "A") == nil)

    // A zero-file tree (no file headers) also yields an empty index.
    let onlyLines = ViewportTestSupport.contextLeaves(Array(1...10))
    let index = FileOffsetIndex(files: [], tree: onlyLines, mode: .unified)
    #expect(index.isEmpty)
    #expect(index.file(atOrAbove: 100) == nil)
  }

  // MARK: - 12.5 scrollDidReach fires change-only (dedupe)

  @Test func scrollDidReachFiresOnFileChangeOnly() {
    let (tree, files) = threeFileTree()
    let spy = ScrollSpyController(files: files, tree: tree, mode: .unified)
    var fired: [FileChange.ID] = []
    spy.onActiveFileChanged = { fired.append($0) }

    spy.scrollDidReach(clipTop: 0)  // → A, fires
    spy.scrollDidReach(clipTop: 50)  // still A, NO fire (dedupe)
    #expect(fired == ["A"])
    #expect(spy.activeFileID == "A")

    spy.scrollDidReach(clipTop: 104)  // → B, fires (boundary crossing)
    spy.scrollDidReach(clipTop: 200)  // still B, NO fire
    #expect(fired == ["A", "B"])

    spy.scrollDidReach(clipTop: 300)  // → C, fires
    #expect(fired == ["A", "B", "C"])
    #expect(spy.activeFileID == "C")
  }

  // MARK: - list → body offsets + push-out top

  @Test func spyOffsetsForJumpAndPushOut() {
    let (tree, files) = threeFileTree()
    let spy = ScrollSpyController(files: files, tree: tree, mode: .unified)

    #expect(spy.offset(forFile: "B") == 104)  // jump-to-file target y
    #expect(spy.offset(forFile: "missing") == nil)
    #expect(spy.fileID(atTop: 260) == "C")
    #expect(spy.nextFileTop(after: "A") == 104)
    #expect(spy.nextFileTop(after: "C") == nil)
    #expect(!spy.isEmpty)
  }

  // MARK: - rebuild re-reads the tree (mode toggle / structural mutation)

  @Test func rebuildRefreshesIndex() {
    let (tree, files) = threeFileTree()
    let spy = ScrollSpyController()
    #expect(spy.isEmpty)  // starts empty
    spy.rebuild(files: files, tree: tree, mode: .unified)
    #expect(spy.offset(forFile: "C") == 248)
  }
}
