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
