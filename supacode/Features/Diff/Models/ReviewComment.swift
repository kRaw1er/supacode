import Foundation

/// Which gutter a review comment's line range was drawn on. `.old` is the
/// deletion (pre-image) column; `.new` is the addition / context column.
nonisolated enum DiffSide: String, Codable, Sendable, Equatable {
  case old
  case new
}

/// A single user review note anchored to a line range on one side of a file's
/// diff. Content-anchored (`anchorSnippet` + `contextBefore`) so it survives a
/// live re-diff; on relocation failure it is marked `orphaned`, never deleted
/// (5.1). Persisted from v1 (Phase 6, D2): `Codable` + `updatedAt`, disk-backed
/// per worktree by `CommentPersistenceStore`, load-then-relocate on open.
nonisolated struct ReviewComment: Identifiable, Equatable, Sendable, Codable {
  let id: UUID
  /// New-side path (rename → post-rename path); the grouping key for the
  /// prompt and for scoping a comment to a diff tab.
  var filePath: String
  /// Which diff produced the tab this comment was drawn on. A comment on the
  /// working-tree diff of a file and one on the base-branch diff of the same
  /// file are distinct threads — the `(filePath, source)` pair is the scope key.
  var source: DiffSource

  /// Which gutter the range was drawn on (5.2).
  var side: DiffSide
  /// 1-based line number on `side`, inclusive.
  var startLine: Int
  /// Inclusive; equals `startLine` for a single-line comment.
  var endLine: Int
  /// Exact joined text of the anchored lines at creation (the relocation key).
  var anchorSnippet: String
  /// Up to 3 lines immediately preceding `startLine` (disambiguates dup snippets).
  var contextBefore: String
  /// The user's note. May be empty while composing; empty batch entries are dropped.
  var body: String
  /// Set when relocation fails on re-diff. NEVER deleted implicitly (5.1).
  var orphaned: Bool
  var createdAt: Date
  /// Edit bookkeeping — bumped whenever the body is (re)committed. Defaults to
  /// `createdAt` so a decode of pre-`updatedAt` data (or a fresh comment) stays
  /// valid without a migration (D2).
  var updatedAt: Date

  init(
    id: UUID = UUID(),
    filePath: String,
    source: DiffSource = .workingTree,
    side: DiffSide,
    startLine: Int,
    endLine: Int,
    anchorSnippet: String,
    contextBefore: String,
    body: String = "",
    orphaned: Bool = false,
    createdAt: Date = Date(),
    updatedAt: Date? = nil
  ) {
    self.id = id
    self.filePath = filePath
    self.source = source
    self.side = side
    self.startLine = startLine
    self.endLine = endLine
    self.anchorSnippet = anchorSnippet
    self.contextBefore = contextBefore
    self.body = body
    self.orphaned = orphaned
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
  }

  /// Decode resilience: `updatedAt` is optional in the payload so a JSON written
  /// by a build predating the field decodes cleanly, defaulting to `createdAt`.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(UUID.self, forKey: .id)
    let filePath = try container.decode(String.self, forKey: .filePath)
    let source = try container.decodeIfPresent(DiffSource.self, forKey: .source) ?? .workingTree
    let side = try container.decode(DiffSide.self, forKey: .side)
    let startLine = try container.decode(Int.self, forKey: .startLine)
    let endLine = try container.decode(Int.self, forKey: .endLine)
    let anchorSnippet = try container.decode(String.self, forKey: .anchorSnippet)
    let contextBefore = try container.decode(String.self, forKey: .contextBefore)
    let body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
    let orphaned = try container.decodeIfPresent(Bool.self, forKey: .orphaned) ?? false
    let createdAt = try container.decode(Date.self, forKey: .createdAt)
    let updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    self.init(
      id: id,
      filePath: filePath,
      source: source,
      side: side,
      startLine: startLine,
      endLine: endLine,
      anchorSnippet: anchorSnippet,
      contextBefore: contextBefore,
      body: body,
      orphaned: orphaned,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }
}

extension DiffLine {
  /// The git line number this line carries on `side`, or `nil` when the line
  /// does not exist on that side (an addition has no old number; a deletion has
  /// no new number).
  func lineNumber(on side: DiffSide) -> Int? {
    switch side {
    case .old: oldLineNumber
    case .new: newLineNumber
    }
  }
}
