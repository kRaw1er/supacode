import Foundation
import Testing

@testable import supacode

/// Unit coverage for the pure intra-line `WordDiff`. UTF-16 char offsets, caps,
/// and mode-agnostic pairing (SpecFlow 6.3 / 7.5).
struct WordDiffTests {
  @Test func singleTokenSubstitution() {
    let result = WordDiff.diff(old: "foo(1)", new: "foo(2)")
    // Only the `1` / `2` differ.
    #expect(result.oldSpans == [WordDiff.Span(range: 4..<5)])
    #expect(result.newSpans == [WordDiff.Span(range: 4..<5)])
  }

  @Test func multiTokenEdit() {
    let result = WordDiff.diff(old: "let x = a + b", new: "let x = a - c")
    // `+`→`-` (offset 10) and `b`→`c` (offset 12); untouched identifiers excluded.
    #expect(result.oldSpans == [WordDiff.Span(range: 10..<11), WordDiff.Span(range: 12..<13)])
    #expect(result.newSpans == [WordDiff.Span(range: 10..<11), WordDiff.Span(range: 12..<13)])
  }

  @Test func pureInsertion() {
    let result = WordDiff.diff(old: "f(a)", new: "f(a, b)")
    #expect(result.oldSpans.isEmpty)
    // The inserted `, b` is one contiguous merged span.
    #expect(result.newSpans == [WordDiff.Span(range: 3..<6)])
  }

  @Test func identicalLinesAreEmpty() {
    let result = WordDiff.diff(old: "let x = 1", new: "let x = 1")
    #expect(result == .empty)
  }

  @Test func longLineCapReturnsEmpty() {
    let old = String(repeating: "a", count: WordDiff.maxLineLength + 1)
    let new = String(repeating: "b", count: WordDiff.maxLineLength + 1)
    #expect(WordDiff.diff(old: old, new: new) == .empty)
  }

  @Test func tokenCountCapReturnsEmpty() {
    // Each `.` is its own punctuation token; > maxTokens ⇒ skipped.
    let old = String(repeating: ".", count: WordDiff.maxTokens + 10)
    let new = String(repeating: ".", count: WordDiff.maxTokens + 5)
    #expect(WordDiff.diff(old: old, new: new) == .empty)
  }

  @Test func unifiedAndSplitUseIdenticalSpans() {
    // The diff takes one (old, new) pair, so unified and split callers consume the
    // exact same result — split routes oldSpans→left / newSpans→right, unified
    // routes oldSpans→`-` / newSpans→`+`. Same spans either way.
    let pair = ("value = compute(a)", "value = compute(b)")
    let asUnified = WordDiff.diff(old: pair.0, new: pair.1)
    let asSplit = WordDiff.diff(old: pair.0, new: pair.1)
    #expect(asUnified == asSplit)
    #expect(!asUnified.oldSpans.isEmpty)
    #expect(!asUnified.newSpans.isEmpty)
  }

  @Test func unicodeScalarBoundariesDoNotCrash() {
    let result = WordDiff.diff(old: "café", new: "cafe")
    // Each side is a single identifier token spanning the four scalars.
    #expect(result.oldSpans == [WordDiff.Span(range: 0..<4)])
    #expect(result.newSpans == [WordDiff.Span(range: 0..<4)])
  }

  // MARK: - Phase 5: cross-mode meta-invariant

  /// C 5.1 / §5.10 — the same `(old, new)` pair yields identical spans whether the
  /// caller is unified or split (the diff takes one pair, mode-agnostic), over a
  /// spread of Unicode fixtures.
  @Test func unifiedEqualsSplitOnUnicode() {
    let pairs: [(String, String)] = [
      (UnicodeFixtures.emojiThumb, UnicodeFixtures.emojiDown),
      (UnicodeFixtures.cjkExpr, "x = \u{65E5}\u{672C} + 1"),
      ("let \(UnicodeFixtures.krPre) = 1", "let \(UnicodeFixtures.krPre) = 2"),
      ("café", "cafe"),
      ("f(a)", "f(a, b)"),
    ]
    for (old, new) in pairs {
      let asUnified = WordDiff.diff(old: old, new: new)
      let asSplit = WordDiff.diff(old: old, new: new)
      #expect(asUnified == asSplit)
    }
  }

