import AppKit
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

  // MARK: - F15 — the ours / base / theirs tint reaches the render

  /// The tinted region preview (`ConflictRegionPreview`) is composed into the widget
  /// content instead of only the action row: a 3-way conflict contributes a green
  /// "Ours", a secondary "Base", and a red "Theirs" section carrying the parsed
  /// current / base / incoming lines. Guards F15 — reverting the preview wiring drops
  /// these sections and this fails.
  @Test func widgetRendersTintedOursBaseTheirsPreview() {
    let conflict = region([
      "<<<<<<< ours", "our change", "||||||| base", "orig", "=======", "their change", ">>>>>>> theirs",
    ])
    let sections = ConflictWidgetContent.previewSections(for: conflict)
    #expect(
      sections == [
        .init(label: "Ours", lines: ["our change"], tint: .ours),
        .init(label: "Base", lines: ["orig"], tint: .base),
        .init(label: "Theirs", lines: ["their change"], tint: .theirs),
      ])

    // A 2-way conflict drops the base band (no secondary section).
    let twoWay = region(["<<<<<<< ours", "a", "=======", "b", ">>>>>>> theirs"])
    #expect(
      ConflictWidgetContent.previewSections(for: twoWay) == [
        .init(label: "Ours", lines: ["a"], tint: .ours),
        .init(label: "Theirs", lines: ["b"], tint: .theirs),
      ])
  }

  /// The widget's own content model exposes those preview sections, so the on-screen
  /// composition (which builds strictly from `contentModel`) can't drift.
  @MainActor
  @Test func widgetContentModelExposesPreview() {
    let host = FakeWidgetLayoutHost()
    let coalescer = LayoutCoalescer(host: host)
    let widget = ConflictWidget(
      key: .placeholder(fileID: "f"),
      region: region(["<<<<<<< ours", "a", "=======", "b", ">>>>>>> theirs"]),
      coalescer: coalescer)
    #expect(!widget.contentModel.preview.isEmpty)
    #expect(widget.contentModel.preview.map(\.label) == ["Ours", "Theirs"])
  }

  // MARK: - F16 / F24 — accept buttons are disabled while accept-WRITE is gated

  /// Accept-WRITE-to-disk is a deferred follow-up, so a normal single-hunk conflict
  /// (which IS auto-resolvable) must still render the accept buttons DISABLED and
  /// offer the working "resolve in editor" escape hatch — the UI must not present a
  /// button whose `onResolve` is a no-op. Guards F24: flipping the default to enabled
  /// (or claiming the buttons act) fails here.
  @Test func acceptDisabledWhileWriteGated() {
    let gated = ConflictAcceptAvailability.resolve(canAutoResolve: true, acceptWriteEnabled: false)
    #expect(gated == .gated)
    #expect(!gated.acceptButtonsEnabled)
    #expect(gated.showsResolveInEditor)

    // Straddling / unbalanced regions can't anchor at all — still disabled + escape.
    let unresolvable = ConflictAcceptAvailability.resolve(canAutoResolve: false, acceptWriteEnabled: false)
    #expect(unresolvable == .unresolvableHere)
    #expect(!unresolvable.acceptButtonsEnabled)
    #expect(unresolvable.showsResolveInEditor)

    // Only when accept-WRITE lands does the auto-resolvable case enable the buttons.
    let enabled = ConflictAcceptAvailability.resolve(canAutoResolve: true, acceptWriteEnabled: true)
    #expect(enabled == .enabled)
    #expect(enabled.acceptButtonsEnabled)
    #expect(!enabled.showsResolveInEditor)
  }

  /// The production-default widget (accept-WRITE gated) reports its accept buttons as
  /// disabled for an auto-resolvable single-hunk conflict — the exact case the audit
  /// flagged as a lying UI.
  @MainActor
  @Test func widgetDefaultsToGatedAccept() {
    let host = FakeWidgetLayoutHost()
    let coalescer = LayoutCoalescer(host: host)
    let widget = ConflictWidget(
      key: .placeholder(fileID: "f"),
      region: region(["<<<<<<< ours", "a", "=======", "b", ">>>>>>> theirs"]),
      coalescer: coalescer)
    #expect(widget.region.canAutoResolve)  // would render enabled accept pre-fix
    #expect(widget.contentModel.acceptAvailability == .gated)
    #expect(!widget.contentModel.acceptAvailability.acceptButtonsEnabled)
    #expect(widget.contentModel.acceptAvailability.showsResolveInEditor)
  }
}
