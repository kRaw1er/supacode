import Foundation

/// Verified UTF/Unicode torture fixtures (test-strategy D §"reusable constants").
/// `u16` == `NSString.length`; `graphemes` == `String.count` (== `NSString`
/// composed-sequence count on the target OS). Do NOT "clean up" the `\u{}` escapes
/// into pasted glyphs — the escapes ARE the contract. Consumed by P3/P4/P5/P11.
enum UnicodeFixtures {
  // Emoji — every one is exactly ONE grapheme.
  static let coffee = "\u{2615}"  // u16 1,  g 1
  static let grin = "\u{1F600}"  // u16 2,  g 1
  static let thumbSkin = "\u{1F44D}\u{1F3FD}"  // u16 4,  g 1
  static let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"  // u16 11, g 1
  static let rainbowFlag = "\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}"  // u16 6,  g 1
  static let womanTech = "\u{1F469}\u{200D}\u{1F4BB}"  // u16 5,  g 1
  static let jpFlag = "\u{1F1EF}\u{1F1F5}"  // u16 4,  g 1
  static let keycap1 = "\u{0031}\u{FE0F}\u{20E3}"  // u16 3,  g 1
  // CJK / wide.
  static let cjk = "\u{4E2D}\u{6587}"  // u16 2,  g 2
  static let japanese = "\u{65E5}\u{672C}\u{8A9E}"  // u16 3,  g 3
  static let krPre = "\u{D55C}\u{AD6D}\u{C5B4}"  // u16 3,  g 3
  static let krDecomp = "\u{1100}\u{1161}\u{11A8}"  // u16 3,  g 1  (conjoining jamo)
  static let fullWidthA = "\u{FF21}"  // u16 1,  g 1  (double-width)
  // Combining / normalization.
  static let eAcuteNFC = "\u{00E9}"  // u16 1,  g 1
  static let eAcuteNFD = "\u{0065}\u{0301}"  // u16 2,  g 1
  static let ksha = "\u{0915}\u{094D}\u{0937}"  // u16 3,  g 1
  static let thai = "\u{0E01}\u{0E48}"  // u16 2,  g 1
  static let stackedZ = "\u{007A}\u{0308}\u{0323}"  // u16 3,  g 1
  // Astral non-emoji.
  static let mathX = "\u{1D54F}"  // u16 2,  g 1
  static let mathAlpha = "\u{1D6FC}"  // u16 2,  g 1
  static let dna = "\u{1F9EC}"  // u16 2,  g 1
  // Bidi / RTL.
  static let arabic = "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}"  // u16 5,  g 5
  static let hebrew = "\u{05E9}\u{05DC}\u{05D5}\u{05DD}"  // u16 4,  g 4
  static let rlo = "\u{202E}"
  static let lro = "\u{202D}"
  // Invisible.
  static let zwsp = "\u{200B}"
  static let zwnj = "\u{200C}"
  static let zwj = "\u{200D}"
  static let bom = "\u{FEFF}"
  static let softHyphen = "\u{00AD}"
  static let nbsp = "\u{00A0}"
  // Composite lines.
  static let emojiThumb = "a\u{1F44D}b"
  static let emojiDown = "a\u{1F44A}b"  // u16 4 each
  static let cjkExpr = "x = \u{4E2D}\u{6587} + 1"  // u16 10
  static let bidiAssign = "let \u{05E9}\u{05DC}\u{05D5}\u{05DD} = 1"  // u16 12
  static let tabEmoji = "\t\u{1F600}\tx"  // u16 5

  /// One entry of the master facts table (structs, not tuples, per the lint's
  /// 2-member cap).
  struct Fixture {
    let name: String
    let value: String
    let u16: Int
    let graphemes: Int
  }

  /// The derived (u16, grapheme, composed) facts of a string.
  struct Facts {
    let u16: Int
    let graphemes: Int
    let composed: Int
  }

  /// The master table `unicodeFixtureFactsProbe` walks so an OS/toolchain
  /// composed-sequence change fails loudly.
  static let all: [Fixture] = [
    Fixture(name: "coffee", value: coffee, u16: 1, graphemes: 1),
    Fixture(name: "grin", value: grin, u16: 2, graphemes: 1),
    Fixture(name: "thumbSkin", value: thumbSkin, u16: 4, graphemes: 1),
    Fixture(name: "family", value: family, u16: 11, graphemes: 1),
    Fixture(name: "rainbowFlag", value: rainbowFlag, u16: 6, graphemes: 1),
    Fixture(name: "womanTech", value: womanTech, u16: 5, graphemes: 1),
    Fixture(name: "jpFlag", value: jpFlag, u16: 4, graphemes: 1),
    Fixture(name: "keycap1", value: keycap1, u16: 3, graphemes: 1),
    Fixture(name: "cjk", value: cjk, u16: 2, graphemes: 2),
    Fixture(name: "japanese", value: japanese, u16: 3, graphemes: 3),
    Fixture(name: "krPre", value: krPre, u16: 3, graphemes: 3),
    Fixture(name: "krDecomp", value: krDecomp, u16: 3, graphemes: 1),
    Fixture(name: "fullWidthA", value: fullWidthA, u16: 1, graphemes: 1),
    Fixture(name: "eAcuteNFC", value: eAcuteNFC, u16: 1, graphemes: 1),
    Fixture(name: "eAcuteNFD", value: eAcuteNFD, u16: 2, graphemes: 1),
    Fixture(name: "ksha", value: ksha, u16: 3, graphemes: 1),
    Fixture(name: "thai", value: thai, u16: 2, graphemes: 1),
    Fixture(name: "stackedZ", value: stackedZ, u16: 3, graphemes: 1),
    Fixture(name: "mathX", value: mathX, u16: 2, graphemes: 1),
    Fixture(name: "mathAlpha", value: mathAlpha, u16: 2, graphemes: 1),
    Fixture(name: "dna", value: dna, u16: 2, graphemes: 1),
    Fixture(name: "arabic", value: arabic, u16: 5, graphemes: 5),
    Fixture(name: "hebrew", value: hebrew, u16: 4, graphemes: 4),
    Fixture(name: "emojiThumb", value: emojiThumb, u16: 4, graphemes: 3),
    Fixture(name: "emojiDown", value: emojiDown, u16: 4, graphemes: 3),
    Fixture(name: "cjkExpr", value: cjkExpr, u16: 10, graphemes: 10),
    Fixture(name: "bidiAssign", value: bidiAssign, u16: 12, graphemes: 12),
    Fixture(name: "tabEmoji", value: tabEmoji, u16: 5, graphemes: 4),
  ]

  /// The verification probe (D §"regenerate fixture facts"): re-derives `(u16,
  /// swiftGraphemes, nsComposedSeqs)` so a divergence between `NSString` composed
  /// boundaries and Swift `Character` boundaries surfaces immediately.
  static func facts(_ text: String) -> Facts {
    let nsString = text as NSString
    var index = 0
    var composed = 0
    while index < nsString.length {
      composed += 1
      index = NSMaxRange(nsString.rangeOfComposedCharacterSequence(at: index))
    }
    return Facts(u16: nsString.length, graphemes: text.count, composed: composed)
  }
}
