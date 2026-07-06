import Foundation

/// The whole-file gate that decides — UPSTREAM of the render path — whether a file
/// gets intra-line word-diff at all. `WordDiff` itself enforces only the per-line
/// 1000-char UTF-16 cap; the "a side has > 1000 changed lines → no word-diff"
/// decision belongs here, at the diff dispatcher (the reducer already has the
/// per-side changed-line counts from `git_patch_line_stats`). Suppressing word-diff
/// wholesale on a massively-changed file keeps the render path from running an
/// O(changed lines) token diff that the user could never read anyway.
///
/// Pierre parity: the whole-side changed-lines gate (WorkerPool `maxLineDiffLength`
/// family; both `maxLineDiffLength` / `tokenizeMaxLineLength` default `1000`). Phase
/// 13 extends this into a broader `LargeFileRenderPolicy`. Pure / static and
/// `nonisolated` so it can be evaluated off the main actor. No free functions.
nonisolated enum WordDiffPolicy {
  /// A side with more than this many changed lines suppresses intra-line word-diff
  /// for the whole file (pierre `maxLineDiffLength` default `1000`).
  static let maxChangedLinesPerSide = 1_000

  /// `true` ⇒ suppress word-diff for the whole file: neither side's per-line token
  /// diff runs, only the row-level `+`/`-` tint. Gated on the per-side changed-line
  /// counts the diff layer already has.
  static func isDisabled(oldChangedLines: Int, newChangedLines: Int) -> Bool {
    max(oldChangedLines, newChangedLines) > maxChangedLinesPerSide
  }
}
