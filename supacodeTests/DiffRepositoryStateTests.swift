import Foundation
import Testing

@testable import supacode

/// Phase 6 (1.8): confirms the Phase 1 `LibGit2DiffProvider` binds
/// `git_repository_state` onto `WorktreeDiff.operation` and surfaces conflicted
/// files as `FileStatus.conflicted`. Uses real on-disk git repos left mid-merge /
/// mid-rebase (shelling `/usr/bin/git`) so the libgit2 binding is exercised for
/// genuine state, not mocked.
private enum RepoStateFixture {
  enum FixtureError: Error {
    case git(_ args: [String], _ output: String)
  }

  static func makeRepo() throws -> URL {
    let root = URL.temporaryDirectory.appending(path: "repostate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try run(["init", "-q", "-b", "main"], in: root)
    try run(["config", "user.email", "t@t.dev"], in: root)
    try run(["config", "user.name", "T"], in: root)
    try run(["config", "commit.gpgsign", "false"], in: root)
    return root
  }

  static func write(_ text: String, to rel: String, in root: URL) throws {
    let url = root.appending(path: rel)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(text.utf8).write(to: url, options: .atomic)
  }

  static func cleanup(_ root: URL) {
    try? FileManager.default.removeItem(at: root)
  }

  /// Builds two divergent branches that both edit the same line of `conflict.txt`,
  /// leaving the working tree on `main`. Returns the repo root.
  static func makeConflictingBranches() throws -> URL {
    let root = try makeRepo()
    try write("original\n", to: "conflict.txt", in: root)
    try run(["add", "conflict.txt"], in: root)
    try run(["commit", "-q", "-m", "init"], in: root)
    try run(["checkout", "-q", "-b", "feature"], in: root)
    try write("feature change\n", to: "conflict.txt", in: root)
    try run(["add", "conflict.txt"], in: root)
    try run(["commit", "-q", "-m", "feature"], in: root)
    try run(["checkout", "-q", "main"], in: root)
    try write("main change\n", to: "conflict.txt", in: root)
    try run(["add", "conflict.txt"], in: root)
    try run(["commit", "-q", "-m", "main"], in: root)
    return root
  }

  @discardableResult
  static func run(_ args: [String], in root: URL) throws -> String {
    let (output, status) = try invoke(args, in: root)
    guard status == 0 else { throw FixtureError.git(args, output) }
    return output
  }

  /// Runs a git command that is expected to fail on conflict (merge / rebase),
  /// swallowing the non-zero status so the repo is left mid-operation.
  static func runAllowingFailure(_ args: [String], in root: URL) throws {
    _ = try invoke(args, in: root)
  }

  private static func invoke(_ args: [String], in root: URL) throws -> (output: String, status: Int32) {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/git")
    process.arguments = ["-C", root.path(percentEncoded: false)] + args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (output, process.terminationStatus)
  }
}

@Suite(.serialized)
struct DiffRepositoryStateTests {
  @Test func cleanRepositoryReportsNoOperation() async throws {
    let root = try RepoStateFixture.makeRepo()
    defer { RepoStateFixture.cleanup(root) }
    try RepoStateFixture.write("base\n", to: "base.txt", in: root)
    try RepoStateFixture.run(["add", "base.txt"], in: root)
    try RepoStateFixture.run(["commit", "-q", "-m", "init"], in: root)

    let diff = try await LibGit2DiffProvider().changedFiles(at: root)
    #expect(diff.operation == .none)
  }

  @Test func midMergeReportsMergeOperationAndConflictedFile() async throws {
    let root = try RepoStateFixture.makeConflictingBranches()
    defer { RepoStateFixture.cleanup(root) }
    try RepoStateFixture.runAllowingFailure(["merge", "feature"], in: root)

    let diff = try await LibGit2DiffProvider().changedFiles(at: root)
    #expect(diff.operation == .merge)
    #expect(diff.files.contains { $0.status == .conflicted })
  }

  @Test func midRebaseReportsRebaseFamilyOperation() async throws {
    let root = try RepoStateFixture.makeConflictingBranches()
    defer { RepoStateFixture.cleanup(root) }
    // Rebase feature onto main's divergent tip → conflict, leaving a rebase dir.
    try RepoStateFixture.runAllowingFailure(["checkout", "-q", "feature"], in: root)
    try RepoStateFixture.runAllowingFailure(["rebase", "main"], in: root)

    let diff = try await LibGit2DiffProvider().changedFiles(at: root)
    let rebaseFamily: Set<RepositoryOperation> = [.rebase, .rebaseInteractive, .rebaseMerge]
    #expect(rebaseFamily.contains(diff.operation))
  }
}
