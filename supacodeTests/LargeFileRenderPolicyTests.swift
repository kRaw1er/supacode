import Testing

@testable import supacode

/// Phase 13 (C 15.6) — the fully-changed-huge-file gate. Four bands: `>100k` /
/// `isLargeFileCapped` / `>1000`-char line → plain; `>1000` changed / `hasLongLines`
/// → word-diff off; normal → all on. Every gated band carries a `bannerKey` so the
/// header always explains a dropped feature — no silent drop.
struct LargeFileRenderPolicyTests {

  private func file(
    capped: Bool = false,
    hasLongLines: Bool = false,
    status: FileStatus = .modified
  ) -> FileChange {
    FileChange(
      oldPath: "a.txt", newPath: "a.txt", status: status,
      addedLines: 0, removedLines: 0, isBinary: false,
      isLargeFileCapped: capped, hasLongLines: hasLongLines, similarity: 0)
  }

  // MARK: - Band 1: plain (everything off)

  @Test func cappedFileGoesPlain() {
    let decision = LargeFileRenderPolicy.decide(file: file(capped: true), changedLines: 5, maxLineLength: 20)
    #expect(decision == .init(highlight: false, wordDiff: false, bannerKey: .plain))
  }

  @Test func over100kChangedGoesPlain() {
    let decision = LargeFileRenderPolicy.decide(file: file(), changedLines: 100_001, maxLineLength: 20)
    #expect(decision.highlight == false)
    #expect(decision.wordDiff == false)
    #expect(decision.bannerKey == .plain)
  }

  @Test func longSingleLineGoesPlain() {
    // A 2MB minified line (> 1000 UTF-16) → plain, protecting the CTLine byte ceiling.
    let decision = LargeFileRenderPolicy.decide(file: file(), changedLines: 3, maxLineLength: 1_001)
    #expect(decision.bannerKey == .plain)
    #expect(decision.highlight == false)
  }

  // MARK: - Band 2: word-diff off

  @Test func over1000ChangedDropsWordDiffOnly() {
    let decision = LargeFileRenderPolicy.decide(file: file(), changedLines: 1_001, maxLineLength: 40)
    #expect(decision == .init(highlight: true, wordDiff: false, bannerKey: .wordDiffOff))
  }

  @Test func hasLongLinesDropsWordDiffOnly() {
    let decision = LargeFileRenderPolicy.decide(file: file(hasLongLines: true), changedLines: 10, maxLineLength: 200)
    #expect(decision.highlight == true)
    #expect(decision.wordDiff == false)
    #expect(decision.bannerKey == .wordDiffOff)
  }

  // MARK: - Band 3: everything on

  @Test func normalFileAllOn() {
    let decision = LargeFileRenderPolicy.decide(file: file(), changedLines: 1_000, maxLineLength: 1_000)
    #expect(decision == .init(highlight: true, wordDiff: true, bannerKey: nil))
  }

  // MARK: - Boundaries line up with the per-side policies

  @Test func thresholdsMatchPerSidePolicies() {
    #expect(LargeFileRenderPolicy.maxChangedLinesForHighlight == DiffHighlightPolicy.maxChangedLinesPerSide)
    #expect(LargeFileRenderPolicy.maxChangedLinesForWordDiff == WordDiffPolicy.maxChangedLinesPerSide)
    #expect(LargeFileRenderPolicy.maxLineLength == DiffHighlightPolicy.maxLineLength)
  }

  // MARK: - Banner text (no silent drop)

  @Test func bannerKeysCarryHeaderText() {
    #expect(!LargeFileRenderPolicy.BannerKey.plain.headerText.isEmpty)
    #expect(!LargeFileRenderPolicy.BannerKey.wordDiffOff.headerText.isEmpty)
    #expect(!LargeFileRenderPolicy.BannerKey.highlightingOff.headerText.isEmpty)
  }
}
