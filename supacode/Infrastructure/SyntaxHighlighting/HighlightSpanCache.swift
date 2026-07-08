import Foundation

/// LRU of resolved per-line `StyleRun`s keyed by `(blobOID, queryName, themeGen)`.
/// The blob's spans grow incrementally as windows are queried on scroll, so each
/// entry is a `line → runs` map that new windows union into. `themeGen` is the third
/// key component so a future user-theme swap (`DiffHighlightEngine.bumpSyntaxTheme()`)
/// invalidates spans WITHOUT touching parse trees — the capture strings and line
/// offsets are appearance-independent, only their *colors* change, and those resolve
/// at draw time. `styleGeneration` (appearance / Dynamic Type / zoom) is deliberately
/// absent: it bumps the Phase-3 CTLine cache, never this one.
///
/// `@MainActor` to sit alongside the rest of the highlight engine (mutable state,
/// no cross-actor sharing).
@MainActor
final class HighlightSpanCache {
  struct Key: Hashable {
    let blobOID: String
    let queryName: String
    let themeGen: Int
  }

  private var store: [Key: [Int: [StyleRun]]] = [:]
  /// MRU order: front == least-recently-used, back == most-recently-used.
  private var order: [Key] = []
  private let capacity: Int

  init(capacity: Int = 100) { self.capacity = max(1, capacity) }

  var count: Int { store.count }

  /// The full `line → runs` map cached for `key`, if any (touches LRU on hit).
  subscript(key: Key) -> [Int: [StyleRun]]? {
    if store[key] != nil { touch(key) }
    return store[key]
  }

  /// Unions a freshly-queried window's `line → runs` into the blob's file map,
  /// overwriting the lines the window covers (a re-query of the same window replaces
  /// its runs rather than duplicating them). Creates the entry on first write.
  func merge(_ window: [Int: [StyleRun]], into key: Key) {
    // Mutate the entry IN PLACE via the `default:` subscript. The old `var map =
    // store[key]; map[line] = …; store[key] = map` created a SECOND reference to the
    // entry's storage, so the first mutation COW-copied the WHOLE accumulated map —
    // O(lines-visited-so-far) per merge, growing without bound as a big file is
    // scrolled (a main-actor stall that dragged every diff's scroll fps down).
    for (line, runs) in window {
      store[key, default: [:]][line] = runs
    }
    touch(key)
    while order.count > capacity, let evicted = order.first {
      order.removeFirst()
      store[evicted] = nil
    }
  }

  private func touch(_ key: Key) {
    order.removeAll { $0 == key }
    order.append(key)
  }
}