  // MARK: - Phase 5: UTF regressions G2 / G3 / G4

  /// UTF regression G2 (extends C 5.2) — a surrogate pair, ZWJ sequence, and
  /// skin-tone modifier are each ONE token; no span bound bisects a grapheme.
  @Test func emojiWordDiffNotSplit() {
    // Surrogate pair kept whole — both spans are the full [1,3), never [1,2).
    let thumb = WordDiff.diff(old: UnicodeFixtures.emojiThumb, new: UnicodeFixtures.emojiDown)
    #expect(thumb.oldSpans == [WordDiff.Span(range: 1..<3)])
    #expect(thumb.newSpans == [WordDiff.Span(range: 1..<3)])
    // A 👨‍👩‍👧‍👦 change is ONE 11-unit span (never fragmented per-scalar).
    let family = WordDiff.diff(old: "a\(UnicodeFixtures.grin)b", new: "a\(UnicodeFixtures.family)b")
    #expect(family.newSpans == [WordDiff.Span(range: 1..<12)])
    #expect(family.newSpans.first?.range.count == 11)
    // The 👍🏽 skin-tone modifier is never a standalone token: 👍 → 👍🏽 spans the
    // whole [1,5) cluster on the new side (old scalar tokenizer produced a bare [3,5)).
    let skin = WordDiff.diff(old: UnicodeFixtures.emojiThumb, new: "a\(UnicodeFixtures.thumbSkin)b")
    #expect(skin.newSpans == [WordDiff.Span(range: 1..<5)])
    #expect(skin.oldSpans == [WordDiff.Span(range: 1..<3)])
  }

  /// UTF regression G4 — a DECOMPOSED é (`e` + U+0301, at [4,6)) is snapped OUTWARD
  /// on BOTH ends via `rangeOfComposedCharacterSequences(for:)`: a change to the
  /// isolated `e` → `é` covers the WHOLE [4,6) cluster, never a bare [5,6) that
  /// splits the base letter from its combining mark (which the old scalar tokenizer
  /// produced, because U+0301 was classified as its own punctuation token).
  @Test func combiningMarkSpanSnappedBothEnds() {
    let result = WordDiff.diff(old: "caf e", new: "caf \(UnicodeFixtures.eAcuteNFD)")
    #expect(result.newSpans == [WordDiff.Span(range: 4..<6)])
    #expect(result.oldSpans == [WordDiff.Span(range: 4..<5)])
    // No span bound lands strictly inside the é composed sequence (never at 5).
    for span in result.newSpans {
      #expect(span.range.lowerBound != 5)
      #expect(span.range.upperBound != 5)
    }
  }

  /// UTF regression G3 (extends C 5.4) — the per-line cap unit is `NSString.length`
  /// (UTF-16), NOT graphemes. A line of 501 astral letters is 1002 UTF-16 units but
  /// only 501 graphemes: the LENGTH cap (checked before tokenization) fires on the
  /// UTF-16 length even though the grapheme count is far under 1000. The old code
  /// used `String.count` (graphemes = 501, under the old 2000 cap), so it would NOT
  /// have capped here. Astral letters group into ONE word token, so this isolates the
  /// length cap from the separate `maxTokens` guard.
  @Test func capUnitIsUTF16NotGraphemes() {
    let overByUnits = String(repeating: UnicodeFixtures.mathX, count: 501)  // 1002 u16, 501 graphemes
    #expect((overByUnits as NSString).length == 1002)
    #expect(overByUnits.count == 501)
    #expect(WordDiff.diff(old: overByUnits, new: overByUnits + UnicodeFixtures.mathAlpha) == .empty)
    // A short pair under every cap still runs (the length gate is not over-eager).
    #expect(WordDiff.diff(old: "hello", new: "world") != .empty)
  }

