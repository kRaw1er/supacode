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
    let diff = state.openDiffTab(filePath: "/tmp/repo/wt-diff/a.swift")
    #expect(state.tabManager.tabs.map(\.id) == [term, diff])
    #expect(state.tabManager.tabs.first { $0.id == diff }?.kind == .diff)
    #expect(state.surfaceIDs(inTab: diff).isEmpty)
    #expect(state.activeSurfaceID(for: diff) == nil)
    #expect(state.surfaceIDs(inTab: term).count == 1)
  }

  @Test func selectingDiffTabDoesNotSpawnSurface() {
    let state = makeState()
    _ = state.createTab()!
    let diff = state.openDiffTab(filePath: "/tmp/x")
    let before = state.allSurfaceIDs.count
    state.selectTab(diff)
    #expect(state.tabManager.selectedTabId == diff)
    #expect(state.allSurfaceIDs.count == before)
  }

  @Test func closeDiffTabPicksNeighborAndLeavesTerminalIntact() {
    let state = makeState()
    let term = state.createTab()!
    let diff = state.openDiffTab(filePath: "/tmp/x")
    state.closeTab(diff)
    #expect(state.tabManager.tabs.map(\.id) == [term])
    #expect(state.tabManager.selectedTabId == term)
    #expect(state.surfaceIDs(inTab: term).count == 1)
  }

  @Test func closingTerminalNeighborOfDiffTabIsUnaffected() {
    let state = makeState()
    let term = state.createTab()!
    let diff = state.openDiffTab(filePath: "/tmp/x")
    state.selectTab(term)
    state.closeTab(term)
    #expect(state.tabManager.tabs.map(\.id) == [diff])
    #expect(state.tabManager.selectedTabId == diff)
    #expect(state.allSurfaceIDs.isEmpty)
  }

  @Test func openDiffTabDedupesByPath() {
    let state = makeState()
    let first = state.openDiffTab(filePath: "/tmp/repo/a.swift")
    let second = state.openDiffTab(filePath: "/tmp/repo/a.swift")
    #expect(first == second)
    #expect(state.tabManager.tabs.filter { $0.kind == .diff }.count == 1)
    #expect(state.tabManager.selectedTabId == first)
  }

  @Test func captureLayoutSnapshotExcludesDiffTabs() {
    let state = makeState()
    _ = state.createTab()!
    _ = state.openDiffTab(filePath: "/tmp/x")
    let snapshot = state.captureLayoutSnapshot()
    #expect(snapshot?.tabs.count == 1)
  }

  @Test func diffTabEmitsProjectionSoRowRenders() {
    let state = makeState()
    var projected: [TerminalTabID] = []
    state.onTabProjectionChanged = { projected.append($0.tabID) }
    let diff = state.openDiffTab(filePath: "/tmp/x")
    #expect(projected.contains(diff))
  }

  @Test func closingDiffTabEmitsTabRemoved() {
    let state = makeState()
    var removed: [TerminalTabID] = []
    state.onTabRemoved = { removed.append($0) }
    let diff = state.openDiffTab(filePath: "/tmp/x")
    state.closeTab(diff)
    #expect(removed == [diff])
  }
}
