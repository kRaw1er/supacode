import Foundation

/// One file version (old or new blob) as ONE UTF-16 buffer + a line-start offset
/// table. `NSString` (NOT a bridged Swift `String`) so `character(at:)` is O(1)
/// and `substring(with:)` is O(range) — the load-bearing rule (brainstorm
/// §"UTF-16 offset discipline": Swift `String` is UTF-8-backed → O(n) random
/// UTF-16 access, whereas neon `NamedRange`, `NSAttributedString`, and
/// `CTLineGetOffsetForStringIndex` are all UTF-16-native). The two only O(fileLen)
/// costs live in `init`: decode the blob, build `lineStarts`. Everything else is
/// O(1) / O(log n).
///
/// Search / copy (Phase 11) read `nsString`, `line(atUTF16Offset:)`,
/// `utf16Offset(ofLine:)`, `string(ofLine:)` off this same store.
@MainActor
final class UTF16LineStore {
  /// Real UTF-16 backing — never a bridged Swift `String`. Exposed so Phase 11
  /// search can run `NSString.range(of:)` whole-needle against the blob.
  let nsString: NSString

  /// `lineStarts[i]` = UTF-16 offset of line i's first unit; the last entry
  /// == length (sentinel) so every line has an end with no branch. ONE linear
  /// pass in `init` (brainstorm: the second and last O(fileLen) cost).
  private let lineStarts: [Int]

  /// Number of lines. A trailing `"\n"` does NOT synthesize a phantom empty line
  /// (the sentinel guard in `buildLineStarts`), so this matches the data layer's
  /// `git_patch_line_stats` (Phase 9).
  var lineCount: Int { lineStarts.count - 1 }

  /// Phase 9 streams `[UInt16]` off-main (Sendable). Until then a bridge in
  /// `init(bridging:)` is a one-time O(fileLen) cost, NOT on the read path — the
  /// read path is `NSString.character(at:)` / `substring(with:)`.
  init(utf16 units: [UInt16]) {
    let text = NSString(characters: units, length: units.count)
    self.nsString = text
    self.lineStarts = Self.buildLineStarts(text)
  }

  convenience init(bridging swiftString: String) {
    self.init(utf16: Array(swiftString.utf16))
  }

  /// O(1): UTF-16 range of line `i` EXCLUDING its trailing `"\n"` / `"\r\n"`. The
  /// real bytes stay in `nsString` so copy / offsets are correct (Phase 11) — we
  /// only narrow the reported range.
  func range(ofLine index: Int) -> NSRange {
    let start = lineStarts[index]
    var end = lineStarts[index + 1]
    if end > start, nsString.character(at: end - 1) == 0x0A { end -= 1 }  // \n
    if end > start, nsString.character(at: end - 1) == 0x0D { end -= 1 }  // \r
    return NSRange(location: start, length: end - start)
  }

  /// O(range) content slice as `NSString` — feeds the typesetter's attributed
  /// string WITHOUT ever materializing a Swift `String`.
  func line(_ index: Int) -> NSString { nsString.substring(with: range(ofLine: index)) as NSString }

  /// O(range) content slice as a Swift `String` (S15 — the copy read path, where
  /// the endpoint IS a user-facing `String`). Never used on the render hot path.
  func string(ofLine index: Int) -> String { nsString.substring(with: range(ofLine: index)) }

  /// O(1): the UTF-16 offset of line `index`'s first unit.
  func utf16Offset(ofLine index: Int) -> Int { lineStarts[index] }

  /// O(log lineCount): file offset → line index (== `locate(offset:).line`), the
  /// Phase 11 search "match offset → which line" query.
  func line(atUTF16Offset offset: Int) -> Int { locate(offset: offset).line }

  /// O(log lineCount): file offset → (line, line-relative column). Binary search
  /// the offset table (brainstorm: "span → line number is O(log #lines)").
  func locate(offset: Int) -> (line: Int, column: Int) {
    var low = 0
    var high = lineCount
    while low < high {  // partition_point over lineStarts: largest index with lineStarts[index] <= offset
      let mid = (low + high + 1) / 2
      if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
    }
    return (low, offset - lineStarts[low])
  }

  /// Snap a UTF-16 offset to the nearest grapheme boundary's **start** so a
  /// surrogate pair / emoji is never split (brainstorm §UTF-16: snap token
  /// boundaries to grapheme edges). **Start-only** (G4): correct for a caret and
  /// for a span `lowerBound`; a span `upperBound` must snap OUTWARD instead — that
  /// case is owned by Phase 5 (`rangeOfComposedCharacterSequences(for:)`).
  func snapToGrapheme(_ offset: Int) -> Int {
    guard offset > 0, offset < nsString.length else { return offset }
    let range = nsString.rangeOfComposedCharacterSequence(at: offset)
    return range.location == offset ? offset : range.location  // move to the cluster start
  }

  /// ONE unichar-level pass, no Swift `String`. Breaks on `"\n"` (0x0A) only — a
  /// classic-Mac CR-only blob (`"a\rb\rc"`) is therefore ONE line with embedded
  /// CRs (`lineStarts == [0, 5]`). This is a conscious, tested contract (⚠️ Gap
  /// G1): content fed line-by-line has already had `\r` / `\n` stripped by the
  /// data layer, and a trailing `"\n"` produces no phantom empty line thanks to
  /// the sentinel guard.
  private static func buildLineStarts(_ string: NSString) -> [Int] {
    var starts = [0]
    let length = string.length
    var index = 0
    while index < length {
      if string.character(at: index) == 0x0A { starts.append(index + 1) }
      index += 1
    }
    if starts.last != length { starts.append(length) }  // sentinel (trailing "\n" ⇒ no phantom line)
    return starts
  }
}
