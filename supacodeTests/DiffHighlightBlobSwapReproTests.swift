import AppKit
import CoreText
import Testing

@testable import supacode

/// Regression guard for the "плавающая каша" bug found 2026-07-11 via the in-app
/// `SUPACODE_DIFF_HL_DIAG` dump: a REUSED `DiffViewportController` painted a newly-applied
/// file's text with the PREVIOUS file's syntax runs. The fix is per-`fileID` blob
/// resolution — each leaf resolves ITS OWN file's blobs (`highlightBlobsByFile[segment
/// .hunkID.fileID]`), so a stale entry for another file can never colour it — plus the
/// atomic `applyDocument` swap. Two files with DISJOINT capture shapes (file B is all
/// strings, file A is all comments) make any cross-contamination loud.
@MainActor
struct DiffHighlightBlobSwapReproTests {
  private static let query = "swift"
  private static let fileB = (1...20).map { "let value\($0) = \"string \($0) here now\"" }  // string runs
  private static let fileA = (1...20).map { "// plain comment line number \($0) of text" }  // comment runs only

  private func tree(_ lines: [String], fileID: String) -> ChunkTree {
    let tree = ChunkTree(metrics: .production)
    let hunkID = HunkID(fileID: fileID, index: 0)
    let diffLines = lines.enumerated().map { index, text in
      DiffLine(
        origin: .context, oldLineNumber: index + 1, newLineNumber: index + 1, content: text, noNewlineAtEof: false)
    }
    var after: ChunkID?
    for index in diffLines.indices {
      after = tree.insert(
        .lineSegment(
          LineSegment(hunkID: hunkID, lines: diffLines, window: index..<(index + 1), classification: .context)),
        after: after)
    }
    return tree
  }

  private func blob(_ oid: String, _ lines: [String]) -> HighlightBlobInput {
    HighlightBlobInput(blobOID: oid, utf16: DiffFixture.blob(lines.joined(separator: "\n") + "\n"), path: "F.swift")
  }

  /// Every materialized row's drawn glyphs, classified: `.plain` (base colour only),
  /// `.justified` (coloured by `expectedOID`'s runs for its blob line), or an offender
  /// string (coloured by SOME OTHER blob — the cross-file bleed).
  private func offenders(_ controller: DiffViewportController, expectedOID: String) -> [String] {
    let base = DiffPalette.shared.codeForeground.cgColor
    var out: [String] = []
    for view in controller.documentView.subviews.compactMap({ $0 as? LineRowView }) {
      for render in view.typesetRowRenders {
        guard let content = render.content, let number = render.newNumber, let ctLine = render.ctLines.first else {
          continue
        }
        let expected = controller.highlightEngine.cachedRuns(
          blobOID: expectedOID, queryName: Self.query, blobLine: number - 1)
        let length = (content as NSString).length
        for index in 0..<length {
          guard let drawn = CTRunColorProbe.foreground(ctLine, at: index) else { continue }
          if CTRunColorProbe.sameColor(drawn, base) { continue }
          let justified = expected.contains { run in
            run.range.contains(index)
              && CTRunColorProbe.sameColor(HighlightTheme.color(for: run.capture).cgColor, drawn)
          }
          if !justified {
            out.append("\(expectedOID) line \(number) col \(index) \"\(content)\"")
            break
          }
        }
      }
    }
    return out
  }

  /// PER-FILE ISOLATION: with only file B's blob registered, applying file A's tree (a reused
  /// controller mid-switch) must render file A PLAIN — a leaf resolves its OWN `fileID`, so
  /// file B's warmed STRING runs can never bleed onto file A's comment text. Before the fix
  /// (single controller-wide blob slot) this painted file A in file B's colours.
  @Test func leafResolvesOwnFileBlobNeverAnotherFiles() async {
    let engine = DiffHighlightEngine()
    let controller = ViewportTestSupport.controller(width: 4000, clipHeight: 400)
    controller.highlightEngine = engine

    controller.applyDocument(
      tree: tree(Self.fileB, fileID: "fileB"), mode: .unified, fileID: "fileB",
      blobs: .init(old: nil, new: blob("B", Self.fileB), disabled: false), scrollPreserving: false)
    await controller.highlightWarmTask?.value

    // The reused controller now shows file A's tree; only file B's blob is registered.
    controller.apply(tree: tree(Self.fileA, fileID: "fileA"), mode: .unified, scrollPreserving: false)
    await controller.highlightWarmTask?.value

    // No file-A glyph is coloured by file B (it resolves fileID "fileA" → no blob → plain).
    #expect(offenders(controller, expectedOID: "A").isEmpty, "file B's runs must never colour file A")
  }

  /// ATOMIC SWAP: `applyDocument` registers the new file's blob (keyed by its `fileID`)
  /// BEFORE `apply` lays out, so switching to file A colours it from A's OWN runs — never a
  /// stale frame in another file's colours, before OR after the warm.
  @Test func applyDocumentSwapsBlobAtomicallyNoStaleColors() async {
    let engine = DiffHighlightEngine()
    let controller = ViewportTestSupport.controller(width: 4000, clipHeight: 400)
    controller.highlightEngine = engine

    controller.applyDocument(
      tree: tree(Self.fileB, fileID: "fileB"), mode: .unified, fileID: "fileB",
      blobs: .init(old: nil, new: blob("B", Self.fileB), disabled: false), scrollPreserving: false)
    await controller.highlightWarmTask?.value

    controller.applyDocument(
      tree: tree(Self.fileA, fileID: "fileA"), mode: .unified, fileID: "fileA",
      blobs: .init(old: nil, new: blob("A", Self.fileA), disabled: false), scrollPreserving: false)
    // Even BEFORE the warm completes, the paint must never carry B's runs (plain at worst).
    #expect(offenders(controller, expectedOID: "A").isEmpty, "no stale colors immediately after atomic swap")

    await controller.highlightWarmTask?.value
    #expect(offenders(controller, expectedOID: "A").isEmpty, "no stale colors after file A warms")
  }
}
