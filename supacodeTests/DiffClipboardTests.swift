import AppKit
import Testing

@testable import supacode

/// Phase 11 — model-sourced clean copy (PURE). Covers: clean text with no `+`/`-` /
/// gutter numbers (they were never in the store); side-awareness (split-left → old,
/// split-right → new; a context line copied from either side is identical); the
/// unified whole-line helper reading each row's own side (deletions from old,
/// additions / context from new); grapheme-snapped endpoints; tabs preserved as real
/// `\t`; no invented trailing newline for a `noNewlineAtEof` final line; and bidi /
/// RLO copied in logical (memory) order, byte-for-byte, spoof surfaced not sanitized.
@MainActor
struct DiffClipboardTests {
  // MARK: - Helpers

  private func store(_ text: String) -> UTF16LineStore { UTF16LineStore(bridging: text) }

  private func endpoint(_ side: DiffSide, _ line: Int, _ offset: Int) -> DiffClipboard.Endpoint {
    DiffClipboard.Endpoint(side: side, lineNumber: line, utf16Offset: offset)
  }

  private func selection(
    _ side: DiffSide, _ startLine: Int, _ startOffset: Int, _ endLine: Int, _ endOffset: Int
  ) -> DiffClipboard.Selection {
    DiffClipboard.Selection(
      anchor: endpoint(side, startLine, startOffset), head: endpoint(side, endLine, endOffset))
  }

  /// A selection covering `line` fully (offset 0 → its content length).
  private func fullLine(_ side: DiffSide, _ line: Int, in source: UTF16LineStore) -> DiffClipboard.Selection {
    selection(side, line, 0, line, source.line(line).length)
  }

  private let noNewlineNever: (DiffSide, Int) -> Bool = { _, _ in false }

  // MARK: - C 13.7 clean text — no markers, no gutter numbers — and side-aware

  @Test func cleanSideAwareText() {
    // new blob: context "ctx" (line 0), addition "add" (line 1).
    // old blob: context "ctx" (line 0), deletion "del" (line 1).
    let newStore = store("ctx\nadd\n")
    let oldStore = store("ctx\ndel\n")
    let stores: (DiffSide) -> UTF16LineStore = { $0 == .new ? newStore : oldStore }

    // Addition copied from the new (right) side — clean, no leading "+".
    let add = DiffClipboard.string(
      for: fullLine(.new, 1, in: newStore), store: stores, lineHasNoNewline: noNewlineNever)
    #expect(add == "add\n")
    #expect(!add.contains("+"))
    #expect(!add.contains("1"))  // no gutter number leaked

    // Deletion copied from the old (left) side — clean, no leading "-".
    let del = DiffClipboard.string(
      for: fullLine(.old, 1, in: oldStore), store: stores, lineHasNoNewline: noNewlineNever)
    #expect(del == "del\n")
    #expect(!del.contains("-"))

    // A context line copied from EITHER side is byte-identical.
    let ctxNew = DiffClipboard.string(
      for: fullLine(.new, 0, in: newStore), store: stores, lineHasNoNewline: noNewlineNever)
    let ctxOld = DiffClipboard.string(
      for: fullLine(.old, 0, in: oldStore), store: stores, lineHasNoNewline: noNewlineNever)
    #expect(ctxNew == ctxOld)
    #expect(ctxNew == "ctx\n")
  }

  // MARK: - C 13.9 unified whole-line helper reads each row's own side

  @Test func unifiedWholeLineHelperMixesSides() {
    // A modified file: deletion "old text" (old #1) + addition "new text" (new #1).
    let fileChange = DiffFixture.file(path: "a.swift")
    let hunk = DiffFixture.hunk([
      DiffFixture.line(.deletion, old: 1, new: nil, "old text"),
      DiffFixture.line(.addition, old: nil, new: 1, "new text"),
    ])
    let tree = ChunkTreeFixture.files([ChunkTreeFixture.FileSpec(file: fileChange, hunks: [hunk])])

    // Stores whose git line 1 (→ 0-based store index 0) carries each side's text.
    let oldStore = store("old text\n")
    let newStore = store("new text\n")
    let stores: (DiffSide) -> UTF16LineStore = { $0 == .new ? newStore : oldStore }

    // Resolve the deletion + addition rows through the tree projection.
    var deletionRow: Int?
    var additionRow: Int?
    var widgetRow: Int?
    for row in 0..<tree.rowCount(.unified) {
      guard let resolved = tree.diffLine(atRow: row, mode: .unified) else {
        if widgetRow == nil { widgetRow = row }
        continue
      }
      if resolved.side == .old { deletionRow = row }
      if resolved.side == .new { additionRow = row }
    }
    guard let deletionRow, let additionRow else {
      Issue.record("rows not resolved")
      return
    }

    let text = DiffClipboard.string(
      forRows: [deletionRow, additionRow], tree: tree, mode: .unified, store: stores)
    #expect(text == "old text\nnew text")  // del from OLD store, add from NEW store — mixed
    #expect(!text.contains("+"))
    #expect(!text.contains("-"))

    // A widget row (file / hunk header) resolves to nil and is dropped.
    if let widgetRow {
      let empty = DiffClipboard.string(forRows: [widgetRow], tree: tree, mode: .unified, store: stores)
      #expect(empty.isEmpty)
    }
  }

