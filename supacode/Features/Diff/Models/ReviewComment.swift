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
/// (5.1). Session-only: not persisted to disk in v1.
nonisolated struct ReviewComment: Identifiable, Equatable, Sendable {
  let id: UUID
  /// New-side path (rename → post-rename path); the grouping key for the
  /// prompt and for scoping a comment to a diff tab.
  var filePath: String
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

  init(
    id: UUID = UUID(),
    filePath: String,
    side: DiffSide,
    startLine: Int,
    endLine: Int,
    anchorSnippet: String,
    contextBefore: String,
    body: String = "",
    orphaned: Bool = false,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.filePath = filePath
    self.side = side
    self.startLine = startLine
    self.endLine = endLine
    self.anchorSnippet = anchorSnippet
    self.contextBefore = contextBefore
    self.body = body
    self.orphaned = orphaned
    self.createdAt = createdAt
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
