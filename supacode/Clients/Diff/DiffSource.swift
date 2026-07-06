import Foundation

/// Discriminates which diff a `DiffProvider` / `DiffClient` call materializes.
///
/// - `.workingTree`: the uncommitted working-tree diff (`git diff HEAD` +
///   untracked) — the original, unchanged source.
/// - `.baseBranch(ref:)`: the branch's committed changes vs its base, using
///   three-dot merge-base semantics (`merge-base(base, HEAD)..HEAD`), matching
///   GitHub / Orca "Files changed". `ref` is the caller-supplied base spec — a
///   branch name like `"main"` (from a PR base) or a remote ref like
///   `"origin/main"` (from `automaticWorktreeBaseRef`).
///
/// Identity / dedup / comment-scope use the whole case, so `ref` participates.
nonisolated enum DiffSource: Equatable, Sendable, Hashable {
  case workingTree
  case baseBranch(ref: String)

  /// `true` for the uncommitted working-tree diff, whose NEW side is the workdir
  /// (a zero OID, not a blob) — so the streaming walk skips decoding the new-side
  /// blob for it and reuse keys on `oldBlobID`.
  var isWorkingTree: Bool {
    if case .workingTree = self { return true }
    return false
  }

  /// Human-facing label for titles / section headers — `nil` for the
  /// working-tree source; the base ref with a leading `origin/` stripped.
  var displayName: String? {
    switch self {
    case .workingTree:
      return nil
    case .baseBranch(let ref):
      return ref.hasPrefix("origin/") ? String(ref.dropFirst("origin/".count)) : ref
    }
  }
}
