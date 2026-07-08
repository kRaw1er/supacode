import Foundation
import Testing

@testable import supacode

/// Phase 3 — the UTF-16-native line store (the load-bearing perf discipline). All
/// PURE (Foundation + `NSString`, no CoreText / AppKit). Rows 3.1–3.4 + the D-matrix
/// regressions (`crOnly` G1, start-only snap G4, the fixture-facts probe).
@MainActor
struct UTF16LineStoreTests {
  // MARK: - 3.1 range / line across newline forms

  @Test func utf16StoreRangeAcrossNewlineForms() {
    // `\n` split: two lines, EOL excluded from the reported range.
    let lineFeed = UTF16LineStore(bridging: "a\nb")
    #expect(lineFeed.lineCount == 2)
    #expect(lineFeed.line(0) as String == "a")
    #expect(lineFeed.line(1) as String == "b")
    #expect(lineFeed.range(ofLine: 0) == NSRange(location: 0, length: 1))

    // `\r\n` split: BOTH the CR and LF are stripped from the content range.
    let crlf = UTF16LineStore(bridging: "a\r\nb")
    #expect(crlf.lineCount == 2)
    #expect(crlf.line(0) as String == "a")
    #expect(crlf.line(1) as String == "b")
    #expect(crlf.range(ofLine: 0) == NSRange(location: 0, length: 1))

    // Trailing newline ⇒ NO phantom final empty line (sentinel guard).
    let trailing = UTF16LineStore(bridging: "a\nb\n")
    #expect(trailing.lineCount == 2)
    #expect(trailing.line(1) as String == "b")

    // Empty blob ⇒ zero lines; a single unterminated line ⇒ exactly one.
    #expect(UTF16LineStore(bridging: "").lineCount == 0)
    let single = UTF16LineStore(bridging: "a")
    #expect(single.lineCount == 1)
    #expect(single.line(0) as String == "a")

    // Two empty lines from "\n\n".
    let blanks = UTF16LineStore(bridging: "\n\n")
    #expect(blanks.lineCount == 2)
    #expect(blanks.line(0) as String == "")
    #expect(blanks.line(1) as String == "")
  }

  // MARK: - 3.2 locate round-trips with range (O(log n) binary search)

  @Test func utf16StoreLocateRoundTrips() {
    let store = UTF16LineStore(bridging: "a\nbb\nccc")
    #expect(store.lineCount == 3)
    for line in 0..<store.lineCount {
      let range = store.range(ofLine: line)
      #expect(store.utf16Offset(ofLine: line) == range.location)
      // Every content offset of the line maps back to (line, column).
      for column in 0..<max(range.length, 1) {
        let located = store.locate(offset: range.location + column)
        #expect(located.line == line)
        #expect(located.column == column)
        #expect(store.line(atUTF16Offset: range.location + column) == line)
      }
    }
  }

  // MARK: - 3.3 built from [UInt16], backed by NSString (NOT a bridged Swift String)

  @Test func utf16StoreBuiltFromUnitsNotBridgedString() {
    // Built straight from UTF-16 code units — the whole point (benchmark: a
    // bridged native Swift `String`'s `character(at:)` is NOT guaranteed O(1);
    // `NSString(characters:length:)` is). The backing must be an `NSString`.
    let units = DiffFixture.blob("hello\nworld")
    let store = UTF16LineStore(utf16: units)
    #expect(store.nsString is NSString)
    #expect(store.nsString.length == units.count)
    #expect(store.nsString.character(at: 0) == UInt16(UnicodeScalar("h").value))  // O(1) unit access
    #expect(store.lineCount == 2)
    #expect(store.line(1) as String == "world")
  }

  // MARK: - 3.4 snap keeps a surrogate pair whole

