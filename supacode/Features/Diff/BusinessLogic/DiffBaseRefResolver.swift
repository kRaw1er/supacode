import Foundation

/// Resolution policy for the base-branch diff's base ref (Phase 2). Fully
/// automatic — there is no Settings UI:
///
/// 1. The PR base (`pullRequest?.baseRefName`, a branch name like `"main"`)
///    when the worktree has an open PR. The Phase-1 `Libgit2Diff.candidates`
///    logic promotes a bare branch name to `origin/<name>` on revparse.
/// 2. Otherwise the repository's automatic base ref via the existing
///    `GitClientDependency.automaticWorktreeBaseRef` (remote HEAD →
///    `preferredBaseRef` → local head, e.g. `"origin/main"`).
/// 3. `nil` when nothing resolves — the reducer hides the base section.
///
/// Caseless `enum` (no top-level free funcs per CLAUDE.md); one pure entry point.
enum DiffBaseRefResolver {
  static func resolve(
    prBaseRefName: String?,
    repositoryRoot: URL,
    gitClient: GitClientDependency
  ) async -> String? {
    if let prBaseRefName, !prBaseRefName.isEmpty {
      return prBaseRefName
    }
    return await gitClient.automaticWorktreeBaseRef(repositoryRoot)
  }
}
