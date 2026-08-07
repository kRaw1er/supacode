import AppKit
import SwiftUI
import Testing

@testable import supacode

/// Phase 10 — `DiffKeyboardNav`: the pure key→command map (rejects ⌘/⌃/⌥, allows
/// Shift), `perform` routing through the shared `reveal(row:)`, `revealFirstChange`
/// on open, focus survival across a virtualization recycle, and the FocusedAction
/// menu-dedupe contract.
@MainActor
struct DiffKeyboardNavTests {
  // MARK: - Test doubles

  /// A fake reveal target that captures the revealed row index (no live NSView).
  @MainActor private final class FakeReveal: DiffRevealing {
    var mode: DiffViewMode = .unified
    var revealed: [(index: Int, align: RevealAlignment)] = []
    var currentMode: DiffViewMode { mode }
    func reveal(row index: Int, align: RevealAlignment) { revealed.append((index, align)) }
  }

  private func key(_ chars: String, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
      characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0)!
  }

  /// A tree: file header (row 0) + 3 context lines (rows 1–3) + a change block
  /// (5 del + 5 add → unified rows 4–13).
  private func changeTree() -> ChunkTree {
    let tree = ChunkTree(metrics: .production)
    var after: ChunkID? = tree.insert(
      .widget(Widget(key: .fileHeader(fileID: "f"), estimatedHeight: 44, payload: .fileHeader(fileID: "f"))),
      after: nil)
    let context = (1...3).map {
      DiffLine(origin: .context, oldLineNumber: $0, newLineNumber: $0, content: "c\($0)", noNewlineAtEof: false)
    }
    after = tree.insert(
      .lineSegment(
        LineSegment(hunkID: HunkID(fileID: "f", index: 0), lines: context, window: 0..<3, classification: .context)),
      after: after)
    let change =
      (0..<5).map {
        DiffLine(origin: .deletion, oldLineNumber: $0 + 4, newLineNumber: nil, content: "d", noNewlineAtEof: false)
      }
      + (0..<5).map {
        DiffLine(origin: .addition, oldLineNumber: nil, newLineNumber: $0 + 4, content: "a", noNewlineAtEof: false)
      }
    _ = tree.insert(
      .lineSegment(
        LineSegment(hunkID: HunkID(fileID: "f", index: 0), lines: change, window: 0..<10, classification: .change)),
      after: after)
    return tree
  }

  // MARK: - command(for:) map

  @Test func commandMapMatchesEveryKeyAndRejectsChords() {
    #expect(DiffKeyboardNav.command(for: key("n")) == .nextChange)
    #expect(DiffKeyboardNav.command(for: key("p")) == .prevChange)
    #expect(DiffKeyboardNav.command(for: key("]")) == .nextFile)
    #expect(DiffKeyboardNav.command(for: key("[")) == .prevFile)
    #expect(DiffKeyboardNav.command(for: key("j")) == .lineDown)
    #expect(DiffKeyboardNav.command(for: key("k")) == .lineUp)
    #expect(DiffKeyboardNav.command(for: key("o")) == .expandFile)
    #expect(DiffKeyboardNav.command(for: key("e")) == .moreContext)
    #expect(DiffKeyboardNav.command(for: key("E", .shift)) == .lessContext)  // ⇧E
    #expect(DiffKeyboardNav.command(for: key("/")) == .find)
    #expect(DiffKeyboardNav.command(for: key("?", .shift)) == .help)  // ? is shift+/

    // Reject ⌘/⌃/⌥ chords (so ⌘F / ⌘⌫ / ⌥ nav still reach the menu / app).
    #expect(DiffKeyboardNav.command(for: key("n", .command)) == nil)
    #expect(DiffKeyboardNav.command(for: key("j", .control)) == nil)
    #expect(DiffKeyboardNav.command(for: key("p", .option)) == nil)
    // Unmapped key.
    #expect(DiffKeyboardNav.command(for: key("x")) == nil)
  }

  // MARK: - perform(.lineDown) increments + reveals

  @Test func performLineNavigation() {
    let fake = FakeReveal()
    let tree = ViewportTestSupport.contextLeaves(Array(1...10))
    let nav = DiffKeyboardNav(controller: fake, tree: tree, send: { _ in })

    nav.perform(.lineDown)
    #expect(nav.focusedRowIndex == 1)
    #expect(fake.revealed.last?.index == 1)

    nav.perform(.lineDown)
    #expect(nav.focusedRowIndex == 2)
    #expect(fake.revealed.last?.index == 2)

    nav.perform(.lineUp)
    #expect(nav.focusedRowIndex == 1)
    #expect(fake.revealed.last?.index == 1)

    // lineUp clamps at 0.
    nav.perform(.lineUp)
    nav.perform(.lineUp)
    #expect(nav.focusedRowIndex == 0)
  }

  // MARK: - handle() consumes mapped keys, ignores chords

  @Test func handleConsumesMappedKeysOnly() {
    let fake = FakeReveal()
    let nav = DiffKeyboardNav(controller: fake, tree: ViewportTestSupport.contextLeaves(Array(1...10)), send: { _ in })
    #expect(nav.handle(key("j")) == true)  // consumed
    #expect(nav.handle(key("n", .command)) == false)  // chord → not consumed (falls through)
    #expect(nav.handle(key("x")) == false)  // unmapped → not consumed
  }

  // MARK: - revealFirstChange seeks the first change row

  @Test func revealFirstChangeSeeksFirstChangeRow() {
    let fake = FakeReveal()
    let nav = DiffKeyboardNav(controller: fake, tree: changeTree(), send: { _ in })
    nav.revealFirstChange()
    // fileHeader(row 0) + 3 context(rows 1–3) → first change block starts at row 4.
    #expect(nav.focusedRowIndex == 4)
    #expect(fake.revealed.last?.index == 4)
    #expect(fake.revealed.last?.align == .center)
  }

  @Test func revealFirstChangeNoOpWithoutChanges() {
    let fake = FakeReveal()
    let nav = DiffKeyboardNav(controller: fake, tree: ViewportTestSupport.contextLeaves(Array(1...10)), send: { _ in })
    nav.revealFirstChange()
    #expect(fake.revealed.isEmpty)  // no change block → no-op
    #expect(nav.focusedRowIndex == 0)
  }

  // MARK: - o / e / ⇧E / ? / send routing

  @Test func performRoutesFileScopedCommandsThroughSend() {
    let fake = FakeReveal()
    let tree = changeTree()
    var sent: [DiffReviewFeature.Action] = []
    let nav = DiffKeyboardNav(controller: fake, tree: tree, send: { sent.append($0) })
    // Move the cursor into the file body so `currentFileID()` resolves "f".
    nav.perform(.lineDown)  // row 1 (inside file f)

    nav.perform(.expandFile)
    nav.perform(.moreContext)
    nav.perform(.lessContext)
    nav.perform(.find)
    nav.perform(.help)
    #expect(
      sent == [
        .diffExpandWholeFile(fileID: "f"),
        .diffExpandContext(fileID: "f", delta: 1),
        .diffExpandContext(fileID: "f", delta: -1),
        .diffBeginFind,
        .diffShowKeyboardHelp,
      ])
  }

  // MARK: - navSurvivesVirtualizationRecycle (NSVIEW)

  @Test func navSurvivesVirtualizationRecycle() {
    let controller = ViewportTestSupport.controller(width: 800, clipHeight: 600)
    let tree = ViewportTestSupport.contextLeaves(Array(1...500))  // 10000pt tall
    controller.apply(tree: tree, mode: .unified, scrollPreserving: false)
    let nav = DiffKeyboardNav(controller: controller, tree: tree, send: { _ in })

    for _ in 0..<10 { nav.perform(.lineDown) }  // focus row 10 (y = 200)
    #expect(nav.focusedRowIndex == 10)

    // Fling far past the overscan so row 10's view is recycled off.
    controller.scroll(toY: 9000)
    // The keyboard cursor is decoupled from the view — it survives the recycle.
    #expect(nav.focusedRowIndex == 10)

    // Still navigable afterward.
    nav.perform(.lineDown)
    #expect(nav.focusedRowIndex == 11)
  }

  // MARK: - Focused-action token dedupe (menu-invalidation contract)

  @Test func focusedActionTokenDedupe() {
    let enabled = FocusedAction<Void>(isEnabled: true, token: nil, perform: {})
    let enabledAgain = FocusedAction<Void>(isEnabled: true, token: nil, perform: {})
    #expect(enabled == enabledAgain)  // equal → focusedSceneValue does NOT republish → AppKit menu not rebuilt

    let disabled = FocusedAction<Void>(isEnabled: false, token: nil, perform: {})
    #expect(enabled != disabled)  // isEnabled flip → menu updates its disabled state

    let tokenX = FocusedAction<Void>(isEnabled: true, token: AnyHashable("x"), perform: {})
    let tokenY = FocusedAction<Void>(isEnabled: true, token: AnyHashable("y"), perform: {})
    #expect(tokenX != tokenY)  // token change → republish
  }
}
