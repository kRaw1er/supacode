import Foundation
import Testing

@testable import supacode

/// Regression guard for the "whole region renders red" bug: a fast-scroll warm fan-out
/// launches many concurrent `styleRuns` for ONE blob, all sharing one cached neon
/// `TreeSitterClient`. `TreeSitterClient` is non-Sendable and its parse runs off-main during
/// the `highlights` await, so concurrent calls raced on neon's shared parse state and returned
/// CORRUPT captures — every line came back as a spurious `string` run (== `systemRed`). The fix
/// serializes parses per client (`DiffHighlightEngine.ParseGate`).
@MainActor
struct DiffHighlightConcurrentParseTests {
  /// ~24k lines of valid Swift with NO multi-line/unterminated strings, so a correct parse
  /// yields `string` runs on only the handful of lines that hold a literal. It must be LARGE:
  /// the race is on the shared client's off-main parse, and only a big source keeps a parse
  /// in flight long enough for a concurrent `highlights` call to collide with it (a small file
  /// finishes each parse before the next task interleaves, hiding the bug).
  private func syntheticSource() -> String {
    var lines: [String] = ["import Foundation", ""]
    for i in 0..<2500 {
      lines.append("func compute\(i)(value: Int) -> Int {")
      lines.append("  let doubled = value * 2  // plain code line, no string here")
      // A multi-line string block every so often — matching the real file's `"""` blocks. The
      // race corrupts the parse INTO one giant `string` node, so a balanced multi-line string
      // is what makes the collision manifest as "everything red".
      if i % 8 == 0 {
        lines.append("  reportIssue(")
        lines.append("    \"\"\"")
        lines.append("    diagnostic message number \(i) spanning")
        lines.append("    several lines of literal text content")
        lines.append("    \"\"\"")
        lines.append("  )")
      }
      lines.append("  return doubled + \(i)")
      lines.append("}")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private func input() -> HighlightBlobInput {
    HighlightBlobInput(blobOID: "concurrent-parse", utf16: DiffFixture.blob(syntheticSource()), path: "Gen.swift")
  }

  private func stringLineCount(_ engine: DiffHighlightEngine, lineCount: Int) -> Int {
    let query = DiffHighlightEngine.grammarQueryName(forPath: "Gen.swift")!
    var n = 0
    for line in 0..<lineCount
    where engine.cachedRuns(blobOID: "concurrent-parse", queryName: query, blobLine: line)
      .contains(where: { $0.capture.hasPrefix("string") })
    {
      n += 1
    }
    return n
  }

  @Test func concurrentFanOutDoesNotCorruptIntoAllString() async throws {
    let src = syntheticSource()
    let lineCount = src.split(separator: "\n", omittingEmptySubsequences: false).count
    let blob = input()

    // Baseline: one query at a time over the whole file → the known-good `string`-line count.
    let sequential = DiffHighlightEngine()
    _ = await sequential.styleRuns(for: blob, visibleLines: 0..<lineCount)
    let baseline = stringLineCount(sequential, lineCount: lineCount)

    // Fan-out: many CONCURRENT overlapping windows on ONE engine (one shared client), like a
    // fast scroll's warm burst. Pre-fix this raced neon into all-`string` garbage.
    let concurrent = DiffHighlightEngine()
    var windows: [Range<Int>] = []
    var lo = 0
    while lo < lineCount {
      windows.append(lo..<min(lineCount, lo + 300))
      lo += 150
    }
    var tasks: [Task<Void, Never>] = []
    for w in windows {
      tasks.append(Task { @MainActor in _ = await concurrent.styleRuns(for: blob, visibleLines: w) })
    }
    for t in tasks { await t.value }

    let underFanOut = stringLineCount(concurrent, lineCount: lineCount)
    let message: Comment = """
      concurrent fan-out corrupted the parse: \(underFanOut) string-lines vs \(baseline) baseline \
      (the all-red bug — concurrent `highlights` on one non-Sendable client)
      """
    #expect(underFanOut == baseline, message)
  }
}
