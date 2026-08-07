import Foundation
import Testing

@testable import supacode

struct TerminalTextSinkResolverTests {
  private typealias TabEntry = (id: TerminalTabID, kind: TerminalTabItem.Kind)

  private func tab(_ id: TerminalTabID, _ kind: TerminalTabItem.Kind) -> TabEntry {
    (id, kind)
  }

  @Test func selectedTerminalTabWithFocusIsChosen() {
    let terminal = TerminalTabID()
    let focused = UUID()
    let result = TerminalTextSinkResolver.resolve(
      orderedTabs: [tab(terminal, .terminal)],
      selectedTabID: terminal,
      focusedSurfaceByTab: [terminal: focused],
      surfaceIDsByTab: [terminal: [focused]]
    )
    #expect(result?.tabID == terminal)
    #expect(result?.surfaceID == focused)
  }

  @Test func selectedDiffTabSkipsToFirstTerminalTabsFocusedSurface() {
    let diff = TerminalTabID()
    let terminal = TerminalTabID()
    let focused = UUID()
    let result = TerminalTextSinkResolver.resolve(
      orderedTabs: [tab(diff, .diff), tab(terminal, .terminal)],
      selectedTabID: diff,
      focusedSurfaceByTab: [terminal: focused],
      surfaceIDsByTab: [terminal: [focused, UUID()]]
    )
    #expect(result?.tabID == terminal)
    #expect(result?.surfaceID == focused)
  }

  @Test func terminalTabWithoutFocusFallsBackToFirstSurface() {
    let terminal = TerminalTabID()
    let first = UUID()
    let result = TerminalTextSinkResolver.resolve(
      orderedTabs: [tab(terminal, .terminal)],
      selectedTabID: nil,
      focusedSurfaceByTab: [:],
      surfaceIDsByTab: [terminal: [first, UUID()]]
    )
    #expect(result?.tabID == terminal)
    #expect(result?.surfaceID == first)
  }

  @Test func onlyDiffTabReturnsNil() {
    let diff = TerminalTabID()
    let result = TerminalTextSinkResolver.resolve(
      orderedTabs: [tab(diff, .diff)],
      selectedTabID: diff,
      focusedSurfaceByTab: [:],
      surfaceIDsByTab: [:]
    )
    #expect(result == nil)
  }
}
