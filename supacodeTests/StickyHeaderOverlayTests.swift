import AppKit
import SwiftUI
import Testing

@testable import supacode

/// Phase 10 — `StickyHeaderOverlay`: the pure `overlap → pushUp` push-out arithmetic
/// (the live pixel placement / flip is Release-manual), the floating-subview
/// reserves-no-space invariant, boundary push-out, collapsed-not-sticky, and the
/// in-flow ↔ sticky header-model 1:1 mirror + golden.
@MainActor
struct StickyHeaderOverlayTests {
  private let header = StickyHeaderOverlay.headerHeight  // 44

  // MARK: - Fixture: a 3-file tree (headers @ 0 / 104 / 248)

  private func threeFileTree() -> (tree: ChunkTree, files: [FileChange.ID]) {
    let tree = ChunkTree(metrics: .production)
    var after: ChunkID?
    func fileHeader(_ id: String) {
      after = tree.insert(
        .widget(Widget(key: .fileHeader(fileID: id), estimatedHeight: 44, payload: .fileHeader(fileID: id))),
        after: after)
    }
    func lines(_ id: String, _ count: Int) {
      let diffLines = (0..<count).map {
        DiffLine(origin: .context, oldLineNumber: $0 + 1, newLineNumber: $0 + 1, content: "x", noNewlineAtEof: false)
      }
      after = tree.insert(
        .lineSegment(
          LineSegment(
            hunkID: HunkID(fileID: id, index: 0), lines: diffLines, window: 0..<count, classification: .context)),
        after: after)
    }
    fileHeader("A")
    lines("A", 3)  // A header 0, next B @ 104
    fileHeader("B")
    lines("B", 5)  // B header 104, next C @ 248
    fileHeader("C")
    lines("C", 2)  // C header 248
    return (tree, ["A", "B", "C"])
  }

  // MARK: - stickyPushOutContiguity (PURE)

  @Test func stickyPushOutContiguity() {
    // Content below the window (next header far below) → flush, HEADER_ONLY at the top.
    let below = StickyHeaderOverlay.pushUp(nextFileTop: 1000, clipTop: 500)  // overlap 500 ≥ 44
    #expect(below == 0)
    #expect(StickyHeaderOverlay.pinnedBottom(clipTop: 500, pushUp: below) == 500 + header)  // HEADER_ONLY

    // The boundary: next header exactly `header` below → still flush (pushUp 0).
    #expect(StickyHeaderOverlay.pushUp(nextFileTop: 500 + header, clipTop: 500) == 0)

    // Next header entering the band (0 < overlap < header): the pinned header's bottom
    // meets the incoming header's top exactly (contiguity — region ends at the logical
    // bottom).
    let entering = StickyHeaderOverlay.pushUp(nextFileTop: 520, clipTop: 500)  // overlap 20
    #expect(entering == header - 20)
    #expect(StickyHeaderOverlay.pinnedBottom(clipTop: 500, pushUp: entering) == 520)  // == nextFileTop

    // Next header at the clip top → fully pushed out (pushUp == header).
    #expect(StickyHeaderOverlay.pushUp(nextFileTop: 500, clipTop: 500) == header)

    // Two-sided asymmetry: the LAST file (no next) is never pushed.
    #expect(StickyHeaderOverlay.pushUp(nextFileTop: nil, clipTop: 500) == 0)
  }

  // MARK: - stickyOverlayReservesSpaceNoReflow (NSVIEW)

  @Test func stickyOverlayReservesSpaceNoReflow() {
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: 600)
    let (tree, files) = threeFileTree()
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
    let spy = ScrollSpyController(files: files, tree: tree, mode: .unified)

    let heightBefore = controller.documentView.frame.height
    let totalBefore = tree.totalHeight(.unified)
    let offsetBefore = controller.scrollView.contentView.bounds.origin.y

    let overlay = StickyHeaderOverlay(
      scrollView: controller.scrollView, spy: spy,
      resolveModel: { FileHeaderWidget.Model(path: $0, statusText: "Modified") })
    overlay.update(clipTop: 0, viewportWidth: 800)

