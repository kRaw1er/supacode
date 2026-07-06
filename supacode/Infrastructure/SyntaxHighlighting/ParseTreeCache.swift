import Foundation
import TreeSitterClient

/// LRU of `TreeSitterClient`s keyed by **content identity** `(blobOID, queryName)` —
/// NOT by row position, theme, font, or `styleGeneration`. The client OWNS its parse
/// tree, so this is the parse-tree cache: the base blob parses once and is shared
/// across every worktree diff that references the same commit. An appearance /
/// Dynamic Type / zoom flip bumps the Phase-3 CTLine `styleGeneration` — which is
/// deliberately absent from `Key`, so those flips never invalidate a parse.
///
/// `@MainActor` because `TreeSitterClient` is `@MainActor` and non-`Sendable`
/// (`TreeSitterClient.swift:22-24`).
@MainActor
final class ParseTreeCache {
  struct Key: Hashable {
    let blobOID: String
    let queryName: String
  }

  private var store: [Key: TreeSitterClient] = [:]
  /// MRU order: front == least-recently-used, back == most-recently-used.
  private var order: [Key] = []
  private let capacity: Int

  init(capacity: Int = 24) { self.capacity = max(1, capacity) }

  var count: Int { store.count }

  subscript(key: Key) -> TreeSitterClient? {
    get {
      if store[key] != nil { touch(key) }
      return store[key]
    }
    set {
      guard let newValue else {
        store[key] = nil
        order.removeAll { $0 == key }
        return
      }
      store[key] = newValue
      touch(key)
      while order.count > capacity, let evicted = order.first {
        order.removeFirst()
        store[evicted] = nil
      }
    }
  }

  private func touch(_ key: Key) {
    order.removeAll { $0 == key }
    order.append(key)
  }
}
