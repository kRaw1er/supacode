import AppKit

// MARK: - Shared reveal primitive (authored here, consumed by Phase 12 a11y)

/// How a revealed row lands relative to the viewport (under the sticky-header band).
enum RevealAlignment: Equatable, Sendable {
  case top
  case center
  case nearest
}

/// The abstract "seek a row's y and anchor-scroll to it" surface `DiffKeyboardNav`
/// (Phase 10) and VoiceOver focus (Phase 12) share. A protocol so the nav is unit-
/// testable against a fake that captures the revealed index with no live NSView.
@MainActor
protocol DiffRevealing: AnyObject {
  var currentMode: DiffViewMode { get }
  func reveal(row index: Int, align: RevealAlignment)
}

/// Pure anchored-scroll math (port of pierre `computeFocusedRowScrollTopForOffset` /
/// `ScrollIntoView`): given a row's document-space extent, the current viewport, the
/// total document height and a sticky `headerInset`, resolve the desired clip-top y
/// — or `nil` when no scroll is needed (`.nearest` on an already-visible row). No
/// AppKit, so the ~20 boundary cases are unit-testable in isolation.
enum DiffScrollTargetSolver {
  /// The scrollable viewport a reveal solves against: the current top offset, the
  /// clip height, the total document height, and the sticky-header inset.
  struct Viewport: Equatable {
    var visibleMinY: CGFloat
    var height: CGFloat
    var totalHeight: CGFloat
    var headerInset: CGFloat
  }

  static func desiredTop(
    rowTop: CGFloat,
    rowHeight: CGFloat,
    align: RevealAlignment,
    viewport: Viewport
  ) -> CGFloat? {
    let viewportHeight = viewport.height
    let inset = max(0, viewport.headerInset)  // a negative inset degrades to 0
    let maxTop = max(0, viewport.totalHeight - viewportHeight)
    func clamp(_ value: CGFloat) -> CGFloat { max(0, min(value, maxTop)) }

    let rowBottom = rowTop + rowHeight
    let visibleMaxY = viewport.visibleMinY + viewportHeight
    // The unobscured band sits below the sticky header.
    let band = max(0, viewportHeight - inset)

    switch align {
    case .top:
      return clamp(rowTop - inset)
    case .center:
      // Center within the UNOBSCURED band; a row taller than the band top-aligns
      // (minus the sticky inset) so its start stays visible.
      guard rowHeight < band else { return clamp(rowTop - inset) }
      return clamp(rowTop - inset - (band - rowHeight) / 2)
    case .nearest:
      if rowTop < viewport.visibleMinY + inset {
        return clamp(rowTop - inset)  // hidden above / under the header → reveal above
      }
      if rowBottom > visibleMaxY {
        return clamp(rowBottom - viewportHeight)  // below the fold → land at the bottom
      }
      return nil  // already clear of the header, fully visible → no scroll
    }
  }
}

extension DiffViewportController {
  /// The current render dimension (alias for the private-set `mode`, spelled
  /// `currentMode` by consumer phases).
  var currentMode: DiffViewMode { mode }
}

extension DiffViewportController: DiffRevealing {
  /// Shared anchored scroll-to for keyboard nav (Phase 10) AND VoiceOver focus
  /// (Phase 12). Seeks the row's y in the tree (O(log n)) and performs a single
  /// instant scroll that lands it just under the sticky-header band. No stored state
  /// here — the nav cursor (`DiffKeyboardNav.focusedRowIndex`) is the SoT.
  func reveal(row index: Int, align: RevealAlignment = .nearest) {
    guard let hit = tree.seek(index: index, mode: currentMode) else { return }
    reveal(toY: hit.yOrigin, height: hit.rowHeight, align: align)
  }

  /// Direct y entry point (jump-to-file passes `ScrollSpyController.offset(forFile:)`).
  func reveal(
    toY rowTop: CGFloat,
    height: CGFloat = 0,
    align: RevealAlignment = .top,
    headerInset: CGFloat = StickyHeaderOverlay.headerHeight
  ) {
    let visible = visibleRect
    guard
      let target = DiffScrollTargetSolver.desiredTop(
        rowTop: rowTop,
        rowHeight: height,
        align: align,
        viewport: DiffScrollTargetSolver.Viewport(
          visibleMinY: visible.minY,
          height: visible.height,
          totalHeight: tree.totalHeight(currentMode),
          headerInset: headerInset
        )
      )
    else { return }
    // `scroll(toY:)` clamps into range, sets the clip origin under the re-entrancy
    // guard, calls `reflectScrolledClipView`, and re-materializes the window.
    scroll(toY: target)
  }
}

// MARK: - Keyboard navigation (app-level key path — NOT menu equivalents)

/// Single-letter diff-body navigation. Driven from the viewport NSView's
/// `keyDown(with:)` WHILE IT HOLDS FIRST RESPONDER — never registered as menu
/// key-equivalents (CLAUDE.md FocusedAction rule: a menu equivalent fires globally
/// and would swallow `n`/`j`/`/` even inside a focused text field). Inert in the
/// comment editor by construction: the editor is a different first responder, so
/// AppKit routes `keyDown` there and `handle` is never reached.
@MainActor
final class DiffKeyboardNav {
  enum Command: Equatable, Sendable {
    case nextChange, prevChange  // n / p
    case nextFile, prevFile  // ] / [
    case lineDown, lineUp  // j / k
    case expandFile  // o   (Phase 7)
    case moreContext, lessContext  // e / ⇧E (Phase 7)
    case find, help  // / , ?
  }