    // A floating subview reserves NO layout space: the document height, the tree
    // total, and the scroll offset are all unchanged.
    #expect(controller.documentView.frame.height == heightBefore)
    #expect(tree.totalHeight(.unified) == totalBefore)
    #expect(controller.scrollView.contentView.bounds.origin.y == offsetBefore)
  }

  // MARK: - stickyOverlayBoundaryPushOut (NSVIEW)

  @Test func stickyOverlayBoundaryPushOut() {
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: 600)
    let (tree, files) = threeFileTree()
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
    let spy = ScrollSpyController(files: files, tree: tree, mode: .unified)
    let overlay = StickyHeaderOverlay(
      scrollView: controller.scrollView, spy: spy,
      resolveModel: { FileHeaderWidget.Model(path: $0, statusText: "Modified") })

    // clipTop 0 owns A; next header (B @ 104) is far below → flush (frameY = clipH-header).
    overlay.update(clipTop: 0, viewportWidth: 800)
    #expect(overlay.pinnedState.fileID == "A")
    #expect(overlay.pinnedState.frameY == 600 - header)

    // clipTop 70 still owns A; B @ 104 is entering the band (overlap 34) → shoved up 10.
    overlay.update(clipTop: 70, viewportWidth: 800)
    #expect(overlay.pinnedState.fileID == "A")
    #expect(overlay.pinnedState.frameY == 600 - header + (header - 34))

    // clipTop 260 owns C (the last file) → never pushed (flush).
    overlay.update(clipTop: 260, viewportWidth: 800)
    #expect(overlay.pinnedState.fileID == "C")
    #expect(overlay.pinnedState.frameY == 600 - header)
  }

  // MARK: - stickyOverlayCollapsedNotSticky (NSVIEW)

  @Test func stickyOverlayCollapsedNotSticky() {
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: 600)
    let (tree, files) = threeFileTree()
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
    let spy = ScrollSpyController(files: files, tree: tree, mode: .unified)
    let overlay = StickyHeaderOverlay(
      scrollView: controller.scrollView, spy: spy,
      resolveModel: { FileHeaderWidget.Model(path: $0, statusText: "Modified") })

    // Above the first file's header → no owning file → overlay hidden (not sticky).
    overlay.update(clipTop: -50, viewportWidth: 800)
    #expect(overlay.pinnedState.isHidden)
    #expect(overlay.pinnedState.fileID == nil)

    // Scroll into file B → sticky again.
    overlay.update(clipTop: 150, viewportWidth: 800)
    #expect(!overlay.pinnedState.isHidden)
    #expect(overlay.pinnedState.fileID == "B")

    // An empty index (no files) is never sticky. (Hold `emptySpy` strongly — the
    // overlay keeps only an `unowned` reference to it.)
    let emptySpy = ScrollSpyController()
    let emptyOverlay = StickyHeaderOverlay(
      scrollView: controller.scrollView, spy: emptySpy,
      resolveModel: { FileHeaderWidget.Model(path: $0, statusText: "") })
    emptyOverlay.update(clipTop: 0, viewportWidth: 800)
    #expect(emptyOverlay.pinnedState.isHidden)
  }

  // MARK: - stickyOverlayIsAccessibilityHidden (NSVIEW) — no double VO announce

  @Test func stickyOverlayIsAccessibilityHidden() throws {
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: 600)
    let (tree, files) = threeFileTree()
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
    let spy = ScrollSpyController(files: files, tree: tree, mode: .unified)
    let overlay = StickyHeaderOverlay(
      scrollView: controller.scrollView, spy: spy,
      resolveModel: { FileHeaderWidget.Model(path: $0, statusText: "Modified") })
    overlay.update(clipTop: 150, viewportWidth: 800)  // pin file B so the overlay is live
    #expect(overlay.pinnedState.fileID == "B")

    // The pinned overlay duplicates a file-header widget that already lives in the tree
    // (a synthesized AX element), so the floating overlay subtree MUST be hidden from
    // VoiceOver — otherwise the file header is announced twice while scrolling across a
    // file boundary. Find the floating container by its hosted `StickyFileHeaderView`.
    func descendants(of view: NSView) -> [NSView] {
      view.subviews + view.subviews.flatMap(descendants)
    }
    let hosting = try #require(
      descendants(of: controller.scrollView).compactMap { $0 as? NSHostingView<StickyFileHeaderView> }.first,
      "the overlay must host a StickyFileHeaderView")
    let container = try #require(hosting.superview, "the hosted header must live inside the overlay container")
    #expect(container.isAccessibilityHidden())  // hidden from VO
    #expect(container.isAccessibilityElement() == false)  // not itself an AX element
  }

  // MARK: - collapsedReportsHeaderHeight (PURE) — collapsed file reserves header-only

  @Test func collapsedReportsHeaderHeight() {
    let metrics = ChunkLayoutMetrics.production
    // A file with NO body (rename-pure / identical / no content hunks) is the shipped
    // analog of a whole-file collapse: only the header region is reserved and the body
    // is NEVER typeset — no per-line rows enter the estimate and the trailing
    // `paddingBottom` is skipped entirely.
    let noBody = DiffFixture.file(status: .renamed)
    let headerOnly = ChunkTreeBuilder.estimatedHeights(file: noBody, hunks: [])
    let expected = metrics.diffHeaderHeight + metrics.paddingTop  // header + top pad; NO body, NO paddingBottom
    #expect(headerOnly.unified == expected)
    #expect(headerOnly.split == expected)
    // The reserved header-only height is exactly the pinned overlay's header height.
    #expect(headerOnly.unified == StickyHeaderOverlay.headerHeight + metrics.paddingTop)

    // A file WITH a body reserves strictly MORE — proving the collapsed case really
    // skipped typesetting the body rather than coincidentally matching header height.
    let withBody = ChunkTreeBuilder.estimatedHeights(
      file: DiffFixture.file(),
      hunks: [DiffFixture.hunk([DiffFixture.line(.deletion, old: 1, "a"), DiffFixture.line(.addition, new: 1, "b")])])
    #expect(withBody.unified > expected)
    #expect(withBody.split > expected)
  }

  // MARK: - stickyOverlayMirrorsInFlowHeader

  @Test func stickyOverlayMirrorsInFlowHeader() {
    let file = DiffFixture.file(path: "Sources/App.swift", status: .modified)
    // The overlay resolves the SAME `FileHeaderWidget.Model` the in-flow header uses.
    let inFlow = FileHeaderWidget.Model.make(from: file)
    let sticky = inFlow.staticMirror
    #expect(sticky.path == inFlow.path)
    #expect(sticky.statusText == inFlow.statusText)
    #expect(sticky.addedLines == inFlow.addedLines)
    #expect(sticky.removedLines == inFlow.removedLines)
    // Only the interactive affordance differs (a static pinned header renders no button).
    #expect(inFlow.canCommentOnFile)
    #expect(!sticky.canCommentOnFile)
  }

  // MARK: - fileHeaderModelAndStickyMirrorGolden (PURE golden)

  @Test func fileHeaderModelAndStickyMirrorGolden() {
    let files: [FileChange] = [
      file("Sources/App.swift", status: .modified, added: 3, removed: 1),
      file("New/Name.swift", oldPath: "Old/Name.swift", status: .renamed, added: 2, removed: 2),
      file("Docs/readme.md", status: .added, added: 10, removed: 0),
      file("Legacy/Gone.swift", status: .deleted, added: 0, removed: 5),
    ]
    var out: [String] = []
    for fileChange in files {
      let inFlow = FileHeaderWidget.Model.make(from: fileChange)
      let sticky = inFlow.staticMirror
      #expect(sticky.path == inFlow.path && sticky.statusText == inFlow.statusText)
      #expect(sticky.addedLines == inFlow.addedLines && sticky.removedLines == inFlow.removedLines)
      out.append(row(inFlow, sticky: false))
      out.append(row(sticky, sticky: true))
    }
    GoldenText.assert(out.joined(separator: "\n") + "\n", "file-header-model-mirror")
  }

  private func row(_ model: FileHeaderWidget.Model, sticky: Bool) -> String {
    "path=\(model.path)|status=\(model.statusText)|+\(model.addedLines)|-\(model.removedLines)|sticky=\(sticky)"
  }

  private func file(
    _ newPath: String, oldPath: String? = nil, status: FileStatus, added: Int, removed: Int
  ) -> FileChange {
    FileChange(
      oldPath: oldPath ?? newPath,
      newPath: newPath,
      status: status,
      addedLines: added,
      removedLines: removed,
      isBinary: false,
      isLargeFileCapped: false,
      hasLongLines: false,
      similarity: 0
    )
  }
}
