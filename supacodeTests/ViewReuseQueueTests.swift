import AppKit
import Testing

@testable import supacode

/// Phase 2 — the CodeEditTextView-ported `ViewReuseQueue` + the recycle
/// lifecycle (C 2.10-adjacent pool mechanics, B §3 stale-content, B §20 unmount
/// order, B §1 borrowed-state restore). NSVIEW-HEADLESS: real `NSView`s, no
/// window.
@MainActor
struct ViewReuseQueueTests {
  /// Wire the pool's teardown hook to the recyclable protocol, as the controller does.
  private func pool() -> ViewReuseQueue<NSView, Int> {
    let queue = ViewReuseQueue<NSView, Int>()
    queue.onEnqueue = { view in (view as? DiffViewportRecyclable)?.prepareForReuse() }
    return queue
  }

  // MARK: - getOrCreateView / getView reuse

  @Test func poolReusesQueuedViewForSameKey() {
    let queue = pool()
    var created = 0
    let first = queue.getOrCreateView(forKey: 1) {
      created += 1
      return NSView()
    }
    // Same key → same view, no new creation.
    let again = queue.getOrCreateView(forKey: 1) {
      created += 1
      return NSView()
    }
    #expect(first === again)
    #expect(created == 1)
    #expect(queue.getView(forKey: 1) === first)

    // Recycle key 1, then a NEW key dequeues that freed view (no creation).
    queue.enqueueView(forKey: 1)
    #expect(queue.getView(forKey: 1) == nil)
    let reused = queue.getOrCreateView(forKey: 2) {
      created += 1
      return NSView()
    }
    #expect(reused === first)
    #expect(created == 1)
  }

  @Test func enqueueViewsRecyclesScrollOffKeepsLive() {
    let queue = pool()
    for key in 0..<5 { _ = queue.getOrCreateView(forKey: key) { NSView() } }
    queue.enqueueViews(notInSet: [2, 3])
    #expect(queue.usedCount == 2)
    #expect(queue.getView(forKey: 2) != nil)
    #expect(queue.getView(forKey: 3) != nil)
    #expect(queue.getView(forKey: 0) == nil)
    #expect(queue.getView(forKey: 1) == nil)
    #expect(queue.getView(forKey: 4) == nil)
  }

  // MARK: - B §20 unmount lifecycle

  @Test func scrollOutFiresUnmount() {
    let log = LifecycleLog()
    let queue = pool()
    _ = queue.getOrCreateView(forKey: 1) { SpyRecyclableView(tag: "A", log: log) }
    queue.enqueueView(forKey: 1)
    #expect(log.entries == ["unmount:A"])
    #expect(queue.usedCount == 0)
  }

  @Test func swapUnmountsPrevFirst() {
    let log = LifecycleLog()
    let queue = pool()
    let viewA = queue.getOrCreateView(forKey: 1) { SpyRecyclableView(tag: "A", log: log) }
    queue.enqueueView(forKey: 1)  // A unmounts and returns to the free-list.
    let viewB = queue.getOrCreateView(forKey: 2) { SpyRecyclableView(tag: "B", log: log) }
    // B reuses A's freed view — the previous occupant was unmounted BEFORE reuse.
    #expect(viewB === viewA)
    #expect(log.entries == ["unmount:A"])
  }

  @Test func teardownErrorIsolated() {
    // enqueueView mutates `used` for every non-kept key; the batch snapshots keys
    // first, so recycling one view never corrupts the iteration and every
    // scroll-off view is torn down (P6 extends this to real widget-host errors).
    let log = LifecycleLog()
    let queue = pool()
    for key in 0..<3 { _ = queue.getOrCreateView(forKey: key) { SpyRecyclableView(tag: "\(key)", log: log) } }
    queue.enqueueViews(notInSet: [1])
    #expect(queue.usedCount == 1)
    #expect(queue.getView(forKey: 1) != nil)
    #expect(Set(log.entries) == ["unmount:0", "unmount:2"])
  }

  // MARK: - B §1 borrowed-state restore

  @Test func teardownRestoresBorrowedViewState() {
    let log = LifecycleLog()
    let queue = pool()
    let spy = queue.getOrCreateView(forKey: 1) { SpyRecyclableView(tag: "A", log: log) } as? SpyRecyclableView
    spy?.content = "borrowed"
    spy?.isHidden = false
    queue.enqueueView(forKey: 1)
    // Borrowed state killed on teardown; view reset to the reusable baseline.
    #expect(spy?.content == nil)
    #expect(spy?.isHidden == true)
  }

  // MARK: - B §3 recycled view shows only new content

  @Test func recycledViewHasNoStaleContent() {
    let view = LineRowView()
    let alpha = segment(content: "alpha", newLine: 1)
    let beta = segment(content: "beta", newLine: 2)
    let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    view.configure(segment: alpha, chunkID: ChunkID(raw: 1), rowHeight: 20, font: font, mode: .unified)
    #expect(view.firstRowText == "alpha")

    view.prepareForReuse()
    #expect(view.firstRowText == nil)
    #expect(view.configuredRowCount == 0)

    // Reconfigure onto a different leaf: only the new content, never a ghost.
    view.configure(segment: beta, chunkID: ChunkID(raw: 2), rowHeight: 20, font: font, mode: .unified)
    #expect(view.firstRowText == "beta")
    #expect(view.configuredChunkID == ChunkID(raw: 2))
  }

  private func segment(content: String, newLine: Int) -> LineSegment {
    LineSegment(
      hunkID: HunkID(fileID: "f", index: 0),
      lines: [
        DiffLine(
          origin: .context, oldLineNumber: newLine, newLineNumber: newLine, content: content, noNewlineAtEof: false)
      ],
      window: 0..<1,
      classification: .context
    )
  }
}
