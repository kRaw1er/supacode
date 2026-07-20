import Foundation

/// Content-anchored relocation for review comments. Re-runs on every re-diff of
/// a file (driven by `.filesChanged` in Phase 3) so a comment tracks its lines
/// as the agent edits around them, and is marked `orphaned` — never deleted —
/// when its lines vanish (5.1). Static-only on a caseless enum (no free funcs).
enum CommentAnchor {
  /// Re-locate `comment` against the freshly re-diffed `lines` for its side.
  /// Returns an updated comment: new `startLine`/`endLine` when the anchored
  /// snippet is found, or `orphaned = true` with the range left intact when not.
  static func relocate(_ comment: ReviewComment, in lines: [DiffLine], side: DiffSide) -> ReviewComment {
    // 1. Project onto `side`: git line numbers are the anchor coordinates.
    var numbers: [Int] = []
    var contents: [String] = []
    numbers.reserveCapacity(lines.count)
    contents.reserveCapacity(lines.count)
    for line in lines {
      guard let number = line.lineNumber(on: side) else { continue }
      numbers.append(number)
      contents.append(normalize(line.content))
    }

    let target = splitLines(comment.anchorSnippet)
    let windowSize = target.count
    let context = splitLines(comment.contextBefore)
    guard windowSize > 0, contents.count >= windowSize else {
      return orphaned(comment)
    }

    // 3. Primary match — snippet + context. 4. Fallback — snippet only.
    let candidates = matchingWindows(target: target, in: contents, windowSize: windowSize)
    let withContext = candidates.filter { contextMatches(context, before: $0, in: contents) }
    let pool = withContext.isEmpty ? candidates : withContext
    guard !pool.isEmpty else { return orphaned(comment) }

    // Among matches, pick the window whose new start line is closest to the
    // old start line (minimizes drift when a block was duplicated).
    let bestStart = pool.min {
      abs(numbers[$0] - comment.startLine) < abs(numbers[$1] - comment.startLine)
    }!

    // 5. Found → set range to the matched window's git line numbers, clear
    // orphaned, then clamp to the last contiguous line (5.3).
    var relocated = comment
    relocated.startLine = numbers[bestStart]
    relocated.endLine = clampedEnd(from: bestStart, windowSize: windowSize, numbers: numbers)
    relocated.orphaned = false
    return relocated
  }

  // MARK: - Matching

  /// Start indices of every N-line window in `contents` whose joined content
  /// equals the target snippet.
  private static func matchingWindows(target: [String], in contents: [String], windowSize: Int) -> [Int] {
    guard windowSize <= contents.count else { return [] }
    var starts: [Int] = []
    for start in 0...(contents.count - windowSize) where windowMatches(target, in: contents, at: start) {
      starts.append(start)
    }
    return starts
  }

  private static func windowMatches(_ target: [String], in contents: [String], at start: Int) -> Bool {
    for offset in 0..<target.count where contents[start + offset] != target[offset] {
      return false
    }
    return true
  }

  /// Context compared as a suffix so a shrunk file head still matches: only the
  /// overlapping tail of the target context and the candidate's preceding lines
  /// are required to be equal. An empty target context always matches.
  private static func contextMatches(_ context: [String], before start: Int, in contents: [String]) -> Bool {
    guard !context.isEmpty else { return true }
    let preceding = Array(contents[max(0, start - context.count)..<start])
    let overlap = min(context.count, preceding.count)
    guard overlap > 0 else { return false }
    for offset in 1...overlap where context[context.count - offset] != preceding[preceding.count - offset] {
      return false
    }
    return true
  }

  /// Shrinks the window end to the last line that is contiguous in git
  /// numbering with the start, so a comment never spans a hunk-boundary gap.
  private static func clampedEnd(from start: Int, windowSize: Int, numbers: [Int]) -> Int {
    var end = start
    var index = start + 1
    while index < start + windowSize, numbers[index] == numbers[index - 1] + 1 {
      end = index
      index += 1
    }
    return numbers[end]
  }

  // MARK: - Helpers

  private static func orphaned(_ comment: ReviewComment) -> ReviewComment {
    var result = comment
    result.orphaned = true
    return result
  }

  /// Splits a multi-line snippet into normalized constituent lines.
  private static func splitLines(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    return text.split(separator: "\n", omittingEmptySubsequences: false).map { normalize(String($0)) }
  }

  /// Trims only a trailing `\r` (git keeps the line body); leading indentation
  /// is preserved because an indentation change is a real edit worth re-anchoring on.
  private static func normalize(_ line: String) -> String {
    line.hasSuffix("\r") ? String(line.dropLast()) : line
  }
}
