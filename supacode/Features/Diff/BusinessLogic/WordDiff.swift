import Foundation

/// Pure, side-effect-free intra-line token diff. Given one `(old, new)` line pair
/// it returns the character spans that changed on each side, so the viewer can
/// paint a stronger word-level background on top of the row's `+`/`-` tint.
///
/// Mode-agnostic (SpecFlow 6.3): callers pass a single pair, so unified and split
/// invoke it identically — split puts `oldSpans` on the left row and `newSpans`
/// on the right; unified puts `oldSpans` on the `-` row and `newSpans` on the `+`
/// row. Same inputs ⇒ same spans regardless of caller mode.
///
/// Static-only on a caseless `enum` (no top-level funcs, per CLAUDE.md).
enum WordDiff {
  /// A changed character span within one line. Offsets are **UTF-16** code-unit
  /// offsets so they compose directly with `NSRange` / `AttributedString`.
  struct Span: Equatable, Sendable {
    let range: Range<Int>
  }

  /// The changed spans on each side of a paired line.
  struct Result: Equatable, Sendable {
    let oldSpans: [Span]
    let newSpans: [Span]

    static let empty = Result(oldSpans: [], newSpans: [])
  }

  /// Above this character length on either side, intra-line diff is skipped — the
  /// row keeps only its whole-line `+`/`-` background (SpecFlow 2.9 / 7.5).
  static let maxLineLength = 2_000
  /// Guards `CollectionDifference`'s O(n·m) cost on pathological token runs.
  static let maxTokens = 400

  /// Intra-line token diff of one paired line. Returns `.empty` for identical
  /// lines, over-length lines, or over-token-count lines.
  static func diff(old: String, new: String) -> Result {
    if old == new { return .empty }
    if old.count > maxLineLength || new.count > maxLineLength { return .empty }

    let oldTokens = tokenize(old)
    let newTokens = tokenize(new)
    if oldTokens.texts.count > maxTokens || newTokens.texts.count > maxTokens { return .empty }

    let difference = newTokens.texts.difference(from: oldTokens.texts)
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

  // MARK: - Tokenization

  private enum TokenClass {
    case identifier
    case whitespace
  }

  /// Splits a line into contiguous tokens carrying their UTF-16 offset range:
  /// maximal identifier runs (letters / digits / `_`), maximal whitespace runs,
  /// and every other scalar as its own single-scalar punctuation token. Works on
  /// `UnicodeScalarView` (Swift-native, not `NSString`); offsets are accumulated
  /// in UTF-16 units so a span composes with `AttributedString` without a remap.
  private static func tokenize(_ line: String) -> (texts: [String], ranges: [Range<Int>]) {
    var texts: [String] = []
    var ranges: [Range<Int>] = []
    var offset = 0
    var runText = ""
    var runStart = 0
    var runClass: TokenClass?

    func flushRun() {
      guard runClass != nil, !runText.isEmpty else { return }
      texts.append(runText)
      ranges.append(runStart..<offset)
      runText.removeAll(keepingCapacity: true)
      runClass = nil
    }

    for scalar in line.unicodeScalars {
      let width = scalar.value > 0xFFFF ? 2 : 1
      let scalarClass = classify(scalar)
      switch scalarClass {
      case .identifier, .whitespace:
        if runClass == scalarClass {
          runText.unicodeScalars.append(scalar)
        } else {
          flushRun()
          runText.unicodeScalars.append(scalar)
          runStart = offset
          runClass = scalarClass
        }
      case nil:
        flushRun()
        texts.append(String(scalar))
        ranges.append(offset..<(offset + width))
      }
      offset += width
    }
    flushRun()
    return (texts, ranges)
  }

  /// `nil` ⇒ punctuation (each scalar is its own token).
  private static func classify(_ scalar: Unicode.Scalar) -> TokenClass? {
    if scalar == "_" || scalar.properties.isAlphabetic || (scalar.value >= 0x30 && scalar.value <= 0x39) {
      return .identifier
    }
    if scalar.properties.isWhitespace {
      return .whitespace
    }
    return nil
  }

  // MARK: - Span merging

  /// Merges the given token indices (into `ranges`) into contiguous character
  /// spans: adjacent token indices are coalesced because tokens partition the
  /// line, so consecutive indices are always character-contiguous.
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