  @Test func snapToGraphemeKeepsSurrogatePair() {
    let store = UTF16LineStore(bridging: "a\u{1F600}b")  // "a😀b", 😀 == units 1..<3
    #expect(store.snapToGrapheme(1) == 1)  // already a cluster start
    #expect(store.snapToGrapheme(2) == 1)  // trailing surrogate → back to the pair start
    #expect(store.snapToGrapheme(3) == 3)  // "b"
    // The reported line range never lands inside the cluster.
    #expect(store.range(ofLine: 0) == NSRange(location: 0, length: 4))
  }

  // MARK: - snap is START-only (G4) — the upperBound case is owned by Phase 5

  @Test func snapToGraphemeStartOnly() {
    // Every interior offset of a multi-unit cluster snaps DOWN to the cluster start.
    let nfd = UTF16LineStore(bridging: UnicodeFixtures.eAcuteNFD)  // e + U+0301
    #expect(nfd.snapToGrapheme(1) == 0)

    let ksha = UTF16LineStore(bridging: UnicodeFixtures.ksha)  // 3 units, 1 grapheme
    #expect(ksha.snapToGrapheme(1) == 0)
    #expect(ksha.snapToGrapheme(2) == 0)

    let stacked = UTF16LineStore(bridging: UnicodeFixtures.stackedZ)  // z + 2 combining marks
    #expect(stacked.snapToGrapheme(1) == 0)
    #expect(stacked.snapToGrapheme(2) == 0)

    let thai = UTF16LineStore(bridging: UnicodeFixtures.thai)
    #expect(thai.snapToGrapheme(1) == 0)
  }

  // MARK: - lineStarts across ALL EOL forms incl. crOnly → one line (G1)

  @Test func lineStartsAcrossAllEOLForms() {
    // `\n`-only splitting is a conscious contract. A classic-Mac CR-only blob is
    // therefore ONE line with embedded CRs (`lineStarts == [0, 5]`).
    let crOnly = UTF16LineStore(bridging: "a\rb\rc")
    #expect(crOnly.lineCount == 1)  // G1: CR is not a break
    #expect(crOnly.utf16Offset(ofLine: 0) == 0)
    #expect(crOnly.nsString.length == 5)  // sentinel == 5 ⇒ lineStarts == [0, 5]
    #expect(crOnly.line(0) as String == "a\rb\rc")  // CRs retained (no trailing to strip)

    let lineFeed = UTF16LineStore(bridging: "a\nb")
    #expect(lineFeed.utf16Offset(ofLine: 0) == 0)
    #expect(lineFeed.utf16Offset(ofLine: 1) == 2)

    let crlf = UTF16LineStore(bridging: "a\r\nb")
    #expect(crlf.utf16Offset(ofLine: 1) == 3)

    // Astral line: "𝕏\nx" — the surrogate pair counts as 2 units.
    let astral = UTF16LineStore(bridging: "\u{1D54F}\nx")
    #expect(astral.lineCount == 2)
    #expect(astral.utf16Offset(ofLine: 0) == 0)
    #expect(astral.utf16Offset(ofLine: 1) == 3)  // pair(0..<2) + \n@2 ⇒ line 1 starts @3
    #expect(astral.locate(offset: 2).line == 0)
    #expect(astral.locate(offset: 3).line == 1)
  }

  // MARK: - a leading / mid-line BOM (U+FEFF) does not desync the offset table (STORE §6)