  // MARK: - D §I2 / §8 / §9 grapheme-snap + tabs + no invented newline

  @Test func copyGraphemeSnappedSideAwareTabsNoInventedNewline() {
    // Tabs preserved as real `\t`, never expanded to spaces.
    let tabStore = store("a\tb\tc\n")
    let tabText = DiffClipboard.string(
      for: fullLine(.new, 0, in: tabStore), store: { _ in tabStore }, lineHasNoNewline: noNewlineNever)
    #expect(tabText.hasPrefix("a\tb\tc"))
    #expect(tabText.contains("\t"))
    #expect(!tabText.contains("    "))  // not tab-expanded

    // No invented trailing newline for a `noNewlineAtEof` final line.
    let noNlStore = store("a\nb\nlast")  // final line "last" — no EOF newline in the file
    let noNlText = DiffClipboard.string(
      for: fullLine(.new, 2, in: noNlStore), store: { _ in noNlStore },
      lineHasNoNewline: { _, line in line == 2 })  // line 2 IS noNewlineAtEof
    #expect(noNlText == "last")  // NO trailing "\n"

    // A start offset landing INSIDE a surrogate pair snaps OUT so a lone surrogate is
    // never emitted — the whole grapheme rides along.
    let grin = UnicodeFixtures.grin
    let emojiStore = store("x\(grin)y\n")  // x(1) + grin(2) + y(1)
    let emojiText = DiffClipboard.string(
      for: selection(.new, 0, 2, 0, 4),  // start 2 = low surrogate of the grin
      store: { _ in emojiStore }, lineHasNoNewline: noNewlineNever)
    #expect(emojiText.hasPrefix("\(grin)y"))  // start snapped 2 → 1, whole grin included
    #expect(emojiText.unicodeScalars.contains { $0 == Unicode.Scalar(0x1F600)! })
  }

  // MARK: - D §5 bidi / RLO copied in logical (memory) order, spoof surfaced

  @Test func copyLogicalOrderRLORoundTrips() {
    // A bidi line round-trips byte-for-byte in logical (memory) order.
    let bidi = UnicodeFixtures.bidiAssign  // "let שלום = 1"
    let bidiStore = store("\(bidi)\n")
    let bidiText = DiffClipboard.string(
      for: fullLine(.new, 0, in: bidiStore), store: { _ in bidiStore }, lineHasNoNewline: noNewlineNever)
    #expect(bidiText == "\(bidi)\n")  // logical order preserved exactly

    // A copied RLO stays RLO — visual reordering is never baked into the clipboard, and
    // the spoofing control is SURFACED (not sanitized — that is the send path's job).
    let rloLine = "a\(UnicodeFixtures.rlo)bc"
    let rloStore = store("\(rloLine)\n")
    let rloText = DiffClipboard.string(
      for: fullLine(.new, 0, in: rloStore), store: { _ in rloStore }, lineHasNoNewline: noNewlineNever)
    #expect(rloText.unicodeScalars.contains { $0 == Unicode.Scalar(0x202E)! })  // RLO present
    #expect(rloText.hasPrefix(rloLine))  // logical (memory) order, spoof surfaced
  }

  // MARK: - copy → NSPasteboard

  @Test func copyWritesToPasteboard() {
    let unique = "diff-copy-\(UUID().uuidString)"
    DiffClipboard.copy(unique)
    #expect(NSPasteboard.general.string(forType: .string) == unique)
  }
}
