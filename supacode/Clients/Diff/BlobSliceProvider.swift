import Foundation
import libgit2

/// Reveals hidden unchanged lines by reading the git blob for a file's NEW side —
/// the incremental replacement for the deleted 1M-context re-diff. It builds a
/// line-start offset table once per blob (one linear pass, cached), then slices a
/// line range into context `DiffLine`s. It **NEVER** calls `git_diff_*`: the
/// working-tree post-image is read straight off disk and the base-branch new side
/// is HEAD's tree blob, so no diff is ever materialized.
///
/// An `actor` reusing `Libgit2Diff`'s `import libgit2` so libgit2 (built
/// `GIT_THREADS=1`) stays single-threaded per repo — the same confinement
/// contract as `LibGit2DiffProvider`: every C handle is freed before returning.
actor BlobSliceProvider {
  /// > 2 MB blobs are skipped (mirrors `LibGit2DiffProvider.byteCap`): the giant
  /// blob would be a minified line the CTLine cache must never touch.
  static let byteCap = 2 * 1024 * 1024

  /// Cached decoded line tables, keyed by blob identity so a re-slice on scroll —
  /// and on re-diff — is O(range), not O(fileLen). Blob OID for `.baseBranch`;
  /// `(path, size, mtime)` for the on-disk working-tree post-image (a mid-edit
  /// write invalidates the stale table).
  private var cache: [BlobCacheKey: BlobLineTable] = [:]

  /// Instrumentation the fixtures assert on. `diffBuilds` stays 0 forever — the
  /// provider has NO `git_diff_*` path — which is the "reads the blob only" proof
  /// (`blobSliceNeverCallsGitDiff`).
  private(set) var diagnostics = Diagnostics()

  nonisolated struct Diagnostics: Equatable, Sendable {
    var blobReads = 0
    var cacheHits = 0
    /// Always 0: the provider never builds a `git_diff`. A non-zero value would be
    /// a regression back to the deleted re-diff path.
    var diffBuilds = 0
  }

  init() {
    Libgit2Diff.initialize()
  }

  /// The context `DiffLine`s for the half-open new-side `newLineRange`. Unchanged
  /// gap lines advance old/new in lockstep, so a single `oldLineDelta` per gap is
  /// exact: `oldLineNumber = newLineNumber + oldLineDelta`. Never re-diffs.
  func slice(
    file: FileChange,
    worktreeURL: URL,
    source: DiffSource,
    newLineRange: Range<Int>,
    oldLineDelta: Int
  ) throws -> [DiffLine] {
    let table = try lineTable(file: file, worktreeURL: worktreeURL, source: source)
    return Self.slice(table, newLineRange: newLineRange, oldLineDelta: oldLineDelta)
  }

  /// The cached (or freshly built) line table for the file's NEW side, or an empty
  /// table when the path is absent / non-UTF-8 / over the byte cap.
  private func lineTable(file: FileChange, worktreeURL: URL, source: DiffSource) throws -> BlobLineTable {
    switch source {
    case .workingTree:
      return try workingTreeLineTable(file: file, worktreeURL: worktreeURL)
    case .baseBranch:
      return try baseBranchLineTable(file: file, worktreeURL: worktreeURL)
    }
  }

  /// On-disk post-image (tracked + untracked + added). Cache invalidates on a
  /// `(size, mtime)` change so a mid-edit write drops a stale table.
  private func workingTreeLineTable(file: FileChange, worktreeURL: URL) throws -> BlobLineTable {
    guard let newPath = file.newPath else { return .empty }
    let url = worktreeURL.appending(path: newPath)
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    let size = (attributes?[.size] as? Int) ?? -1
    let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? -1
    let key = BlobCacheKey.workingTree(path: newPath, size: size, mtime: mtime)
    if let cached = cache[key] {
      diagnostics.cacheHits += 1
      return cached
    }
    guard size >= 0, size <= Self.byteCap, let data = try? Data(contentsOf: url),
      let text = String(data: data, encoding: .utf8)
    else { return .empty }
    diagnostics.blobReads += 1
    let table = BlobLineTable.build(utf16: Array(text.utf16))
    cache[key] = table
    return table
  }

  /// The new side of the three-dot diff is HEAD's tree blob for the path
  /// (`makeBaseDiff` peels the same HEAD tree). Cached by blob OID so the O(fileLen)
  /// decode + table build happens once per content identity.
  private func baseBranchLineTable(file: FileChange, worktreeURL: URL) throws -> BlobLineTable {
    guard let newPath = file.newPath else { return .empty }
    let read = try Libgit2Diff.headBlobContentUTF16(at: worktreeURL, path: newPath, byteCap: Self.byteCap)
    guard let read else { return .empty }
    let key = BlobCacheKey.blob(oid: read.oid)
    if let cached = cache[key] {
      diagnostics.cacheHits += 1
      return cached
    }
    diagnostics.blobReads += 1
    let table = BlobLineTable.build(utf16: read.utf16)
    cache[key] = table
    return table
  }

  /// Slice a line table into context `DiffLine`s over the (clamped) new-side range.
  /// `static` so the pure slicing math is unit-testable without an actor hop.
  static func slice(_ table: BlobLineTable, newLineRange: Range<Int>, oldLineDelta: Int) -> [DiffLine] {
    let low = max(newLineRange.lowerBound, 1)
    let high = min(newLineRange.upperBound, table.lineCount + 1)
    guard low < high else { return [] }
    var out: [DiffLine] = []
    out.reserveCapacity(high - low)
    for number in low..<high {
      out.append(
        DiffLine(
          origin: .context,
          oldLineNumber: number + oldLineDelta,
          newLineNumber: number,
          content: table.content(line: number),
          noNewlineAtEof: false
        )
      )
    }
    return out
  }
}

