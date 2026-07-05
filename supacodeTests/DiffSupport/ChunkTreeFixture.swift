import Foundation

@testable import supacode

/// I2 — fixtures over the **real** `ChunkTree`. `uniform(rows:)` scales to 1M
/// rows (one shared COW `[DiffLine]` backing, one segment per `maxLeafSpan`);
/// `files([FileSpec])` assembles a multi-file tree through the real builder.
/// `tree.diagnostics.seekCount` / `.buildRowsCallCount` are the load-bearing
/// spies (Phase-8 toggle-is-O(log n), seam 4.1).
@MainActor
enum ChunkTreeFixture {
  /// One file's inputs for a multi-file assembly.
  struct FileSpec {
    var file: FileChange
    var hunks: [DiffHunk]
    var expanded: Set<Int>

    init(file: FileChange, hunks: [DiffHunk], expanded: Set<Int> = []) {
      self.file = file
      self.hunks = hunks
      self.expanded = expanded
    }
  }

  /// A tree of `rows` uniform context lines, one segment per `maxLeafSpan`. Node
  /// count == `ceil(rows / maxLeafSpan)` — the "node count ≪ line count" fixture.
  static func uniform(rows: Int, metrics: ChunkLayoutMetrics = .production) -> ChunkTree {
    let tree = ChunkTree(metrics: metrics)
    guard rows > 0 else { return tree }
    let span = ChunkLayoutMetrics.maxLeafSpan
    let hunkID = HunkID(fileID: "uniform", index: 0)
    var lines: [DiffLine] = []
    lines.reserveCapacity(rows)
    for index in 0..<rows {
      lines.append(
        DiffLine(
          origin: .context,
          oldLineNumber: index + 1,
          newLineNumber: index + 1,
          content: "x",
          noNewlineAtEof: false
        )
      )
    }
    var after: ChunkID?
    var low = 0
    while low < rows {
      let high = min(low + span, rows)
      let segment = LineSegment(hunkID: hunkID, lines: lines, window: low..<high, classification: .context)
      after = tree.insert(.lineSegment(segment), after: after)
      low = high
    }
    return tree
  }

  /// A multi-file tree assembled through the real `ChunkTreeBuilder`.
  static func files(_ specs: [FileSpec], options: ChunkTreeBuilder.Options = ChunkTreeBuilder.Options()) -> ChunkTree {
    let tree = ChunkTree(metrics: options.metrics)
    for spec in specs {
      ChunkTreeBuilder.appendFile(
        into: tree,
        file: spec.file,
        hunks: spec.hunks,
        expanded: spec.expanded,
        options: options
      )
    }
    return tree
  }
}