  private unowned let controller: any DiffRevealing
  private let tree: ChunkTree
  private(set) var focusedRowIndex = 0
  private let send: (DiffReviewFeature.Action) -> Void  // views send actions

  init(
    controller: any DiffRevealing,
    tree: ChunkTree,
    send: @escaping (DiffReviewFeature.Action) -> Void
  ) {
    self.controller = controller
    self.tree = tree
    self.send = send
  }

  /// Pure key → command map. Rejects any ⌘/⌃/⌥ chord (those stay menu/app chords, so
  /// ⌘F / ⌘⌫ still reach the menu); Shift is allowed (`⇧E`, `?`).
  /// `charactersIgnoringModifiers` already reflects Shift, so `⇧E` arrives as "E" and
  /// `?` as "?".
  static func command(for event: NSEvent) -> Command? {
    guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return nil }
    switch event.charactersIgnoringModifiers {
    case "n": return .nextChange
    case "p": return .prevChange
    case "]": return .nextFile
    case "[": return .prevFile
    case "j": return .lineDown
    case "k": return .lineUp
    case "o": return .expandFile
    case "e": return .moreContext
    case "E": return .lessContext
    case "/": return .find
    case "?": return .help
    default: return nil
    }
  }

  /// Called from `keyDown`. Returns true if consumed (the view swallows it; else
  /// `super.keyDown` lets it propagate).
  @discardableResult
  func handle(_ event: NSEvent) -> Bool {
    guard let command = Self.command(for: event) else { return false }
    perform(command)
    return true
  }

  func perform(_ command: Command) {
    switch command {
    case .nextChange: seekChange(forward: true)
    case .prevChange: seekChange(forward: false)
    case .nextFile: seekFile(forward: true)
    case .prevFile: seekFile(forward: false)
    case .lineDown: focusRow(focusedRowIndex + 1)
    case .lineUp: focusRow(max(0, focusedRowIndex - 1))
    case .expandFile:
      if let id = currentFileID() { send(.diffExpandWholeFile(fileID: id)) }  // Phase 7
    case .moreContext:
      if let id = currentFileID() { send(.diffExpandContext(fileID: id, delta: +1)) }
    case .lessContext:
      if let id = currentFileID() { send(.diffExpandContext(fileID: id, delta: -1)) }
    case .find: send(.diffBeginFind)  // Phase 11 entry point
    case .help: send(.diffShowKeyboardHelp)
    }
  }

  /// Called once when a diff opens: land on the first change row, centered.
  func revealFirstChange() {
    guard let index = firstChangeRowIndex() else { return }
    focusRow(index, align: .center)
  }

  // MARK: - Focus + seek

  private func focusRow(_ index: Int, align: RevealAlignment = .nearest) {
    let rowCount = tree.rowCount(controller.currentMode)
    guard rowCount > 0 else { return }
    focusedRowIndex = min(max(0, index), rowCount - 1)
    controller.reveal(row: focusedRowIndex, align: align)  // Phase 12 VO focus routes through the same call
  }

  /// Walk the change-block start rows and land on the next / previous one relative to
  /// the cursor. Consecutive change leaves (a change block split at `maxLeafSpan`) are
  /// coalesced so `n`/`p` step between change BLOCKS, not sub-leaves.
  private func seekChange(forward: Bool) {
    let rows = changeBlockRowIndices()
    guard !rows.isEmpty else { return }
    if forward {
      focusRow(rows.first { $0 > focusedRowIndex } ?? rows.last!)
    } else {
      focusRow(rows.last { $0 < focusedRowIndex } ?? rows.first!)
    }
  }

  /// Step between file-header rows relative to the cursor.
  private func seekFile(forward: Bool) {
    let rows = fileHeaderRowIndices()
    guard !rows.isEmpty else { return }
    if forward {
      focusRow(rows.first { $0 > focusedRowIndex } ?? rows.last!, align: .top)
    } else {
      focusRow(rows.last { $0 < focusedRowIndex } ?? rows.first!, align: .top)
    }
  }

  // MARK: - Tree queries (O(#nodes) walk — an infrequent keypress, like `lineLocation`)

  /// The rendered-row index of the first row of the first change block.
  private func firstChangeRowIndex() -> Int? { changeBlockRowIndices().first }

  /// Ascending rendered-row indices of each change block's first row.
  private func changeBlockRowIndices() -> [Int] {
    var result: [Int] = []
    var previousWasChange = false
    for node in tree.inorderNodes() {
      let isChange = node.chunk.lineSegment?.classification == .change
      if isChange, !previousWasChange,
        let index = tree.rowIndex(for: (chunk: node.id, localRow: 0), mode: controller.currentMode)
      {
        result.append(index)
      }
      previousWasChange = isChange
    }
    return result
  }

  /// Ascending rendered-row indices of every file-header widget.
  private func fileHeaderRowIndices() -> [Int] {
    tree.fileHeaderNodes.values
      .compactMap { tree.rowIndex(for: (chunk: $0, localRow: 0), mode: controller.currentMode) }
      .sorted()
  }

  /// The file id owning the focused row — the last file header at or above it.
  private func currentFileID() -> FileChange.ID? {
    var best: (id: FileChange.ID, row: Int)?
    for (id, headerID) in tree.fileHeaderNodes {
      guard let row = tree.rowIndex(for: (chunk: headerID, localRow: 0), mode: controller.currentMode) else { continue }
      if row <= focusedRowIndex, best == nil || row > best!.row {
        best = (id, row)
      }
    }
    return best?.id
  }
}