// MARK: - Cache key

/// Blob identity for the slice cache. A base-branch blob keys on its OID (stable
/// content identity); a working-tree post-image keys on `(path, size, mtime)` so a
/// mid-edit rewrite invalidates the table. `nonisolated` so its `Hashable`
/// conformance is usable inside the actor (the app target is `@MainActor`-default).
private nonisolated enum BlobCacheKey: Hashable, Sendable {
  case blob(oid: String)
  case workingTree(path: String, size: Int, mtime: Double)
}

// MARK: - Line-start table

/// A decoded blob's line-start offset table (brainstorm §UTF-16: "build a
/// line-start UTF-16 offset table … line↔file offset is O(1) after"). Collapse /
/// expand operates on whole lines (line-start entries), which are inherently on
/// grapheme boundaries — a `\n` can never fall inside a cluster (D I5).
nonisolated struct BlobLineTable: Equatable, Sendable {
  /// The decoded content as UTF-16 code units.
  let utf16: [UInt16]
  /// The UTF-16 offset of each line's first code unit (1 entry per line).
  let lineStarts: [Int]
  /// The UTF-16 offset one past each line's last content code unit — the trailing
  /// `\n` / `\r\n` is excluded (matching `DiffLine.content`).
  let lineEnds: [Int]

  static let empty = BlobLineTable(utf16: [], lineStarts: [], lineEnds: [])

  init(utf16: [UInt16], lineStarts: [Int], lineEnds: [Int]) {
    self.utf16 = utf16
    self.lineStarts = lineStarts
    self.lineEnds = lineEnds
  }

  /// The number of lines. A single trailing newline is collapsed (pierre
  /// `iterateOverFile`): `"a\nb\n"` is two lines, not three.
  var lineCount: Int { lineStarts.count }

  /// The content of the 1-based `line` (its trailing newline already stripped), or
  /// `""` when out of range.
  func content(line: Int) -> String {
    guard line >= 1, line <= lineCount else { return "" }
    let start = lineStarts[line - 1]
    let end = lineEnds[line - 1]
    guard start < end else { return "" }
    return String(decoding: utf16[start..<end], as: UTF16.self)
  }

  /// One linear pass building the line-start / line-end tables. A single trailing
  /// newline is collapsed; a `\r\n` line ending strips the `\r` from the content.
  static func build(utf16: [UInt16]) -> BlobLineTable {
    let newline = UInt16(0x0A)  // \n
    let carriage = UInt16(0x0D)  // \r
    var starts: [Int] = []
    var ends: [Int] = []
    var lineStart = 0
    var index = 0
    while index < utf16.count {
      if utf16[index] == newline {
        var end = index
        if end > lineStart && utf16[end - 1] == carriage { end -= 1 }
        starts.append(lineStart)
        ends.append(end)
        lineStart = index + 1
      }
      index += 1
    }
    // A final line without a trailing newline. When the content ended with `\n`,
    // `lineStart == utf16.count` — the trailing newline is collapsed (no empty row).
    if lineStart < utf16.count {
      var end = utf16.count
      if end > lineStart && utf16[end - 1] == carriage { end -= 1 }
      starts.append(lineStart)
      ends.append(end)
    }
    return BlobLineTable(utf16: utf16, lineStarts: starts, lineEnds: ends)
  }
}
