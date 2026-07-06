import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

/// Phase 6 — comment persistence (D2): `ReviewComment` Codable + `updatedAt`, the
/// disk-backed per-worktree store, reused `CommentAnchor.relocate` on re-diff,
/// orphan-pinned-never-dropped, and source isolation. PURE (JSON + a temp dir).
@MainActor
struct CommentPersistenceTests {
  private func comment(
    id: UUID = UUID(),
    path: String = "a.swift",
    source: DiffSource = .workingTree,
    side: DiffSide = .new,
    start: Int = 3,
    end: Int = 3,
    snippet: String = "target",
    body: String = "please fix",
    orphaned: Bool = false
  ) -> ReviewComment {
    ReviewComment(
      id: id, filePath: path, source: source, side: side, startLine: start, endLine: end,
      anchorSnippet: snippet, contextBefore: "", body: body, orphaned: orphaned,
      createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 200))
  }

  private func tempStore() -> CommentPersistenceStore {
    let root = FileManager.default.temporaryDirectory.appending(path: "diff-comments-\(UUID().uuidString)")
    return CommentPersistenceStore(root: root)
  }

  // MARK: - C 7.1 — Codable round-trip incl. side / source / orphaned / updatedAt

  @Test func codableRoundTrip() throws {
    let original = comment(
      source: .baseBranch(ref: "origin/main"), side: .old, start: 3, end: 5, snippet: "x\ny", orphaned: true)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ReviewComment.self, from: data)
    #expect(decoded == original)
    #expect(decoded.source == .baseBranch(ref: "origin/main"))
    #expect(decoded.side == .old)
    #expect(decoded.orphaned == true)
    #expect(decoded.updatedAt == Date(timeIntervalSince1970: 200))
  }

  // MARK: - C 7.1 — a payload predating `updatedAt` decodes (defaults to createdAt)

  @Test func codableDecodesLegacyWithoutUpdatedAt() throws {
    // Strip `updatedAt` from a real encoded payload to model data written by a build
    // predating the field (format-agnostic — no hand-rolled JSON).
    let data = try JSONEncoder().encode(comment())
    var dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    dict.removeValue(forKey: "updatedAt")
    let stripped = try JSONSerialization.data(withJSONObject: dict)
    let decoded = try JSONDecoder().decode(ReviewComment.self, from: stripped)
    #expect(decoded.updatedAt == decoded.createdAt)  // default keeps old data valid (D2)
  }

  // MARK: - C 7.2 — disk round-trip, atomic, per worktree

  @Test func diskRoundTripPerWorktree() throws {
    let store = tempStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let comments = [comment(), comment(id: UUID(), start: 10, end: 12)]
    try store.save(worktreeID: "wt-1", comments)
    #expect(FileManager.default.fileExists(atPath: store.fileURL(worktreeID: "wt-1").path))
    #expect(try store.load(worktreeID: "wt-1") == comments)
    // Absent worktree → empty, never an error.
    #expect(try store.load(worktreeID: "never-written") == [])
  }

  // MARK: - C 7.3 — two worktrees write distinct files; one never returns the other's

  @Test func perWorktreeFileKeying() throws {
    let store = tempStore()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let first = [comment(path: "a.swift")]
    let second = [comment(path: "b.swift")]
    try store.save(worktreeID: "wt-A", first)
    try store.save(worktreeID: "wt-B", second)
    #expect(store.fileURL(worktreeID: "wt-A") != store.fileURL(worktreeID: "wt-B"))
    #expect(try store.load(worktreeID: "wt-A") == first)
    #expect(try store.load(worktreeID: "wt-B") == second)
  }

  // MARK: - C 7.4 — re-diff shifts the range via the REUSED CommentAnchor.relocate

  @Test func relocateAcrossReDiff() {
    let original = comment(start: 3, end: 3, snippet: "target")
    // The anchored line moved to new-side line 7.
    let lines =
      (1...6).map { DiffFixture.line(.context, old: $0, new: $0, "ctx\($0)") }
      + [DiffFixture.line(.context, old: 7, new: 7, "target")]
    let relocated = CommentAnchor.relocate(original, in: lines, side: .new)
    #expect(relocated.startLine == 7)
    #expect(relocated.endLine == 7)
    #expect(relocated.orphaned == false)
    #expect(relocated.id == original.id)
  }

  // MARK: - C 7.5 — the anchor vanished ⇒ orphaned, still present, id stable

  @Test func orphanPinnedNotDropped() {
    let original = comment(start: 3, end: 3, snippet: "gone")
    let lines = (1...6).map { DiffFixture.line(.context, old: $0, new: $0, "ctx\($0)") }  // no "gone"
    let relocated = CommentAnchor.relocate(original, in: lines, side: .new)
    #expect(relocated.orphaned == true)  // pinned, never dropped
    #expect(relocated.id == original.id)  // id stable
    #expect(relocated.body == original.body)  // content preserved
  }

  // MARK: - C 7.6 — working-tree vs base-branch comments never cross

  @Test func commentsIsolatedBySource() {
    var state = DiffReviewFeature.State()
    let workingTree = comment(id: UUID(), path: "a.swift", source: .workingTree)
    let base = comment(id: UUID(), path: "a.swift", source: .baseBranch(ref: "main"))
    state.comments = [workingTree, base]
    #expect(state.comments(forPath: "a.swift", source: .workingTree) == [workingTree])
    #expect(state.comments(forPath: "a.swift", source: .baseBranch(ref: "main")) == [base])
  }
}
