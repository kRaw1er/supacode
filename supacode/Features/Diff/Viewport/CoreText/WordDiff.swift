import CoreFoundation
import Foundation

/// Pure, side-effect-free intra-line token diff. One `(old, new)` line pair →
/// the changed **UTF-16** character spans on each side, so the viewer can paint a
/// stronger word-level background on top of the row's `+`/`-` tint.
///
/// Mode-agnostic (SpecFlow 6.3): callers pass a single pair, so unified and split
/// invoke it identically — split routes `oldSpans`→left / `newSpans`→right, unified
/// routes `oldSpans`→`-` row / `newSpans`→`+` row. Same inputs ⇒ same spans
/// regardless of caller mode.
///
/// Phase 5 rewrite: the scalar `isAlphabetic`/whitespace tokenizer is replaced by
/// `CFStringTokenizer(kCFStringTokenizerUnitWordBoundary)` — the Unicode
/// word-boundary segmenter (pierre's `Intl.Segmenter` analog). The tokenizer emits
/// WORD units and SKIPS the separators between them; `jsdiff diffWordsWithSpace`
/// keeps whitespace as content, so each skipped gap is re-emitted, sub-tokenized
/// into maximal whitespace runs + per-punctuation graphemes. Every recorded range
/// is grapheme-snapped via `rangeOfComposedCharacterSequences(for:)` so a surrogate
/// pair / combining mark / emoji ZWJ sequence is never split (G2/G4).
///
/// Static-only on a caseless `enum` (no top-level funcs, per CLAUDE.md).
enum WordDiff {
  /// A changed character span within one line. Offsets are **UTF-16** code-unit
  /// offsets so they compose directly with `NSRange` / `AttributedString` /
  /// `CTLineGetOffsetForStringIndex`.
  struct Span: Equatable, Sendable {
    let range: Range<Int>
  }

  /// The changed spans on each side of a paired line.
  struct Result: Equatable, Sendable {
    let oldSpans: [Span]
    let newSpans: [Span]

    static let empty = Result(oldSpans: [], newSpans: [])
  }

  /// Pierre parity: `maxLineDiffLength` / `tokenizeMaxLineLength` both default
  /// `1000` (WorkerPool/`constants.ts:430-431`). Above this **UTF-16** length on
  /// either side, keep only the whole-line `+`/`-` tint (was `2000`; a deliberate
  /// pierre-parity change). The whole-side ">1000 changed lines → no word-diff"
  /// gate is enforced UPSTREAM (`WordDiffPolicy`), never here.
  static let maxLineLength = 1_000
  /// Defensive O(n·m) guard on `CollectionDifference` (ours; pierre relies on the
  /// char cap). Kept from the current impl.
  static let maxTokens = 400

  /// Hot-path entry — the caller holds a UTF-16-native line (Phase 3
  /// `UTF16LineStore`), so no Swift-`String` bridge on the render path. The cap
  /// unit is `NSString.length` (UTF-16 code units), NOT graphemes (G3).
  static func diff(old: NSString, new: NSString) -> Result {
    if old.isEqual(new) { return .empty }
    if old.length > maxLineLength || new.length > maxLineLength { return .empty }
    let oldTokens = tokenize(old)
    let newTokens = tokenize(new)
    if oldTokens.texts.count > maxTokens || newTokens.texts.count > maxTokens { return .empty }

    let difference = newTokens.texts.difference(from: oldTokens.texts)  // CollectionDifference LCS
    var removedIndices: [Int] = []
    var insertedIndices: [Int] = []
    for change in difference {
      switch change {
      case .remove(let offset, _, _): removedIndices.append(offset)
      case .insert(let offset, _, _): insertedIndices.append(offset)
      }
    }
    return Result(
      oldSpans: mergedSpans(from: removedIndices, ranges: oldTokens.ranges),
      newSpans: mergedSpans(from: insertedIndices, ranges: newTokens.ranges)
    )
  }

  /// String convenience (tests / non-hot-path). Bridges once to `NSString`.
  static func diff(old: String, new: String) -> Result {
    diff(old: old as NSString, new: new as NSString)
  }

  // MARK: - Tokenization (Unicode words + gap sub-tokens)

