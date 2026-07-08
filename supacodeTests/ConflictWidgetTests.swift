import Testing

@testable import supacode

/// Phase 13 (C 15.9) — the conflict widget's parse + accept model. Inline
/// `<<<<<<< / ======= / >>>>>>>` markers parse into ours / theirs regions; each
/// accept resolves to the right side; a region that straddles hunk boundaries
/// (unbalanced markers) disables accept (`canAutoResolve == false`) and offers
/// "resolve in editor" instead — gate, don't guess.
struct ConflictWidgetTests {

  private func line(_ content: String) -> DiffLine {
    DiffLine(origin: .context, oldLineNumber: nil, newLineNumber: nil, content: content, noNewlineAtEof: false)
  }

  private func region(_ contents: [String], straddlesHunks: Bool = false) -> ConflictRegion {
    ConflictRegion.parse(contents.map(line), straddlesHunks: straddlesHunks)
  }

  @Test func parsesOursAndTheirsRegions() {
    let conflict = region([
      "<<<<<<< ours", "our change", "=======", "their change", ">>>>>>> theirs",
    ])
    #expect(conflict.currentLines == ["our change"])
    #expect(conflict.incomingLines == ["their change"])
    #expect(conflict.baseLines.isEmpty)
    #expect(conflict.hasConflict)
  }

  @Test func parsesThreeWayBaseSection() {
    let conflict = region([
      "<<<<<<< ours", "our change", "||||||| base", "orig", "=======", "their change", ">>>>>>> theirs",
    ])
    #expect(conflict.currentLines == ["our change"])
    #expect(conflict.baseLines == ["orig"])
    #expect(conflict.incomingLines == ["their change"])
  }

  @Test func acceptResolvesToChosenSide() {
    let conflict = region([
      "<<<<<<< ours", "our change", "=======", "their change", ">>>>>>> theirs",
    ])
    #expect(conflict.resolved(keeping: .current) == ["our change"])
    #expect(conflict.resolved(keeping: .incoming) == ["their change"])
    #expect(conflict.resolved(keeping: .both) == ["our change", "their change"])
  }

  @Test func balancedSingleHunkCanAutoResolve() {
    let conflict = region(["<<<<<<< ours", "a", "=======", "b", ">>>>>>> theirs"])
    #expect(conflict.canAutoResolve)
  }

  @Test func straddlingHunksDisablesAccept() {
    // Explicit straddle flag from the chunk-builder ⇒ ambiguous split ⇒ accept off.
    let straddled = region(["<<<<<<< ours", "a", "=======", "b", ">>>>>>> theirs"], straddlesHunks: true)
    #expect(!straddled.canAutoResolve)
  }

  @Test func unbalancedMarkersDisableAccept() {
    // A conflict start with no matching end (region split across hunks) ⇒ accept off.
    let unbalanced = region(["<<<<<<< ours", "a", "=======", "b"])
    #expect(!unbalanced.canAutoResolve)
  }

  // MARK: - collapsedStillRendersHeader — the header chunk survives any body state

  /// A merge-conflict file always emits its file-header chunk regardless of its body:
  /// with a full conflict body, and with NO body at all (empty hunks — the collapsed /
  /// stripped-body analog). pierre's explicit carve-out: the conflict header renders
  /// even when the body is skipped, so a collapsed conflict never loses its identity row.
  @MainActor
  @Test func collapsedStillRendersHeader() {
    func headerCount(_ chunks: [Chunk]) -> Int {
      chunks.filter { chunk in
        if case .widget(let widget) = chunk, case .fileHeader = widget.key { return true }
        return false
      }
      .count
    }
    func firstIsHeader(_ chunks: [Chunk]) -> Bool {
      guard case .widget(let widget) = chunks.first, case .fileHeader = widget.key else { return false }
      return true
    }
    let conflicted = DiffFixture.file(status: .conflicted)

    // With a full conflict body (hunks): exactly one header, emitted first.
    let withBody = ChunkTreeBuilder.classify(
      file: conflicted,
      hunks: [
        DiffFixture.hunk([
          DiffFixture.line(.deletion, old: 1, "our change"),
          DiffFixture.line(.addition, new: 1, "their change"),
        ])
      ],
      expanded: [])
    #expect(headerCount(withBody) == 1)
    #expect(firstIsHeader(withBody))

    // With NO body (empty hunks — the collapsed / stripped-body case): the header is
    // STILL emitted (and stays first), so the file never silently disappears.
    let noBody = ChunkTreeBuilder.classify(file: conflicted, hunks: [], expanded: [])
    #expect(headerCount(noBody) == 1)
    #expect(firstIsHeader(noBody))
  }
}
