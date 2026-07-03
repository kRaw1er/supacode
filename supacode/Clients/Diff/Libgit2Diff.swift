import Foundation
import libgit2

/// Thin in-house binding over the ~dozen stable libgit2 C functions the diff
/// layer needs. Static methods on a caseless `enum` (no top-level funcs).
///
/// **Confinement contract:** every method opens the repository, builds the
/// diff, materializes the patch(es), reads what it needs into the `Sendable`
/// value types in `DiffModels`, and frees every C object before returning. No
/// `OpaquePointer` / `git_*` value is ever stored or returned. The methods run
/// synchronously with no suspension point, so when `LibGit2DiffProvider` calls
/// them from its isolated context they execute on the actor's serial executor —
/// which is what keeps libgit2 (built `GIT_THREADS=1`) single-threaded per repo.
nonisolated enum Libgit2Diff {
  struct Caps: Sendable {
    var byteCap: Int
    var lineCap: Int
    var longLineCap: Int
  }

  /// The full diff walk of one file, shared by the cheap metadata path and the
  /// on-demand hunk path so the two can never diverge.
  private struct FileDiffResult {
    var addedLines: Int
    var removedLines: Int
    var isBinary: Bool
    var isLargeFileCapped: Bool
    var hasLongLines: Bool
    var hunks: [DiffHunk]
  }

  /// `git_libgit2_init` is ref-counted; calling once per actor is enough.
  static func initialize() {
    _ = git_libgit2_init()
  }

  // MARK: - Public entry points

  static func changedFiles(at worktreeURL: URL, caps: Caps) throws -> WorktreeDiff {
    let repo = try openRepository(at: worktreeURL)
    defer { git_repository_free(repo) }

    let isUnborn = git_repository_head_unborn(repo) == 1
    let operation = repositoryOperation(repo)

    let (diff, tree) = try makeDiff(repo: repo, isUnborn: isUnborn)
    defer {
      git_diff_free(diff)
      if let tree { git_tree_free(tree) }
    }
    try findSimilar(diff)

    var files: [FileChange] = []
    let count = git_diff_num_deltas(diff)
    var idx = 0
    while idx < count {
      defer { idx += 1 }
      guard let deltaPtr = git_diff_get_delta(diff, idx) else { continue }
      let delta = deltaPtr.pointee
      let result = fileDiffResult(delta: delta, diff: diff, idx: idx, caps: caps, wantHunks: false)
      files.append(makeFileChange(delta: delta, result: result))
    }
    return WorktreeDiff(files: files, isUnbornHead: isUnborn, operation: operation)
  }

  static func hunks(for file: FileChange, at worktreeURL: URL, caps: Caps) throws -> [DiffHunk] {
    let repo = try openRepository(at: worktreeURL)
    defer { git_repository_free(repo) }

    let isUnborn = git_repository_head_unborn(repo) == 1
    let (diff, tree) = try makeDiff(repo: repo, isUnborn: isUnborn)
    defer {
      git_diff_free(diff)
      if let tree { git_tree_free(tree) }
    }
    try findSimilar(diff)

    let count = git_diff_num_deltas(diff)
    var idx = 0
    while idx < count {
      defer { idx += 1 }
      guard let deltaPtr = git_diff_get_delta(diff, idx) else { continue }
      let delta = deltaPtr.pointee
      guard deltaMatches(delta, file: file) else { continue }
      let result = fileDiffResult(delta: delta, diff: diff, idx: idx, caps: caps, wantHunks: true)
      if result.isBinary || result.isLargeFileCapped {
        return []
      }
      return result.hunks
    }
    return []
  }

  // MARK: - Repository / diff construction

  private static func openRepository(at url: URL) throws -> OpaquePointer {
    var repo: OpaquePointer?
    let code = url.path(percentEncoded: false).withCString { git_repository_open(&repo, $0) }
    guard code == 0, let repo else {
      if code == GIT_ENOTFOUND.rawValue {
        throw DiffError.notARepository
      }
      throw lastError(code)
    }
    return repo
  }

  /// Returns `(diff, headTree?)`. `headTree` is `nil` for an unborn HEAD, which
  /// makes `git_diff_tree_to_workdir_with_index` diff against the empty tree so
  /// every file surfaces as an addition.
  private static func makeDiff(repo: OpaquePointer, isUnborn: Bool) throws -> (OpaquePointer, OpaquePointer?) {
    var tree: OpaquePointer?
    if !isUnborn {
      tree = try headTree(repo: repo)
    }

    var opts = git_diff_options()
    var returnCode = git_diff_options_init(&opts, UInt32(GIT_DIFF_OPTIONS_VERSION))
    guard returnCode == 0 else {
      if let tree { git_tree_free(tree) }
      throw lastError(returnCode)
    }
    // Untracked included + recurse into untracked dirs + show their content
    // (so a new file's lines surface as additions and non-UTF8 detection can
    // run); typechanges surfaced; patience for readable diffs.
    // GIT_DIFF_INCLUDE_IGNORED is deliberately left unset so `.gitignore` is
    // honored.
    opts.flags =
      GIT_DIFF_INCLUDE_UNTRACKED.rawValue
      | GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue
      | GIT_DIFF_SHOW_UNTRACKED_CONTENT.rawValue
      | GIT_DIFF_INCLUDE_TYPECHANGE.rawValue
      | GIT_DIFF_PATIENCE.rawValue

    var diff: OpaquePointer?
    returnCode = git_diff_tree_to_workdir_with_index(&diff, repo, tree, &opts)
    guard returnCode == 0, let diff else {
      if let tree { git_tree_free(tree) }
      throw lastError(returnCode)
    }
    return (diff, tree)
  }

  private static func headTree(repo: OpaquePointer) throws -> OpaquePointer {
    var ref: OpaquePointer?
    var returnCode = git_repository_head(&ref, repo)
    guard returnCode == 0, let ref else { throw lastError(returnCode) }
    defer { git_reference_free(ref) }

    var object: OpaquePointer?
    returnCode = git_reference_peel(&object, ref, GIT_OBJECT_TREE)
    guard returnCode == 0, let object else { throw lastError(returnCode) }
    // The peeled object is a tree; `git_tree_free` is `git_object_free` for it.
    return object
  }

  private static func findSimilar(_ diff: OpaquePointer) throws {
    var findOpts = git_diff_find_options()
    var returnCode = git_diff_find_options_init(&findOpts, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION))
    guard returnCode == 0 else { throw lastError(returnCode) }
    findOpts.flags =
      GIT_DIFF_FIND_RENAMES.rawValue
      | GIT_DIFF_FIND_COPIES.rawValue
      | GIT_DIFF_FIND_FOR_UNTRACKED.rawValue
    returnCode = git_diff_find_similar(diff, &findOpts)
    guard returnCode == 0 else { throw lastError(returnCode) }
  }

  // MARK: - Per-file materialization

  /// Materializes one delta into stats + optional hunks. Short-circuits the
  /// size cap *before* touching the patch so a giant file is never walked.
  private static func fileDiffResult(
    delta: git_diff_delta,
    diff: OpaquePointer,
    idx: Int,
    caps: Caps,
    wantHunks: Bool
  ) -> FileDiffResult {
    let oldSize = Int(delta.old_file.size)
    let newSize = Int(delta.new_file.size)
    if max(oldSize, newSize) > caps.byteCap {
      // Capped by byte size: do not materialize the patch (that is the
      // expensive step). Counts unknown, hunks omitted.
      return FileDiffResult(
        addedLines: 0,
        removedLines: 0,
        isBinary: false,
        isLargeFileCapped: true,
        hasLongLines: false,
        hunks: []
      )
    }

    var patch: OpaquePointer?
    let returnCode = git_patch_from_diff(&patch, diff, idx)
    guard returnCode == 0, let patch else {
      // A patch that fails to materialize (e.g. unreadable) is treated as an
      // empty, non-fatal result rather than aborting the whole diff.
      return FileDiffResult(
        addedLines: 0,
        removedLines: 0,
        isBinary: false,
        isLargeFileCapped: false,
        hasLongLines: false,
        hunks: []
      )
    }
    defer { git_patch_free(patch) }

    let numHunks = git_patch_num_hunks(patch)

    // Binary detection is only reliable after materialization: read the delta
    // back from the patch so the freshly-set BINARY flag is visible. The flag
    // alone is authoritative — a `numHunks == 0` fallback would false-positive
    // on renames (a staged rename reports `new_file.size == 0`) and on pure
    // mode changes.
    var isBinary = false
    if let updatedDeltaPtr = git_patch_get_delta(patch) {
      let updated = updatedDeltaPtr.pointee
      isBinary = (updated.flags & GIT_DIFF_FLAG_BINARY.rawValue) != 0
    }
    if isBinary {
      return FileDiffResult(
        addedLines: 0,
        removedLines: 0,
        isBinary: true,
        isLargeFileCapped: false,
        hasLongLines: false,
        hunks: []
      )
    }

    var contextLines = 0
    var additions = 0
    var deletions = 0
    _ = git_patch_line_stats(&contextLines, &additions, &deletions, patch)
    let totalLines = contextLines + additions + deletions
    if totalLines > caps.lineCap {
      // Capped by line count: counts are still cheap from line_stats, hunks
      // omitted so we never build a 50k-line array.
      return FileDiffResult(
        addedLines: additions,
        removedLines: deletions,
        isBinary: false,
        isLargeFileCapped: true,
        hasLongLines: false,
        hunks: []
      )
    }

    if !wantHunks {
      // Cheap metadata path: still need long-line + non-UTF8 detection, which
      // requires the line walk, but skip building the hunk array.
      let walk = walkPatch(patch, numHunks: numHunks, caps: caps, collectHunks: false)
      if walk.nonUTF8 {
        return FileDiffResult(
          addedLines: 0,
          removedLines: 0,
          isBinary: true,
          isLargeFileCapped: false,
          hasLongLines: false,
          hunks: []
        )
      }
      return FileDiffResult(
        addedLines: additions,
        removedLines: deletions,
        isBinary: false,
        isLargeFileCapped: false,
        hasLongLines: walk.hasLongLines,
        hunks: []
      )
    }

    let walk = walkPatch(patch, numHunks: numHunks, caps: caps, collectHunks: true)
    if walk.nonUTF8 {
      // A line failed strict UTF-8 decode → treat the whole file as binary and
      // drop its hunks rather than surface mojibake.
      return FileDiffResult(
        addedLines: 0,
        removedLines: 0,
        isBinary: true,
        isLargeFileCapped: false,
        hasLongLines: false,
        hunks: []
      )
    }
    return FileDiffResult(
      addedLines: additions,
      removedLines: deletions,
      isBinary: false,
      isLargeFileCapped: false,
      hasLongLines: walk.hasLongLines,
      hunks: walk.hunks
    )
  }

  private struct PatchWalk {
    var hunks: [DiffHunk]
    var hasLongLines: Bool
    var nonUTF8: Bool
  }

  /// Walks every hunk/line of a materialized patch, decoding content strictly.
  /// Bails early (returning `nonUTF8 = true`) on the first line that fails a
  /// strict UTF-8 decode.
  private static func walkPatch(
    _ patch: OpaquePointer,
    numHunks: Int,
    caps: Caps,
    collectHunks: Bool
  ) -> PatchWalk {
    var hunks: [DiffHunk] = []
    var hasLongLines = false

    var hunkIdx = 0
    while hunkIdx < numHunks {
      defer { hunkIdx += 1 }
      var hunkPtr: UnsafePointer<git_diff_hunk>?
      var linesInHunk = 0
      let hunkRC = git_patch_get_hunk(&hunkPtr, &linesInHunk, patch, hunkIdx)
      guard hunkRC == 0, let hunkPtr else { continue }
      var hunkValue = hunkPtr.pointee

      var lines: [DiffLine] = []
      var lineIdx = 0
      while lineIdx < linesInHunk {
        defer { lineIdx += 1 }
        var linePtr: UnsafePointer<git_diff_line>?
        let lineRC = git_patch_get_line_in_hunk(&linePtr, patch, hunkIdx, lineIdx)
        guard lineRC == 0, let linePtr else { continue }
        let line = linePtr.pointee

        guard let content = decodeContent(line) else {
          return PatchWalk(hunks: [], hasLongLines: false, nonUTF8: true)
        }
        if content.count > caps.longLineCap {
          hasLongLines = true
        }

        let originChar = line.origin
        switch originChar {
        case Self.contextChar, Self.additionChar, Self.deletionChar:
          let origin: DiffLineOrigin =
            originChar == Self.additionChar
            ? .addition : (originChar == Self.deletionChar ? .deletion : .context)
          lines.append(
            DiffLine(
              origin: origin,
              oldLineNumber: line.old_lineno < 0 ? nil : Int(line.old_lineno),
              newLineNumber: line.new_lineno < 0 ? nil : Int(line.new_lineno),
              content: content,
              noNewlineAtEof: false
            )
          )
        case Self.contextEofnlChar, Self.addEofnlChar, Self.delEofnlChar:
          // "\ No newline at end of file" marker — attach to the last emitted
          // content line rather than surfacing it as its own row.
          if !lines.isEmpty {
            lines[lines.count - 1].noNewlineAtEof = true
          }
        default:
          continue
        }
      }

      if collectHunks {
        let header = decodeHeader(&hunkValue)
        hunks.append(
          DiffHunk(
            oldStart: Int(hunkValue.old_start),
            oldCount: Int(hunkValue.old_lines),
            newStart: Int(hunkValue.new_start),
            newCount: Int(hunkValue.new_lines),
            header: header,
            lines: lines
          )
        )
      }
    }

    return PatchWalk(hunks: hunks, hasLongLines: hasLongLines, nonUTF8: false)
  }

  // MARK: - Decoding helpers

  /// `git_diff_line.content` is NOT NUL-terminated — read exactly
  /// `content_len` bytes and strip a single trailing newline.
  private static func decodeContent(_ line: git_diff_line) -> String? {
    guard let start = line.content, line.content_len > 0 else {
      return ""
    }
    let buffer = UnsafeRawBufferPointer(start: start, count: line.content_len)
    guard var text = String(bytes: buffer, encoding: .utf8) else {
      return nil
    }
    if text.hasSuffix("\n") {
      text.removeLast()
      if text.hasSuffix("\r") {
        text.removeLast()
      }
    }
    return text
  }

  private static func decodeHeader(_ hunk: inout git_diff_hunk) -> String {
    let length = hunk.header_len
    var header = withUnsafeBytes(of: &hunk.header) { rawBuffer -> String in
      let bytes = rawBuffer.prefix(length)
      return String(bytes: bytes, encoding: .utf8) ?? ""
    }
    while header.hasSuffix("\n") || header.hasSuffix("\r") {
      header.removeLast()
    }
    return header
  }

  // MARK: - Status mapping

  private static func makeFileChange(delta: git_diff_delta, result: FileDiffResult) -> FileChange {
    let rawOld = pathString(delta.old_file.path)
    let rawNew = pathString(delta.new_file.path)
    var status = fileStatus(from: delta.status)

    // Submodule gitlink → summary only, no line diff in v1.
    if delta.new_file.mode == UInt16(GIT_FILEMODE_COMMIT.rawValue) {
      status = .submodule
    }
    // A chmod-only change is reported as MODIFIED with a mode delta but no
    // content lines — reclassify it so the UI shows "mode changed".
    if status == .modified,
      delta.old_file.mode != delta.new_file.mode,
      result.addedLines == 0,
      result.removedLines == 0,
      !result.isBinary
    {
      status = .modeChanged
    }
    if result.isBinary {
      status = status == .added || status == .untracked || status == .deleted ? status : .binary
    }

    let oldPath: String?
    let newPath: String?
    switch status {
    case .added, .untracked:
      oldPath = nil
      newPath = rawNew ?? rawOld
    case .deleted:
      oldPath = rawOld ?? rawNew
      newPath = nil
    default:
      oldPath = rawOld
      newPath = rawNew
    }

    return FileChange(
      oldPath: oldPath,
      newPath: newPath,
      status: status,
      addedLines: result.addedLines,
      removedLines: result.removedLines,
      isBinary: result.isBinary,
      isLargeFileCapped: result.isLargeFileCapped,
      hasLongLines: result.hasLongLines,
      similarity: Int(delta.similarity)
    )
  }

  private static func fileStatus(from status: git_delta_t) -> FileStatus {
    switch status {
    case GIT_DELTA_ADDED: return .added
    case GIT_DELTA_DELETED: return .deleted
    case GIT_DELTA_RENAMED: return .renamed
    case GIT_DELTA_COPIED: return .copied
    case GIT_DELTA_TYPECHANGE: return .modeChanged
    case GIT_DELTA_UNTRACKED: return .untracked
    case GIT_DELTA_CONFLICTED: return .conflicted
    default: return .modified
    }
  }

  private static func repositoryOperation(_ repo: OpaquePointer) -> RepositoryOperation {
    // `git_repository_state` returns a C `int`; the state enum's rawValues are
    // UInt32, so compare through Int32.
    let state = git_repository_state(repo)
    switch state {
    case Int32(GIT_REPOSITORY_STATE_MERGE.rawValue):
      return .merge
    case Int32(GIT_REPOSITORY_STATE_REVERT.rawValue), Int32(GIT_REPOSITORY_STATE_REVERT_SEQUENCE.rawValue):
      return .revert
    case Int32(GIT_REPOSITORY_STATE_CHERRYPICK.rawValue), Int32(GIT_REPOSITORY_STATE_CHERRYPICK_SEQUENCE.rawValue):
      return .cherryPick
    case Int32(GIT_REPOSITORY_STATE_BISECT.rawValue):
      return .bisect
    case Int32(GIT_REPOSITORY_STATE_REBASE.rawValue):
      return .rebase
    case Int32(GIT_REPOSITORY_STATE_REBASE_INTERACTIVE.rawValue):
      return .rebaseInteractive
    case Int32(GIT_REPOSITORY_STATE_REBASE_MERGE.rawValue):
      return .rebaseMerge
    case Int32(GIT_REPOSITORY_STATE_APPLY_MAILBOX.rawValue),
      Int32(GIT_REPOSITORY_STATE_APPLY_MAILBOX_OR_REBASE.rawValue):
      return .applyMailbox
    default:
      return .none
    }
  }

  // MARK: - Utilities

  private static func deltaMatches(_ delta: git_diff_delta, file: FileChange) -> Bool {
    let rawOld = pathString(delta.old_file.path)
    let rawNew = pathString(delta.new_file.path)
    let candidateID = rawNew ?? rawOld ?? ""
    return candidateID == file.id || rawNew == file.newPath || rawOld == file.oldPath
  }

  private static func pathString(_ pointer: UnsafePointer<CChar>?) -> String? {
    guard let pointer else { return nil }
    let value = String(cString: pointer)
    return value.isEmpty ? nil : value
  }

  private static func lastError(_ code: Int32) -> DiffError {
    if let errorPtr = git_error_last(), let message = errorPtr.pointee.message {
      return .libgit2(code: code, message: String(cString: message))
    }
    return .libgit2(code: code, message: "unknown libgit2 error")
  }

  // Line-origin bytes, matching git_diff_line_t chars.
  private static let contextChar = CChar(UInt8(ascii: " "))
  private static let additionChar = CChar(UInt8(ascii: "+"))
  private static let deletionChar = CChar(UInt8(ascii: "-"))
  private static let contextEofnlChar = CChar(UInt8(ascii: "="))
  private static let addEofnlChar = CChar(UInt8(ascii: ">"))
  private static let delEofnlChar = CChar(UInt8(ascii: "<"))
}