  /// `CFStringTokenizer(kCFStringTokenizerUnitWordBoundary)` yields WORD units and
  /// SKIPS the separators between them; `jsdiff diffWordsWithSpace` keeps whitespace
  /// as content, so we re-emit each skipped gap `[cursor, start)` — sub-tokenized
  /// into maximal whitespace runs + per-punctuation graphemes (this granularity is
  /// what preserves `multiTokenEdit`'s two spans across an unchanged space). All
  /// ranges grapheme-snapped so a surrogate pair / emoji is never split.
  private static func tokenize(_ line: NSString) -> (texts: [String], ranges: [Range<Int>]) {
    var texts: [String] = []
    var ranges: [Range<Int>] = []
    guard line.length > 0 else { return (texts, ranges) }
    let tokenizer = CFStringTokenizerCreate(
      kCFAllocatorDefault,
      line as CFString,
      CFRange(location: 0, length: line.length),
      kCFStringTokenizerUnitWordBoundary,
      CFLocaleCopyCurrent()
    )
    var cursor = 0
    while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
      let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)  // UTF-16 location/length
      let start = tokenRange.location
      let end = tokenRange.location + tokenRange.length
      if start > cursor { emitGap(line, cursor, start, &texts, &ranges) }  // separators
      emit(line, start, end, &texts, &ranges)  // word unit
      cursor = end
    }
    if cursor < line.length { emitGap(line, cursor, line.length, &texts, &ranges) }  // trailing gap
    return (texts, ranges)
  }

  /// Sub-tokenize a separator gap: coalesce maximal whitespace runs; every other
  /// grapheme is its own punctuation token (matches the old scalar classifier's
  /// granularity — but only over the gaps, so ` + ` stays three tokens and an
  /// unchanged space is never lumped into a neighbouring changed span).
  private static func emitGap(
    _ line: NSString, _ lower: Int, _ upper: Int, _ texts: inout [String], _ ranges: inout [Range<Int>]
  ) {
    var index = lower
    while index < upper {
      let cluster = line.rangeOfComposedCharacterSequence(at: index)  // grapheme cluster at `index`
      if isWhitespace(line, at: index) {
        var end = NSMaxRange(cluster)
        while end < upper, isWhitespace(line, at: end) {
          end = NSMaxRange(line.rangeOfComposedCharacterSequence(at: end))
        }
        emit(line, index, end, &texts, &ranges)
        index = end
      } else {
        let end = NSMaxRange(cluster)
        emit(line, index, end, &texts, &ranges)
        index = end
      }
    }
  }

  /// Grapheme-snap `[lo, hi)` OUTWARD then record. ICU word boundaries are already
  /// grapheme-aligned, so the snap is a no-op for word units and only guards the
  /// arithmetic gap boundaries (G4: a bound falling inside a composed sequence is
  /// widened to the whole cluster on BOTH ends).
  private static func emit(
    _ line: NSString, _ lower: Int, _ upper: Int, _ texts: inout [String], _ ranges: inout [Range<Int>]
  ) {
    guard upper > lower else { return }
    let snapped = line.rangeOfComposedCharacterSequences(for: NSRange(location: lower, length: upper - lower))
    guard snapped.length > 0 else { return }
    texts.append(line.substring(with: snapped))
    ranges.append(snapped.location..<NSMaxRange(snapped))
  }

  private static func isWhitespace(_ line: NSString, at index: Int) -> Bool {
    guard let scalar = Unicode.Scalar(line.character(at: index)) else { return false }
    return scalar.properties.isWhitespace
  }

  // MARK: - Span merging (coalesce changed-adjacent indices)

  /// Tokens partition the line contiguously, so consecutive changed indices are
  /// char-contiguous → one span. A changed whitespace token between two changed
  /// words merges automatically (its index is adjacent); an UNCHANGED space does
  /// NOT (its token index is absent from `indices`, so the run breaks) — this is
  /// the per-token join rule the ported `WordDiffTests` contract requires.
  private static func mergedSpans(from indices: [Int], ranges: [Range<Int>]) -> [Span] {
    guard !indices.isEmpty else { return [] }
    let sorted = indices.sorted()
    var spans: [Span] = []
    var lower = ranges[sorted[0]].lowerBound
    var upper = ranges[sorted[0]].upperBound
    var previous = sorted[0]
    for index in sorted.dropFirst() {
      if index == previous + 1 {
        upper = ranges[index].upperBound
      } else {
        spans.append(Span(range: lower..<upper))
        lower = ranges[index].lowerBound
        upper = ranges[index].upperBound
      }
      previous = index
    }
    spans.append(Span(range: lower..<upper))
    return spans
  }
}
