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

  /// `WordDiff.diff` returns two per-SIDE span lists: `oldSpans` index the OLD/left/`-`
  /// string, `newSpans` index the NEW/right/`+` string. The routing layer is a 1:1
  /// pass-through of that split — `LineRowView.projectSplitChange` sets
  /// `oldWordSpans = result.oldSpans` (left pane) and `newWordSpans = result.newSpans`
  /// (right pane), and unified routes `oldSpans` to the `-` row and `newSpans` to the
  /// `+` row (private `project*`, mode-agnostic). So the meaningful, non-tautological
  /// assertions are about the two SIDES — which an implementation could swap, collapse
  /// onto one side, or push out of the string it indexes — NOT the two MODES, which
  /// share one mode-agnostic `Result`.
  @Test func asymmetricEditKeepsOldAndNewSidesDistinct() {
    // An ASYMMETRIC change so the two sides carry genuinely DIFFERENT spans against
    // DIFFERENT-length strings: 👍 (2 u16) → 👍🏽 (4 u16). Old/left is [1,3) in the
    // 4-unit "a👍b"; new/right is [1,5) in the 6-unit "a👍🏽b".
    let old = UnicodeFixtures.emojiThumb  // "a👍b"  (u16 len 4)
    let new = "a\(UnicodeFixtures.thumbSkin)b"  // "a👍🏽b" (u16 len 6)
    let result = WordDiff.diff(old: old, new: new)

    // Concrete per-side ranges.
    #expect(result.oldSpans == [WordDiff.Span(range: 1..<3)])
    #expect(result.newSpans == [WordDiff.Span(range: 1..<5)])
    // The two sides are genuinely distinct — an impl that mirrored one side onto both,
    // or collapsed them, is caught (the ranges are not equal).
    #expect(result.oldSpans != result.newSpans)
    // Each side is bounded by the string it indexes. Swapping the sides would put the
    // [1,5) span against the 4-unit OLD string (upperBound 5 > 4) — out of bounds.
    #expect(result.oldSpans.allSatisfy { $0.range.upperBound <= (old as NSString).length })
    #expect(result.newSpans.allSatisfy { $0.range.upperBound <= (new as NSString).length })
  }

  @Test func unicodeScalarBoundariesDoNotCrash() {
    let result = WordDiff.diff(old: "café", new: "cafe")
    // Each side is a single identifier token spanning the four scalars.
    #expect(result.oldSpans == [WordDiff.Span(range: 0..<4)])
    #expect(result.newSpans == [WordDiff.Span(range: 0..<4)])
  }

  // MARK: - Phase 5: per-side routing correctness

  /// C 5.1 / §5.10 — each side's spans index its OWN string (old→left/`-`,
  /// new→right/`+`) across a spread of Unicode fixtures. An impl that swapped or
  /// mirrored the sides would push a span past the length of the string it indexes on
  /// an asymmetric pair — this asserts the per-side bound, not a cross-mode equality.
  @Test func oldNewSidesIndexTheirOwnStringAcrossUnicode() {
    let pairs: [(String, String)] = [
      (UnicodeFixtures.emojiThumb, UnicodeFixtures.emojiDown),
      (UnicodeFixtures.cjkExpr, "x = \u{65E5}\u{672C} + 1"),
      ("let \(UnicodeFixtures.krPre) = 1", "let \(UnicodeFixtures.krPre) = 2"),
      ("café", "cafe"),
      ("f(a)", "f(a, b)"),
    ]
    for (old, new) in pairs {
      let result = WordDiff.diff(old: old, new: new)
      let oldLen = (old as NSString).length
      let newLen = (new as NSString).length
      // Old-side spans stay within the OLD string; new-side within the NEW string.
      for span in result.oldSpans {
        #expect(
          span.range.lowerBound >= 0 && span.range.upperBound <= oldLen,
          "old-side span \(span.range) escapes old (len \(oldLen)) — sides swapped?")
      }
      for span in result.newSpans {
        #expect(
          span.range.lowerBound >= 0 && span.range.upperBound <= newLen,
          "new-side span \(span.range) escapes new (len \(newLen)) — sides swapped?")
      }
    }
    // A pure INSERTION routes an EMPTY old/left side and a non-empty new/right side.
    let insertion = WordDiff.diff(old: "f(a)", new: "f(a, b)")
    #expect(insertion.oldSpans.isEmpty)
    #expect(!insertion.newSpans.isEmpty)
    // A pure DELETION is the mirror image: non-empty old/left, empty new/right. An
    // impl that swapped the sides would fail exactly one of these two directions.
    let deletion = WordDiff.diff(old: "f(a, b)", new: "f(a)")
    #expect(!deletion.oldSpans.isEmpty)
    #expect(deletion.newSpans.isEmpty)
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
    // nbsp (U+00A0) IS White_Space → two adjacent nbsp coalesce into ONE whitespace
    // gap token spanning both units: "a b" → "a\u{A0}\u{A0}b" ⇒ the changed span is
    // the full [1,3), not two 1-unit spans.
    let nbsp = WordDiff.diff(old: "a b", new: "a\(UnicodeFixtures.nbsp)\(UnicodeFixtures.nbsp)b")
    #expect(nbsp.newSpans == [WordDiff.Span(range: 1..<3)])

    // ZWSP (U+200B) is a true zero-width SPACE → a word SEPARATOR. Replacing the
    // "foo bar" space (offset 3) with ZWSP keeps "foo"/"bar" as separate tokens, so
    // the changed span is EXACTLY the 1-unit separator [3,4) on BOTH sides — its own
    // gap token, not swallowed into a neighbour (the weak `<=2` bound could not see
    // this granularity: a lone ZWSP is a 1-unit token).
    let zwsp = WordDiff.diff(old: "foo bar", new: "foo\(UnicodeFixtures.zwsp)bar")
    #expect(zwsp.oldSpans == [WordDiff.Span(range: 3..<4)])
    #expect(zwsp.newSpans == [WordDiff.Span(range: 3..<4)])

    // The zero-width JOINERS / format chars (ZWNJ, ZWJ, BOM/word-joiner, soft hyphen)
    // are word-INTERNAL: the Unicode word segmenter fuses "foo<inv>bar" into one unit
    // (correct segmentation, verified behaviour), so the edit is detected coarsely.
    // The guard that matters against "symbols break": every recorded span stays
    // grapheme-aligned and in bounds — the tokenizer never crashes or bisects a
    // composed sequence around an invisible.
    for invisible in [UnicodeFixtures.zwnj, UnicodeFixtures.zwj, UnicodeFixtures.bom, UnicodeFixtures.softHyphen] {
      #expect((invisible as NSString).length == 1)  // a lone format char is one UTF-16 unit
      let new = "foo\(invisible)bar" as NSString
      let result = WordDiff.diff(old: "foo bar", new: new as String)
      #expect(result != .empty)  // the invisible edit is detected
      for span in result.oldSpans + result.newSpans {
        #expect(span.range.lowerBound >= 0)
        #expect(span.range.upperBound <= new.length)
      }
      for span in result.newSpans {
        // No span bound bisects a composed sequence (grapheme-safe around the invisible).
        for bound in [span.range.lowerBound, span.range.upperBound] where bound > 0 && bound < new.length {
          #expect(new.rangeOfComposedCharacterSequence(at: bound).location == bound)
        }
      }
    }
  }

  /// §1 regional-indicator caveat (word side) — a diff over an ODD RI run must place
  /// spans on RI-PAIR boundaries (grapheme edges), never inside a flag pair. Removing
  /// the odd trailing 🇺 from "a🇯🇵🇺b" changes only that lone flag: its cluster is
  /// units 5..<7, and the outward grapheme snap guarantees no span bound bisects the
  /// [🇯🇵] pair (offsets 2,3,4) or the [🇺] pair (offset 6).
  @Test func regionalIndicatorWordDiffPairs2by2() {
    // a=0, 🇯🇵=1..<5 (one flag, 2 RIs), 🇺=5..<7 (odd trailing RI), b=7.
    let result = WordDiff.diff(old: "a\u{1F1EF}\u{1F1F5}\u{1F1FA}b", new: "a\u{1F1EF}\u{1F1F5}b")
    #expect(result != .empty)
    let midPairOffsets: Set<Int> = [2, 3, 4, 6]  // interiors of the two flag clusters
    for span in result.oldSpans + result.newSpans {
      #expect(
        !midPairOffsets.contains(span.range.lowerBound),
        "span lowerBound \(span.range.lowerBound) bisects a regional-indicator pair")
      #expect(
        !midPairOffsets.contains(span.range.upperBound),
        "span upperBound \(span.range.upperBound) bisects a regional-indicator pair")
    }
    // The removed lone flag 🇺 is the change on the old side: its cluster [5,7).
    #expect(result.oldSpans.contains { $0.range.lowerBound == 5 || $0.range.upperBound == 7 })
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
