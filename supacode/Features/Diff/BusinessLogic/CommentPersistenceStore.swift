import ComposableArchitecture
import CryptoKit
import Foundation

/// Disk-backed review-comment persistence — ONE JSON file per worktree, keyed by a
/// stable, path-safe hash of the worktree id, written atomically. Comments carry
/// their own `(filePath, source)` scope inside the file, so a single per-worktree
/// document holds every open diff tab's threads. Source of truth stays the reducer
/// `comments`; this is the durable projection loaded-then-relocated on open (D2).
nonisolated struct CommentPersistenceStore: Sendable {
  /// `…/Application Support/supacode/diff-comments/`.
  let root: URL

  init(root: URL? = nil) {
    if let root {
      self.root = root
    } else {
      let base =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL.temporaryDirectory
      self.root = base.appending(path: "supacode/diff-comments", directoryHint: .isDirectory)
    }
  }

  /// A stable, filesystem-safe file name for a worktree id (its SHA-256 hex).
  func fileURL(worktreeID: String) -> URL {
    let digest = SHA256.hash(data: Data(worktreeID.utf8))
    let hex = digest.map { String(format: "%02x", Int($0)) }.joined()
    return root.appending(path: "\(hex).json")
  }

  /// The persisted comments for a worktree, or `[]` when the file is absent.
  func load(worktreeID: String) throws -> [ReviewComment] {
    let url = fileURL(worktreeID: worktreeID)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode([ReviewComment].self, from: data)
  }

  /// Atomically overwrite a worktree's comment document.
  func save(worktreeID: String, _ comments: [ReviewComment]) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(comments)
    try data.write(to: fileURL(worktreeID: worktreeID), options: .atomic)
  }
}

/// The TCA seam: the reducer persists / loads through these `@Sendable` closures so
/// a `TestStore` overrides them with an in-memory double (no disk). `testValue` is
/// a no-op (loads `[]`, ignores saves) so unrelated reducer tests never touch disk.
struct CommentPersistenceStoreClient: Sendable {
  var load: @Sendable (_ worktreeID: String) async -> [ReviewComment]
  var save: @Sendable (_ worktreeID: String, _ comments: [ReviewComment]) async -> Void
}

extension CommentPersistenceStoreClient: DependencyKey {
  static let liveValue: CommentPersistenceStoreClient = {
    let store = CommentPersistenceStore()
    return CommentPersistenceStoreClient(
      load: { worktreeID in (try? store.load(worktreeID: worktreeID)) ?? [] },
      save: { worktreeID, comments in try? store.save(worktreeID: worktreeID, comments) }
    )
  }()

  /// No disk in tests — a test that exercises persistence injects its own
  /// in-memory double capturing saves; everything else sees an inert store.
  static let testValue = CommentPersistenceStoreClient(
    load: { _ in [] },
    save: { _, _ in }
  )
}
