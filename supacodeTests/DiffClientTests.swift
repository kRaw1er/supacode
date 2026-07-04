import Foundation
import Testing

@testable import supacode

/// Builds real temporary git repositories by shelling `/usr/bin/git`, so the
/// libgit2 binding is exercised against genuine on-disk state (no mocks).
private enum GitFixture {
  enum FixtureError: Error {
    case git(_ args: [String], _ output: String)
  }

  /// Creates a temp dir, `git init`, sets a deterministic identity.
  static func makeRepo() throws -> URL {
    let root = URL.temporaryDirectory.appending(path: "difftest-\(UUID().uuidString)")
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

  static func writeBytes(_ bytes: [UInt8], to rel: String, in root: URL) throws {
    let url = root.appending(path: rel)
    try Data(bytes).write(to: url, options: .atomic)
  }

  static func setPermissions(_ perms: Int, to rel: String, in root: URL) throws {
    let url = root.appending(path: rel)
    try FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path(percentEncoded: false))
  }

  static func stage(_ paths: String..., in root: URL) throws { try run(["add"] + paths, in: root) }
  static func commit(_ msg: String, in root: URL) throws { try run(["commit", "-q", "-m", msg], in: root) }
  static func checkout(_ branch: String, create: Bool = false, in root: URL) throws {
    try run(create ? ["checkout", "-q", "-b", branch] : ["checkout", "-q", branch], in: root)
  }
  static func updateRef(_ ref: String, to revision: String, in root: URL) throws {
    try run(["update-ref", ref, revision], in: root)
  }
  static func head(in root: URL) throws -> String {
    try run(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
  }
  static func rename(_ from: String, _ destination: String, in root: URL) throws {
    try run(["mv", from, destination], in: root)
  }
  static func remove(_ path: String, in root: URL) throws {
    try FileManager.default.removeItem(at: root.appending(path: path))
  }

  static func cleanup(_ root: URL) {
    try? FileManager.default.removeItem(at: root)
  }

  @discardableResult
  static func run(_ args: [String], in root: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/git")
    process.arguments = ["-C", root.path(percentEncoded: false)] + args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else { throw FixtureError.git(args, output) }
    return output
  }
}

@Suite(.serialized)
struct DiffClientTests {
  private func fileChange(_ diff: WorktreeDiff, id: String) -> FileChange? {
    diff.files.first { $0.id == id }
  }

  @Test func addedFileHasAdditionsOnly() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("base\n", to: "base.txt", in: root)
    try GitFixture.stage("base.txt", in: root)
    try GitFixture.commit("init", in: root)
    try GitFixture.write("one\ntwo\nthree\n", to: "new.txt", in: root)
    try GitFixture.stage("new.txt", in: root)

    let diff = try await LibGit2DiffProvider().changedFiles(at: root)
    let change = try #require(fileChange(diff, id: "new.txt"))
    #expect(change.status == .added)
    #expect(change.addedLines == 3)
    #expect(change.removedLines == 0)
    #expect(change.oldPath == nil)
    #expect(change.newPath == "new.txt")
  }

  @Test func modifiedFileCarriesBothLineNumbers() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("a\nb\nc\nd\ne\n", to: "a.txt", in: root)
    try GitFixture.stage("a.txt", in: root)
    try GitFixture.commit("init", in: root)
    try GitFixture.write("a\nb\nX\nd\ne\n", to: "a.txt", in: root)

    let provider = LibGit2DiffProvider()
    let diff = try await provider.changedFiles(at: root)
    let change = try #require(fileChange(diff, id: "a.txt"))
    #expect(change.status == .modified)

