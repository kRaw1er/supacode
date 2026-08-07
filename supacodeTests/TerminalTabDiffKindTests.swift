import ComposableArchitecture
import Foundation
import Sharing
import Testing

@testable import supacode

@MainActor
struct TerminalTabDiffKindTests {
  private func makeState() -> WorktreeTerminalState {
    WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: Worktree(
        id: "/tmp/repo/wt-diff",
        name: "wt-diff",
        detail: "d",
        workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-diff"),
        repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
      ),
      splitPreserveZoomOnNavigation: { false }
    )
  }

  @Test func diffTabAllocatesNoSurface() {
    let state = makeState()
    let term = state.createTab()!
    let diff = state.openDiffTab(filePath: "/tmp/repo/wt-diff/a.swift", source: .workingTree)
    #expect(state.tabManager.tabs.map(\.id) == [term, diff])
    #expect(state.tabManager.tabs.first { $0.id == diff }?.kind == .diff)
    #expect(state.surfaceIDs(inTab: diff).isEmpty)
    #expect(state.activeSurfaceID(for: diff) == nil)
    #expect(state.surfaceIDs(inTab: term).count == 1)
  }

  @Test func selectingDiffTabDoesNotSpawnSurface() {
    let state = makeState()
    _ = state.createTab()!
    let diff = state.openDiffTab(filePath: "/tmp/x", source: .workingTree)
    let before = state.allSurfaceIDs.count
    state.selectTab(diff)
    #expect(state.tabManager.selectedTabId == diff)
    #expect(state.allSurfaceIDs.count == before)
  }

  @Test func closeDiffTabPicksNeighborAndLeavesTerminalIntact() {
    let state = makeState()
    let term = state.createTab()!
    let diff = state.openDiffTab(filePath: "/tmp/x", source: .workingTree)
    state.closeTab(diff)
    #expect(state.tabManager.tabs.map(\.id) == [term])
    #expect(state.tabManager.selectedTabId == term)
    #expect(state.surfaceIDs(inTab: term).count == 1)
  }

  @Test func closingTerminalNeighborOfDiffTabIsUnaffected() {
    let state = makeState()
    let term = state.createTab()!
    let diff = state.openDiffTab(filePath: "/tmp/x", source: .workingTree)
    state.selectTab(term)
    state.closeTab(term)
    #expect(state.tabManager.tabs.map(\.id) == [diff])
    #expect(state.tabManager.selectedTabId == diff)
    #expect(state.allSurfaceIDs.isEmpty)
  }

  @Test func openDiffTabDedupesByPath() {
    let state = makeState()
    let first = state.openDiffTab(filePath: "/tmp/repo/a.swift", source: .workingTree)
    let second = state.openDiffTab(filePath: "/tmp/repo/a.swift", source: .workingTree)
    #expect(first == second)
    #expect(state.tabManager.tabs.filter { $0.kind == .diff }.count == 1)
    #expect(state.tabManager.selectedTabId == first)
  }

  @Test func openDiffTabScopesDedupBySource() {
    let state = makeState()
    // Same path under two sources → two distinct tabs.
    let working = state.openDiffTab(filePath: "/tmp/repo/a.swift", source: .workingTree)
    let base = state.openDiffTab(filePath: "/tmp/repo/a.swift", source: .baseBranch(ref: "main"))
    #expect(working != base)
    #expect(state.tabManager.tabs.filter { $0.kind == .diff }.count == 2)
    #expect(state.diffSource(for: working) == .workingTree)
    #expect(state.diffSource(for: base) == .baseBranch(ref: "main"))
    // Re-opening the same (path, source) focuses the existing tab (no third tab).
    let baseAgain = state.openDiffTab(filePath: "/tmp/repo/a.swift", source: .baseBranch(ref: "main"))
    #expect(baseAgain == base)
    #expect(state.tabManager.tabs.filter { $0.kind == .diff }.count == 2)
    #expect(state.tabManager.selectedTabId == base)
  }

  @Test func captureLayoutSnapshotExcludesDiffTabs() {
    let state = makeState()
    _ = state.createTab()!
    _ = state.openDiffTab(filePath: "/tmp/x", source: .workingTree)
    let snapshot = state.captureLayoutSnapshot()
    #expect(snapshot?.tabs.count == 1)
  }

  @Test func diffTabEmitsProjectionSoRowRenders() {
    let state = makeState()
    var projected: [TerminalTabID] = []
    state.onTabProjectionChanged = { projected.append($0.tabID) }
    let diff = state.openDiffTab(filePath: "/tmp/x", source: .workingTree)
    #expect(projected.contains(diff))
  }

  @Test func closingDiffTabEmitsTabRemoved() {
    let state = makeState()
    var removed: [TerminalTabID] = []
    state.onTabRemoved = { removed.append($0) }
    let diff = state.openDiffTab(filePath: "/tmp/x", source: .workingTree)
    state.closeTab(diff)
    #expect(removed == [diff])
  }

  // MARK: - 6.A center ⌘-number switching includes the diff tab

  @Test func selectTabAtIndexCountsDiffTabPositionally() {
    let state = makeState()
    let term = state.createTab()!
    let diff = state.openDiffTab(filePath: "/tmp/repo/a.swift", source: .workingTree)
    // ⌘2 selects the second positional tab — the diff tab.
    state.selectTabAtIndex(2)
    #expect(state.tabManager.selectedTabId == diff)
    // ⌘1 selects the terminal tab again.
    state.selectTabAtIndex(1)
    #expect(state.tabManager.selectedTabId == term)
    // Out-of-range clamps to the last tab (the diff tab).
    state.selectTabAtIndex(9)
    #expect(state.tabManager.selectedTabId == diff)
  }

  // MARK: - 6.C / 6.F focusing a diff tab is inert for surfaces + notifications

  @Test func focusingDiffTabLeavesSurfacesAndNotificationsUntouched() {
    // Appending a notification touches the injected clock/date, so build the
    // state under test dependencies (they snapshot at init).
    let state = withDependencies {
      $0.continuousClock = TestClock()
      $0.date = .constant(Date(timeIntervalSince1970: 0))
    } operation: {
      makeState()
    }
    let term = state.createTab()!
    let surfaceID = state.surfaceIDs(inTab: term).first!
    // Seed an unread notification on the terminal surface.
    state.appendHookNotification(title: "Build", body: "done", surfaceID: surfaceID)
    let unreadBefore = state.notifications.count { !$0.isRead }
    let surfacesBefore = state.allSurfaceIDs

    var diffProjections: [WorktreeTabProjection] = []
    state.onTabProjectionChanged = { diffProjections.append($0) }
    let diff = state.openDiffTab(filePath: "/tmp/x", source: .workingTree)
    // Selecting the diff tab must not create/destroy a surface (9.5 / 6.F) …
    state.selectTab(diff)
    #expect(state.tabManager.selectedTabId == diff)
    #expect(state.allSurfaceIDs == surfacesBefore)
    // … nor mark the terminal surface's notification read (bell/dock, 6.C).
    #expect(state.notifications.count { !$0.isRead } == unreadBefore)
    // The diff tab's own projection never contributes an unseen count.
    #expect(diffProjections.contains { $0.tabID == diff && $0.unseenNotificationCount == 0 })
    #expect(diffProjections.allSatisfy { $0.tabID != diff || $0.unseenNotificationCount == 0 })
  }
}
