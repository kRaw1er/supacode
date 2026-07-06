import Foundation
import Testing

@testable import supacode

/// Phase 4 — the diff-indirection driver's blob selection (`DiffHighlightDriver`).
/// The pure bucketing arm of the `correctBlobPerDiffSource` regression: the driver
/// buckets the blob the Phase-9 batch already decoded for the selected `DiffSource`
/// — it never re-reads the on-disk working-tree file (bug #1). The GF arm (a real
/// `(oldBlobID, newBlobID)` selection over a temp repo) rides the Phase-9 wave.
@MainActor
struct DiffHighlightDriverTests {

  private enum Fixture {
    static func file(
      _ status: FileStatus, old: String?, new: String?
    ) -> FileChange {
      FileChange(
        oldPath: old, newPath: new, status: status, addedLines: 1, removedLines: 1,
        isBinary: false, isLargeFileCapped: false, hasLongLines: false, similarity: status == .renamed ? 90 : 0)
    }

    static func batch(
      _ file: FileChange,
      oldBlobID: String?, newBlobID: String?,
      oldBlobUTF16: [UInt16]?, newBlobUTF16: [UInt16]?
    ) -> FileDiffBatch {
      FileDiffBatch(
        file: file, hunks: [], unifiedLineCount: 0, splitLineCount: 0,
        oldBlobID: oldBlobID, newBlobID: newBlobID,
        oldBlobUTF16: oldBlobUTF16, newBlobUTF16: newBlobUTF16, generation: 1)
    }

    /// A modified `a.swift`, shaped per source: working-tree's new side is the
    /// (undecoded) workdir; base-branch decodes both the merge-base and tip blobs.
    static func modified(source: DiffSource) -> FileDiffBatch {
      let file = file(.modified, old: "a.swift", new: "a.swift")
      if source.isWorkingTree {
        return batch(
          file, oldBlobID: "head", newBlobID: nil,
          oldBlobUTF16: DiffFixture.blob("let x = 1"), newBlobUTF16: nil)
      }
      return batch(
        file, oldBlobID: "base", newBlobID: "tip",
        oldBlobUTF16: DiffFixture.blob("let x = 1"), newBlobUTF16: DiffFixture.blob("let x = 2"))
    }
  }

  /// 🔴 4.3 (pure arm) — the driver buckets the blob for the selected `DiffSource`:
  /// working-tree → HEAD blob on the old side (workdir on the new side, undecoded);
  /// base-branch → the three-dot merge-base blob AND the branch-tip blob. Keyed off
  /// the BATCH blobs, never a disk read.
  @Test(arguments: [DiffSource.workingTree, DiffSource.baseBranch(ref: "main")])
  func correctBlobPerDiffSource(_ source: DiffSource) {
    let (old, new) = DiffHighlightDriver.blobInputs(for: Fixture.modified(source: source))

    #expect(old?.blobOID == (source.isWorkingTree ? "head" : "base"))
    #expect(old?.path == "a.swift")
    #expect(old?.utf16 == DiffFixture.blob("let x = 1"))
    if source.isWorkingTree {
      #expect(new == nil)  // workdir new side is not decoded into the batch
    } else {
      #expect(new?.blobOID == "tip")
      #expect(new?.path == "a.swift")
    }
  }

  /// A deleted file highlights the OLD side only; the new side is empty.
  @Test func deletedHighlightsOldSideOnly() {
    let batch = Fixture.batch(
      Fixture.file(.deleted, old: "gone.swift", new: nil),
      oldBlobID: "old", newBlobID: nil,
      oldBlobUTF16: DiffFixture.blob("let gone = 0"), newBlobUTF16: nil)
    let (old, new) = DiffHighlightDriver.blobInputs(for: batch)
    #expect(old?.blobOID == "old")
    #expect(old?.path == "gone.swift")
    #expect(new == nil)
  }

  /// An added file highlights the NEW side only; the old side is empty.
  @Test func addedHighlightsNewSideOnly() {
    let batch = Fixture.batch(
      Fixture.file(.added, old: nil, new: "fresh.swift"),
      oldBlobID: nil, newBlobID: "new",
      oldBlobUTF16: nil, newBlobUTF16: DiffFixture.blob("let fresh = 1"))
    let (old, new) = DiffHighlightDriver.blobInputs(for: batch)
    #expect(old == nil)
    #expect(new?.blobOID == "new")
    #expect(new?.path == "fresh.swift")
  }

  /// A rename that changes language keys EACH side on its own blob's path, so the
  /// engine resolves a different grammar per side.
  @Test func renameChangingLanguageKeysEachSideOnItsOwnPath() {
    let batch = Fixture.batch(
      Fixture.file(.renamed, old: "a.swift", new: "b.py"),
      oldBlobID: "swiftBlob", newBlobID: "pyBlob",
      oldBlobUTF16: DiffFixture.blob("let x = 1"), newBlobUTF16: DiffFixture.blob("x = 1"))
    let (old, new) = DiffHighlightDriver.blobInputs(for: batch)
    #expect(old?.path == "a.swift")
    #expect(new?.path == "b.py")
    #expect(GrammarRegistry.grammar(forPath: old!.path)?.queryName == "swift")
    #expect(GrammarRegistry.grammar(forPath: new!.path)?.queryName == "python")
  }
}