    let hunks = try await provider.diff(for: change, at: root)
    let lines = hunks.flatMap(\.lines)
    // A context line has both numbers.
    #expect(lines.contains { $0.origin == .context && $0.oldLineNumber != nil && $0.newLineNumber != nil })
    // A deletion has an old number, no new number.
    #expect(lines.contains { $0.origin == .deletion && $0.oldLineNumber != nil && $0.newLineNumber == nil })
    // An addition has a new number, no old number.
    #expect(lines.contains { $0.origin == .addition && $0.newLineNumber != nil && $0.oldLineNumber == nil })
  }

  @Test func deletedFileHasRemovalsOnly() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("x\ny\nz\n", to: "gone.txt", in: root)
    try GitFixture.stage("gone.txt", in: root)
    try GitFixture.commit("init", in: root)
    try GitFixture.remove("gone.txt", in: root)

    let diff = try await LibGit2DiffProvider().changedFiles(at: root)
    let change = try #require(fileChange(diff, id: "gone.txt"))
    #expect(change.status == .deleted)
    #expect(change.newPath == nil)
    #expect(change.oldPath == "gone.txt")
    #expect(change.removedLines == 3)
  }

  @Test func renamedFileIsDetected() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    let content = (1...20).map { "line \($0)\n" }.joined()
    try GitFixture.write(content, to: "a.txt", in: root)
    try GitFixture.stage("a.txt", in: root)
    try GitFixture.commit("init", in: root)
    try GitFixture.rename("a.txt", "b.txt", in: root)

    let diff = try await LibGit2DiffProvider().changedFiles(at: root)
    let change = try #require(fileChange(diff, id: "b.txt"))
    #expect(change.status == .renamed)
    #expect(change.oldPath == "a.txt")
    #expect(change.newPath == "b.txt")
    #expect(change.similarity >= 60)
  }

  @Test func copiedFileIsDetectedOrFallsBackToAdded() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    let content = (1...20).map { "shared line \($0)\n" }.joined()
    try GitFixture.write(content, to: "a.txt", in: root)
    try GitFixture.stage("a.txt", in: root)
    try GitFixture.commit("init", in: root)
    try GitFixture.write(content, to: "b.txt", in: root)
    try GitFixture.stage("b.txt", in: root)

    let diff = try await LibGit2DiffProvider().changedFiles(at: root)
    let change = try #require(fileChange(diff, id: "b.txt"))
    // libgit2 copy heuristics may classify this as .copied or fall back to
    // .added; both are acceptable outcomes.
    #expect(change.status == .copied || change.status == .added)
  }

  @Test func modeChangeHasNoContentLines() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("script\n", to: "run.sh", in: root)
    try GitFixture.setPermissions(0o644, to: "run.sh", in: root)
    try GitFixture.stage("run.sh", in: root)
    try GitFixture.commit("init", in: root)
    try GitFixture.setPermissions(0o755, to: "run.sh", in: root)

    let provider = LibGit2DiffProvider()
    let diff = try await provider.changedFiles(at: root)
    let change = try #require(fileChange(diff, id: "run.sh"))
    #expect(change.status == .modeChanged)
    #expect(change.addedLines == 0)
    #expect(change.removedLines == 0)
    let hunks = try await provider.diff(for: change, at: root)
    #expect(hunks.flatMap(\.lines).isEmpty)
  }

  @Test func binaryFileIsFlaggedAndYieldsNoHunks() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02, 0x00, 0xFF, 0x10]
    bytes.append(contentsOf: Array(repeating: 0x00, count: 32))
    try GitFixture.writeBytes(bytes, to: "blob.bin", in: root)
    try GitFixture.stage("blob.bin", in: root)
    try GitFixture.commit("init", in: root)
    bytes[5] = 0x77
    try GitFixture.writeBytes(bytes, to: "blob.bin", in: root)

    let provider = LibGit2DiffProvider()
    let diff = try await provider.changedFiles(at: root)
    let change = try #require(fileChange(diff, id: "blob.bin"))
    #expect(change.isBinary)
    let hunks = try await provider.diff(for: change, at: root)
    #expect(hunks.isEmpty)
  }

  @Test func untrackedIncludedAndGitignoreHonored() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("base\n", to: "base.txt", in: root)
    try GitFixture.stage("base.txt", in: root)
    try GitFixture.commit("init", in: root)
    try GitFixture.write("new\n", to: "untracked.txt", in: root)
    try GitFixture.write("secret\n", to: "ignored.txt", in: root)
    try GitFixture.write("ignored.txt\n", to: ".gitignore", in: root)

    let diff = try await LibGit2DiffProvider().changedFiles(at: root)
    let untracked = try #require(fileChange(diff, id: "untracked.txt"))
    #expect(untracked.status == .untracked)
    #expect(fileChange(diff, id: "ignored.txt") == nil)
  }

  @Test func noTrailingNewlineIsPreserved() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("hello", to: "note.txt", in: root)
    try GitFixture.stage("note.txt", in: root)
    try GitFixture.commit("init", in: root)
    try GitFixture.write("hello world", to: "note.txt", in: root)

    let provider = LibGit2DiffProvider()
    let diff = try await provider.changedFiles(at: root)
    let change = try #require(fileChange(diff, id: "note.txt"))
    let hunks = try await provider.diff(for: change, at: root)
    #expect(hunks.flatMap(\.lines).contains { $0.noNewlineAtEof })
  }

  @Test func unbornHeadPresentsFilesAsAdditionLike() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("one\n", to: "one.txt", in: root)
    try GitFixture.write("two\n", to: "two.txt", in: root)

    let diff = try await LibGit2DiffProvider().changedFiles(at: root)
    #expect(diff.isUnbornHead)
    #expect(diff.files.count >= 2)
    #expect(diff.files.allSatisfy { $0.status == .added || $0.status == .untracked })
  }

  @Test func indexLockThrows() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("base\n", to: "base.txt", in: root)
    try GitFixture.stage("base.txt", in: root)
    try GitFixture.commit("init", in: root)
    try GitFixture.write("edit\n", to: "base.txt", in: root)
    let lockURL = root.appending(path: ".git").appending(path: "index.lock")
    try Data().write(to: lockURL)

    await #expect(throws: DiffError.indexLocked) {
      _ = try await LibGit2DiffProvider().changedFiles(at: root)
    }
  }

  @Test func largeFileOverCapIsCappedWithNoHunks() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    let big = String(repeating: "0123456789abcdef\n", count: 200_000)  // ~3.4 MB
    try GitFixture.write(big, to: "big.txt", in: root)
    try GitFixture.stage("big.txt", in: root)
    try GitFixture.commit("init", in: root)
    try GitFixture.write(big + "tail\n", to: "big.txt", in: root)

    let provider = LibGit2DiffProvider()
    let diff = try await provider.changedFiles(at: root)
    let change = try #require(fileChange(diff, id: "big.txt"))
    #expect(change.isLargeFileCapped)
    let hunks = try await provider.diff(for: change, at: root)
    #expect(hunks.isEmpty)
  }

  @Test func nonUTF8FileIsTreatedAsBinary() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("base\n", to: "base.txt", in: root)
    try GitFixture.stage("base.txt", in: root)
    try GitFixture.commit("init", in: root)
    // Invalid UTF-8 with no NUL byte, so libgit2 does not pre-flag it binary.
    try GitFixture.writeBytes([0xFF, 0xFE, 0xFD, 0xFC, 0xFB], to: "weird.dat", in: root)

    let provider = LibGit2DiffProvider()
    let diff = try await provider.changedFiles(at: root)
    let change = try #require(fileChange(diff, id: "weird.dat"))
    #expect(change.isBinary)
    let hunks = try await provider.diff(for: change, at: root)
    #expect(hunks.isEmpty)
  }

  // MARK: - Base-branch (three-dot) source

  /// A committed branch change appears in the base diff; an uncommitted edit
  /// appears only in the working-tree diff. The two sources are independent.
  @Test func baseDiffSeparatesCommittedFromUncommitted() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("base\n", to: "base.txt", in: root)
    try GitFixture.stage("base.txt", in: root)
    try GitFixture.commit("init", in: root)

    try GitFixture.checkout("feature", create: true, in: root)
    try GitFixture.write("feat\n", to: "committed.txt", in: root)
    try GitFixture.stage("committed.txt", in: root)
    try GitFixture.commit("add committed", in: root)
    // An uncommitted change on top — only the working-tree diff should see it.
    try GitFixture.write("dirty\n", to: "dirty.txt", in: root)

    let provider = LibGit2DiffProvider()
    let base = try await provider.changedFiles(source: .baseBranch(ref: "main"), at: root)
    #expect(fileChange(base, id: "committed.txt")?.status == .added)
    #expect(fileChange(base, id: "dirty.txt") == nil)

    let working = try await provider.changedFiles(source: .workingTree, at: root)
    #expect(fileChange(working, id: "dirty.txt")?.status == .untracked)
  }

  /// Load-bearing three-dot assertion: a commit that lands on `main` after the
  /// branch diverged is NOT part of the base diff (merge-base, not `main` tip).
  @Test func baseDiffUsesMergeBaseNotBaseTip() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("base\n", to: "base.txt", in: root)
    try GitFixture.stage("base.txt", in: root)
    try GitFixture.commit("init", in: root)

    try GitFixture.checkout("feature", create: true, in: root)
    try GitFixture.write("feat\n", to: "feature.txt", in: root)
    try GitFixture.stage("feature.txt", in: root)
    try GitFixture.commit("add feature", in: root)

    // A commit that exists only on `main`, after the branch point.
    try GitFixture.checkout("main", in: root)
    try GitFixture.write("main-only\n", to: "main-only.txt", in: root)
    try GitFixture.stage("main-only.txt", in: root)
    try GitFixture.commit("main advances", in: root)
    try GitFixture.checkout("feature", in: root)

    let base = try await LibGit2DiffProvider().changedFiles(source: .baseBranch(ref: "main"), at: root)
    #expect(fileChange(base, id: "feature.txt")?.status == .added)
    // Three-dot: `main`'s new-only file must NOT appear in the branch's changes.
    #expect(fileChange(base, id: "main-only.txt") == nil)
  }

  /// Branch with no commits ahead of base → merge-base == HEAD → zero deltas.
  @Test func baseDiffIsEmptyWhenBranchHasNoCommitsAhead() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("base\n", to: "base.txt", in: root)
    try GitFixture.stage("base.txt", in: root)
    try GitFixture.commit("init", in: root)
    try GitFixture.checkout("feature", create: true, in: root)

    let base = try await LibGit2DiffProvider().changedFiles(source: .baseBranch(ref: "main"), at: root)
    #expect(base.files.isEmpty)
  }

  /// An unresolvable base ref throws `.baseRefUnresolved` (not a crash / libgit2
  /// error) so the reducer can hide the section.
  @Test func baseDiffThrowsWhenRefUnresolvable() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("base\n", to: "base.txt", in: root)
    try GitFixture.stage("base.txt", in: root)
    try GitFixture.commit("init", in: root)

    await #expect(throws: DiffError.baseRefUnresolved) {
      _ = try await LibGit2DiffProvider().changedFiles(source: .baseBranch(ref: "nope/nope"), at: root)
    }
  }

  /// A bare branch name prefers its remote-tracking ref: `origin/main` (older
  /// tip) is chosen over the local `main`, so the base diff spans back to the
  /// remote tip and includes the local-only commit.
  @Test func baseDiffPrefersOriginCandidate() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("base\n", to: "base.txt", in: root)
    try GitFixture.stage("base.txt", in: root)
    try GitFixture.commit("c0", in: root)
    // Pin origin/main at the first commit (the "remote" tip).
    let remoteTip = try GitFixture.head(in: root)
    try GitFixture.updateRef("refs/remotes/origin/main", to: remoteTip, in: root)

    // Advance local main with a commit the remote tip does not have.
    try GitFixture.write("local\n", to: "only-local.txt", in: root)
    try GitFixture.stage("only-local.txt", in: root)
    try GitFixture.commit("c1 local only", in: root)

    try GitFixture.checkout("feature", create: true, in: root)
    try GitFixture.write("feat\n", to: "feature.txt", in: root)
    try GitFixture.stage("feature.txt", in: root)
    try GitFixture.commit("c2 feature", in: root)

    let base = try await LibGit2DiffProvider().changedFiles(source: .baseBranch(ref: "main"), at: root)
    #expect(fileChange(base, id: "feature.txt")?.status == .added)
    // Present only because the base resolved to origin/main (older tip), not the
    // local main which already contains only-local.txt.
    #expect(fileChange(base, id: "only-local.txt")?.status == .added)
  }

  /// Unborn HEAD → nothing committed → empty base diff, no crash.
  @Test func baseDiffOnUnbornHeadIsEmpty() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }

    let base = try await LibGit2DiffProvider().changedFiles(source: .baseBranch(ref: "main"), at: root)
    #expect(base.isUnbornHead)
    #expect(base.files.isEmpty)
  }

  /// A committed rename between merge-base and HEAD is detected as `.renamed`
  /// (proves `find_similar` runs on the base path too).
  @Test func baseDiffDetectsCommittedRename() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    let content = (1...20).map { "line \($0)\n" }.joined()
    try GitFixture.write(content, to: "a.txt", in: root)
    try GitFixture.stage("a.txt", in: root)
    try GitFixture.commit("init", in: root)

    try GitFixture.checkout("feature", create: true, in: root)
    // `git mv` stages the rename itself, so no separate `git add` is needed.
    try GitFixture.rename("a.txt", "b.txt", in: root)
    try GitFixture.commit("rename", in: root)

    let base = try await LibGit2DiffProvider().changedFiles(source: .baseBranch(ref: "main"), at: root)
    let change = try #require(fileChange(base, id: "b.txt"))
    #expect(change.status == .renamed)
    #expect(change.oldPath == "a.txt")
    #expect(change.newPath == "b.txt")
  }
}