  @Test func midLineBOMDoesNotDesyncOffsetTable() {
    // A leading BOM is common in Windows-authored source. It is CONTENT, not stripped:
    // "\u{FEFF}ab\n" ⇒ BOM@0, a@1, b@2, \n@3, sentinel@4 — lineStarts == [0, 4].
    let bomLine = UTF16LineStore(bridging: "\u{FEFF}ab\n")
    #expect(bomLine.lineCount == 1)  // trailing "\n" ⇒ no phantom empty line
    #expect(bomLine.nsString.length == 4)  // BOM counted as 1 unit (sentinel == 4)
    #expect(bomLine.utf16Offset(ofLine: 0) == 0)
    // lineStarts == [line-0 start, sentinel] == [0, 4].
    let lineStarts: [Int] = [bomLine.utf16Offset(ofLine: 0), bomLine.nsString.length]
    #expect(lineStarts == [0, 4])
    // Reported range EXCLUDES the trailing "\n" but KEEPS the BOM: [0, 3).
    #expect(bomLine.range(ofLine: 0) == NSRange(location: 0, length: 3))
    #expect(bomLine.nsString.character(at: 0) == 0xFEFF)  // BOM retained at offset 0, not consumed
    #expect(bomLine.string(ofLine: 0) == "\u{FEFF}ab")

    // A MID-line BOM ("a\u{FEFF}b") stays counted as exactly one unit, so `locate`
    // is monotone with no off-by-one: every offset maps to line 0, column == offset.
    let midBOM = UTF16LineStore(bridging: "a\u{FEFF}b")
    #expect(midBOM.lineCount == 1)
    #expect(midBOM.nsString.length == 3)
    #expect(midBOM.nsString.character(at: 1) == 0xFEFF)
    var previousColumn = -1
    for offset in 0..<3 {  // content offsets; offset == length is the exclusive sentinel
      let located = midBOM.locate(offset: offset)
      #expect(located.line == 0)
      #expect(located.column == offset)  // BOM is a plain 1-unit column, no shift
      #expect(located.column > previousColumn)  // monotone
      previousColumn = located.column
    }
  }

  // MARK: - odd regional-indicator run pairs 2-by-2, trailing RI alone (§1 caveat)

  @Test func regionalIndicatorOddRunPairs2by2() {
    // 🇯🇵🇺 == U+1F1EF U+1F1F5 U+1F1FA — three regional indicators (6 UTF-16 units).
    // Segmentation pairs RIs 2-by-2: [🇯🇵] == units 0..<4 (one flag), [🇺] == units
    // 4..<6 (the odd trailing RI, its own grapheme). snapToGrapheme (start-only)
    // must snap every interior offset of the first flag back to 0 and land the
    // second cluster's start exactly at 4 — never bisecting a flag pair at 2.
    let store = UTF16LineStore(bridging: "\u{1F1EF}\u{1F1F5}\u{1F1FA}")
    #expect(store.nsString.length == 6)
    // The first flag [🇯🇵] is ONE cluster 0..<4: every interior offset snaps to 0.
    #expect(store.snapToGrapheme(1) == 0)
    #expect(store.snapToGrapheme(2) == 0)  // NOT a boundary — the two RIs pair into one flag
    #expect(store.snapToGrapheme(3) == 0)
    // The odd trailing [🇺] is its own cluster starting at 4 (pairs did not merge 3).
    #expect(store.snapToGrapheme(4) == 4)
    #expect(store.snapToGrapheme(5) == 4)
    // NSString composed-sequence boundaries agree: [0,4) then [4,6), never a 3-RI blob.
    #expect(NSEqualRanges(store.nsString.rangeOfComposedCharacterSequence(at: 0), NSRange(location: 0, length: 4)))
    #expect(NSEqualRanges(store.nsString.rangeOfComposedCharacterSequence(at: 4), NSRange(location: 4, length: 2)))
  }

  // MARK: - The fixture-facts probe (OS/toolchain composed-sequence guard)

  @Test func unicodeFixtureFactsProbe() {
    for fixture in UnicodeFixtures.all {
      let facts = UnicodeFixtures.facts(fixture.value)
      #expect(facts.u16 == fixture.u16, "u16 mismatch for \(fixture.name)")
      #expect(facts.graphemes == fixture.graphemes, "grapheme mismatch for \(fixture.name)")
      // NSString composed-sequence boundaries agree with Swift Character boundaries
      // on the target OS — if this ever diverges, pin the fixture (D §equivalence).
      #expect(facts.composed == facts.graphemes, "composed != graphemes for \(fixture.name)")
      #expect((fixture.value as NSString).length == fixture.u16)
    }
  }
}