  /// C 5.3 (D §2/§3) — grapheme-safe, non-empty CJK / conjoining-jamo / conjunct
  /// segmentation: a change is non-empty and no span bound lands strictly inside a
  /// `krDecomp` (conjoining jamo) or `ksha` (Devanagari conjunct) cluster.
  @Test func cjkAndDecomposedNonEmptySegmentation() {
    let cjk = WordDiff.diff(old: UnicodeFixtures.cjk, new: "\u{65E5}\u{6587}")  // 中文 → 日文
    #expect(!cjk.oldSpans.isEmpty)
    #expect(!cjk.newSpans.isEmpty)
    // Conjoining jamo krDecomp (3 u16, 1 grapheme) is atomic — no bound at 2 or 3.
    let jamo = WordDiff.diff(old: "x", new: "x\(UnicodeFixtures.krDecomp)")
    #expect(!jamo.newSpans.isEmpty)
    for span in jamo.newSpans {
      #expect(![2, 3].contains(span.range.lowerBound))
      #expect(![2, 3].contains(span.range.upperBound))
    }
    // Devanagari conjunct ksha (3 u16, 1 grapheme) likewise atomic.
    let ksha = WordDiff.diff(old: "y", new: "y\(UnicodeFixtures.ksha)")
    #expect(!ksha.newSpans.isEmpty)
    for span in ksha.newSpans {
      #expect(![2, 3].contains(span.range.lowerBound))
      #expect(![2, 3].contains(span.range.upperBound))
    }
  }

  /// D §6 — nbsp (U+00A0) IS White_Space, so two adjacent nbsp coalesce into ONE
  /// whitespace gap token (`" " → nbsp+nbsp` is one span over both). The zero-width /
  /// format invisibles are NOT White_Space; each is one UTF-16 unit and is handled
  /// grapheme-safely without crashing or splitting a cluster.
  @Test func nbspIsWhitespaceZwspIsOwnToken() {
    let nbsp = WordDiff.diff(old: "a b", new: "a\(UnicodeFixtures.nbsp)\(UnicodeFixtures.nbsp)b")
    #expect(nbsp.newSpans == [WordDiff.Span(range: 1..<3)])
    for invisible in [
      UnicodeFixtures.zwsp, UnicodeFixtures.zwnj, UnicodeFixtures.zwj, UnicodeFixtures.bom,
      UnicodeFixtures.softHyphen,
    ] {
      #expect((invisible as NSString).length == 1)
      let result = WordDiff.diff(old: "x\(invisible)", new: "y\(invisible)")
      #expect(!result.newSpans.isEmpty)
      for span in result.oldSpans + result.newSpans {
        #expect(span.range.lowerBound >= 0)
        #expect(span.range.upperBound <= 2)
      }
    }
  }

  /// C 5.5 — the separator gap `" + "` sub-tokenizes into `[space, "+", space]`, so
  /// changing the `+` AND the trailing `b` keeps the unchanged middle space as a
  /// boundary: two edits stay TWO spans (the gap is not lumped into one token that
  /// would merge them). Changing only `b` while `+` is unchanged is ONE span.
  @Test func gapSubTokenizePreservesTwoSpans() {
    let two = WordDiff.diff(old: "let x = a + b", new: "let x = a - c")
    #expect(two.oldSpans == [WordDiff.Span(range: 10..<11), WordDiff.Span(range: 12..<13)])
    #expect(two.newSpans == [WordDiff.Span(range: 10..<11), WordDiff.Span(range: 12..<13)])
    let one = WordDiff.diff(old: "a + b", new: "a + c")
    #expect(one.newSpans == [WordDiff.Span(range: 4..<5)])
    #expect(one.oldSpans == [WordDiff.Span(range: 4..<5)])
  }
}
