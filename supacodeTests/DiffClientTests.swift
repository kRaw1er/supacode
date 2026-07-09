import Foundation
import Testing

@testable import supacode

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

  // MARK: - Unicode decode boundary (byte-preserving contract)

  /// `decodeContent` must NOT Unicode-normalize. A café blob committed in NFC
  /// (`0x65 0xC3 0xA9`) and edited to NFD (`0x65 0xCC 0x81`) must:
  /// (1) stay decomposed — the added line's scalars carry U+0065 + U+0301 and
  ///     NEVER the precomposed U+00E9;
  /// (2) decode as text (`isBinary == false`), never mis-flagged binary; and
  /// (3) produce a real hunk — NFC and NFD are byte-distinct content, so a
  ///     normalizing decoder would collapse them and silently drop the diff.
  /// This is the exact "symbols break" hazard at the data layer.
  @Test func decodeContentPreservesNFDNotNormalized() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    // "café\n" precomposed (NFC): c a f é(0xC3 0xA9) \n
    try GitFixture.writeBytes([0x63, 0x61, 0x66, 0x65, 0xC3, 0xA9, 0x0A], to: "cafe.txt", in: root)
    try GitFixture.stage("cafe.txt", in: root)
    try GitFixture.commit("init", in: root)
    // "café\n" decomposed (NFD): c a f e(0x65) + combining acute(0xCC 0x81) \n
    try GitFixture.writeBytes([0x63, 0x61, 0x66, 0x65, 0xCC, 0x81, 0x0A], to: "cafe.txt", in: root)

    let provider = LibGit2DiffProvider()
    let diff = try await provider.changedFiles(at: root)
    let change = try #require(fileChange(diff, id: "cafe.txt"))
    #expect(change.status == .modified)
    #expect(change.isBinary == false)

    let hunks = try await provider.diff(for: change, at: root)
    let lines = hunks.flatMap(\.lines)
    // A normalizing decoder would make both sides equal and emit NO hunk.
    #expect(!lines.isEmpty)

    let addition = try #require(lines.first { $0.origin == .addition })
    let addScalars = Set(addition.content.unicodeScalars.map(\.value))
    #expect(addScalars.contains(0x0065))  // base 'e'
    #expect(addScalars.contains(0x0301))  // combining acute
    #expect(!addScalars.contains(0x00E9))  // never precomposed 'é'

    // The deleted side must still carry the precomposed NFC scalar, proving the
    // two byte encodings were preserved distinctly (no normalization on either).
    let deletion = try #require(lines.first { $0.origin == .deletion })
    #expect(deletion.content.unicodeScalars.map(\.value).contains(0x00E9))
  }

  // MARK: - Long-line metadata

  /// A file with a line longer than `longLineCap` (2000) must set
  /// `hasLongLines == true` on its `FileChange`, so the renderer knows to
  /// truncate rather than typeset a multi-thousand-char line (a scroll-hang
  /// cause). A short sibling line must not spuriously flip the flag.
  @Test func longLineSetsHasLongLinesMetadata() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("short\n", to: "wide.txt", in: root)
    try GitFixture.stage("wide.txt", in: root)
    try GitFixture.commit("init", in: root)
    // 3000-character single line — well over the 2000 cap, under byteCap/lineCap.
    let longLine = String(repeating: "a", count: 3_000)
    try GitFixture.write("short\n\(longLine)\n", to: "wide.txt", in: root)

    let provider = LibGit2DiffProvider()
    let diff = try await provider.changedFiles(at: root)
    let change = try #require(fileChange(diff, id: "wide.txt"))
    #expect(change.status == .modified)
    #expect(change.isLargeFileCapped == false)
    #expect(change.hasLongLines)

    // A file whose only change is a short line must NOT report long lines.
    try GitFixture.write("short one\nshort two\n", to: "narrow.txt", in: root)
    try GitFixture.stage("narrow.txt", in: root)
    let diff2 = try await provider.changedFiles(at: root)
    let narrow = try #require(fileChange(diff2, id: "narrow.txt"))
    #expect(narrow.hasLongLines == false)
  }

  // MARK: - Submodule (gitlink) classification

  /// A real gitlink delta (`GIT_FILEMODE_COMMIT` / mode 160000) must classify as
  /// `FileStatus.submodule`. libgit2 surfaces the gitlink as a synthetic
  /// `"Subproject commit <sha>"` summary line — that SHA summary is exactly what
  /// the placeholder renders — and must NOT be followed into the submodule: the
  /// pointed-to repo's own file bodies (`lib.txt` → "lib") never leak into the
  /// diff.
  @Test func submoduleDeltaClassifiedAsSubmodule() async throws {
    let inner = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(inner) }
    try GitFixture.write("lib\n", to: "lib.txt", in: inner)
    try GitFixture.stage("lib.txt", in: inner)
    try GitFixture.commit("inner init", in: inner)
    let innerHead = try GitFixture.head(in: inner)

    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("base\n", to: "base.txt", in: root)
    try GitFixture.stage("base.txt", in: root)
    try GitFixture.commit("init", in: root)
    // Add the local repo as a submodule at `sub` (a staged gitlink, uncommitted
    // so it surfaces as an ADDED gitlink in the working-tree diff). The
    // file-protocol allowance is required for a local-path submodule clone.
    try GitFixture.run(
      ["-c", "protocol.file.allow=always", "submodule", "add", inner.path(percentEncoded: false), "sub"],
      in: root
    )

    let provider = LibGit2DiffProvider()
    let diff = try await provider.changedFiles(at: root)
    let change = try #require(fileChange(diff, id: "sub"))
    #expect(change.status == .submodule)

    let contents = try await provider.diff(for: change, at: root).flatMap(\.lines).map(\.content)
    // Surfaced as a subproject-commit SHA summary, pointing at the inner HEAD.
    #expect(contents.contains { $0.hasPrefix("Subproject commit") && $0.contains(innerHead) })
    // NOT followed: the submodule's own file body never leaks into the diff.
    #expect(!contents.contains { $0.contains("lib") })
  }

  // MARK: - Symlink (diff the target string, never follow)

  /// A changed symlink (mode 120000) must diff its TARGET STRING, not the
  /// content of the file it points at. Repointing `link` from `target-a.txt` to
  /// `target-b.txt` must surface those path strings in the hunk and must NEVER
  /// leak the pointed-to files' bodies.
  @Test func symlinkDiffsTargetStringWithoutFollowing() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    // Distinct bodies so a "followed the link" bug would surface these strings.
    try GitFixture.write("SECRET-BODY-A-DO-NOT-DIFF\n", to: "target-a.txt", in: root)
    try GitFixture.write("SECRET-BODY-B-DO-NOT-DIFF\n", to: "target-b.txt", in: root)
    let linkURL = root.appending(path: "link")
    try FileManager.default.createSymbolicLink(
      atPath: linkURL.path(percentEncoded: false),
      withDestinationPath: "target-a.txt"
    )
    try GitFixture.stage("target-a.txt", "target-b.txt", "link", in: root)
    try GitFixture.commit("init", in: root)

    // Repoint the symlink at the other target (still just a target-string edit).
    try FileManager.default.removeItem(at: linkURL)
    try FileManager.default.createSymbolicLink(
      atPath: linkURL.path(percentEncoded: false),
      withDestinationPath: "target-b.txt"
    )
    // Also touch a regular file so the same diff carries a NON-symlink control row
    // (guards against `isSymlink` being hardwired true for every change).
    try GitFixture.write("SECRET-BODY-A-DO-NOT-DIFF\nmore\n", to: "target-a.txt", in: root)

    let provider = LibGit2DiffProvider()
    let diff = try await provider.changedFiles(at: root)
    let change = try #require(fileChange(diff, id: "link"))
    #expect(change.status == .modified)
    #expect(change.isBinary == false)
    // SpecFlow 2.6: a changed symlink (mode 120000) is flagged so the renderer can
    // say "this diff is the link target, not file bytes". The content behaviour is
    // unchanged — the target-string assertions below still hold.
    #expect(change.isSymlink)
    // A plain (non-symlink) file in the same diff must NOT be flagged.
    #expect(fileChange(diff, id: "target-a.txt")?.isSymlink == false)

    let hunks = try await provider.diff(for: change, at: root)
    let contents = hunks.flatMap(\.lines).map(\.content)
    // The diff is over the target STRINGS, not the pointed-to file bodies.
    #expect(contents.contains { $0.contains("target-a.txt") })
    #expect(contents.contains { $0.contains("target-b.txt") })
    #expect(!contents.contains { $0.contains("SECRET-BODY") })
  }

  // MARK: - #1/#3 — submodule SHAs + mode octals surfaced on FileChange

  /// A pure chmod (644 → 755) is reclassified `.modeChanged` and carries the concrete
  /// octal modes so the placeholder renders `100644 → 100755` (not the generic branch).
  @Test func chmodOnlyChangeCarriesOctalModes() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.run(["config", "core.fileMode", "true"], in: root)
    try GitFixture.write("#!/bin/sh\necho hi\n", to: "run.sh", in: root)
    try GitFixture.setPermissions(0o644, to: "run.sh", in: root)
    try GitFixture.stage("run.sh", in: root)
    try GitFixture.commit("init", in: root)
    try GitFixture.setPermissions(0o755, to: "run.sh", in: root)  // executable bit only

    let change = try #require(fileChange(try await LibGit2DiffProvider().changedFiles(at: root), id: "run.sh"))
    #expect(change.status == .modeChanged)
    #expect(change.oldMode == "100644")
    #expect(change.newMode == "100755")
  }

  /// A real submodule pointer change (sha1 → sha2) is classified `.submodule` and
  /// carries both commit SHAs so the placeholder renders `Subproject commit …`.
  @Test func submoduleChangeCarriesCommitSHAs() async throws {
    let inner = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(inner) }
    try GitFixture.write("one\n", to: "a.txt", in: inner)
    try GitFixture.stage("a.txt", in: inner)
    try GitFixture.commit("c1", in: inner)
    let sha1 = try GitFixture.head(in: inner)

    let outer = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(outer) }
    // Local-path submodule add / fetch require the file-protocol allowance on modern git.
    try GitFixture.run(
      ["-c", "protocol.file.allow=always", "submodule", "add", inner.path(percentEncoded: false), "sub"], in: outer)
    try GitFixture.commit("add sub", in: outer)

    // Advance inner, then move the checked-out submodule HEAD forward so the OUTER
    // working tree shows the gitlink pointer change sha1 → sha2.
    try GitFixture.write("two\n", to: "b.txt", in: inner)
    try GitFixture.stage("b.txt", in: inner)
    try GitFixture.commit("c2", in: inner)
    let sha2 = try GitFixture.head(in: inner)
    let subDir = outer.appending(path: "sub")
    try GitFixture.run(["-c", "protocol.file.allow=always", "fetch", "-q"], in: subDir)
    try GitFixture.run(["checkout", "-q", sha2], in: subDir)

    let change = try #require(fileChange(try await LibGit2DiffProvider().changedFiles(at: outer), id: "sub"))
    #expect(change.status == .submodule)
    #expect(change.oldSubmoduleSHA == sha1)
    #expect(change.newSubmoduleSHA == sha2)
  }

  // MARK: - #20 — ignoreWhitespace threaded through the production `diff` path

  /// A whitespace-only edit yields a hunk with the flag OFF and ZERO hunks with it ON,
  /// proving the toggle reaches `GIT_DIFF_IGNORE_WHITESPACE` through `DiffProvider.diff`
  /// (the production, non-streaming load path).
  @Test func ignoreWhitespaceThreadedThroughDiffPath() async throws {
    let root = try GitFixture.makeRepo()
    defer { GitFixture.cleanup(root) }
    try GitFixture.write("hello world\nfoo\n", to: "indent.txt", in: root)
    try GitFixture.stage("indent.txt", in: root)
    try GitFixture.commit("init", in: root)
    try GitFixture.write("  hello world\nfoo\n", to: "indent.txt", in: root)  // indentation only

    let provider = LibGit2DiffProvider()
    let change = try #require(fileChange(try await provider.changedFiles(at: root), id: "indent.txt"))
    let withFlagOff = try await provider.diff(for: change, at: root, ignoreWhitespace: false)
    #expect(!withFlagOff.isEmpty)  // a real hunk without the flag
    let withFlagOn = try await provider.diff(for: change, at: root, ignoreWhitespace: true)
    #expect(withFlagOn.isEmpty)  // whitespace-only change drops out with the flag
  }
}
