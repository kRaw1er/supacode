import AppKit

/// Model-sourced clean copy for the diff body. The `+` / `-` markers and gutter line
/// numbers were NEVER in the `UTF16LineStore` — they are gutter glyphs the viewport
/// draws (Phase 3 `GutterRenderer`), not content — so reading the store IS the clean
/// text: no marker or number can leak because none was ever stored. Real `\t` rides
/// along unchanged (Phase 3 keeps tabs in the store).
///
/// Side-awareness falls out for free: in **split** the drag is confined to one column,
/// so a `Selection` stays within one side; in **unified** the whole-line helper reads
/// each row's OWN side (`ChunkTree.diffLine(atRow:)` → `.old` for a deletion row,
/// `.new` otherwise), so a mixed selection copies deletions from the old blob and
/// additions / context from the new blob — exactly what is on screen.
///
/// Stateless (a caseless `enum`, per CLAUDE.md).
enum DiffClipboard {
  /// One end of a selection: which side's store, the **0-based store line index** on
  /// that side, and the line-relative UTF-16 offset within that line.
  struct Endpoint: Equatable, Sendable {
    var side: DiffSide
    var lineNumber: Int
    var utf16Offset: Int
  }

  /// A drag selection, always confined to one side (split column / unified body).
  struct Selection: Equatable, Sendable {
    var anchor: Endpoint
    var head: Endpoint

    /// Normalized top-left → bottom-right in the selection's own line/offset order.
    var ordered: (Endpoint, Endpoint) {
      let first = anchor
      let second = head
      if first.lineNumber != second.lineNumber {
        return first.lineNumber < second.lineNumber ? (first, second) : (second, first)
      }
      return first.utf16Offset <= second.utf16Offset ? (first, second) : (second, first)
    }
  }

  /// Reconstruct the selected text. `store(side)` yields the side's `UTF16LineStore`;
  /// `lineHasNoNewline(side, storeIndex)` mirrors `DiffLine.noNewlineAtEof` for the
  /// file's final line. Endpoints are snapped OUT to composed-character boundaries so a
  /// lone surrogate half / orphan combining mark is never emitted. Bidi text is copied
  /// in logical (memory) order — visual reordering is never baked into the clipboard.
  static func string(
    for selection: Selection,
    store: (DiffSide) -> UTF16LineStore,
    lineHasNoNewline: (DiffSide, Int) -> Bool
  ) -> String {
    let (start, end) = selection.ordered
    let side = start.side  // a selection stays within one side
    let source = store(side)
    guard start.lineNumber >= 0, end.lineNumber < source.lineCount, start.lineNumber <= end.lineNumber else {
      return ""
    }
    var out = ""
    for lineIndex in start.lineNumber...end.lineNumber {
      let content = source.line(lineIndex)  // content only — no marker, no number, trailing newline stripped
      let rawLow = lineIndex == start.lineNumber ? start.utf16Offset : 0
      let rawHigh = lineIndex == end.lineNumber ? end.utf16Offset : content.length
      let low = snappedLower(rawLow, in: content)
      let high = snappedUpper(rawHigh, in: content)
      if low < high {
        out += content.substring(with: NSRange(location: low, length: high - low))  // real `\t` rides along
      }
      if lineIndex != end.lineNumber { out += "\n" }
    }
    // Respect no-newline-at-EOF: a full-through-end selection of a line whose file
    // terminates it with a newline includes that newline; a `noNewlineAtEof` final line
    // must NOT gain a trailing newline the file does not have.
    let endContent = source.line(end.lineNumber)
    let endHigh = snappedUpper(end.utf16Offset, in: endContent)
    if endHigh >= endContent.length,
      !lineHasNoNewline(side, end.lineNumber),
      end.lineNumber < source.lineCount
    {
      out += "\n"
    }
    return out
  }

  /// Whole-line copy (⌘C with no sub-line selection): a run of displayed rows, each
  /// pulled from its OWN side. Unified copy is thus mixed — deletions from the old
  /// store, additions / context from the new store. Widget / marker rows resolve to
  /// `nil` and are dropped. No trailing newline is appended (rows are joined).
  static func string(
    forRows rows: [Int],
    tree: ChunkTree,
    mode: DiffViewMode = .unified,
    store: (DiffSide) -> UTF16LineStore
  ) -> String {
    rows.compactMap { row -> String? in
      guard let resolved = tree.diffLine(atRow: row, mode: mode) else { return nil }  // widget/marker rows → nil
      let source = store(resolved.side)
      let storeIndex = resolved.lineNumber - 1  // git line number (1-based) → store index (0-based)
      guard storeIndex >= 0, storeIndex < source.lineCount else { return nil }
      return source.string(ofLine: storeIndex)
    }
    .joined(separator: "\n")
  }

  /// Write `text` to the general pasteboard (matches `RepositoriesFeature.swift:2238`).
  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  // MARK: - Grapheme snapping

  /// Snap an offset DOWN to the start of its composed-character sequence (so a copy
  /// never begins with an orphan combining mark), clamped into `[0, length]`.
  private static func snappedLower(_ offset: Int, in text: NSString) -> Int {
    let clamped = min(max(offset, 0), text.length)
    guard clamped > 0, clamped < text.length else { return clamped }
    return text.rangeOfComposedCharacterSequence(at: clamped).location
  }

  /// Snap an offset UP to the end of its composed-character sequence (so a copy never
  /// ends with a lone surrogate half), clamped into `[0, length]`.
  private static func snappedUpper(_ offset: Int, in text: NSString) -> Int {
    let clamped = min(max(offset, 0), text.length)
    guard clamped > 0, clamped < text.length else { return clamped }
    let cluster = text.rangeOfComposedCharacterSequence(at: clamped)
    return cluster.location == clamped ? clamped : NSMaxRange(cluster)
  }
}
