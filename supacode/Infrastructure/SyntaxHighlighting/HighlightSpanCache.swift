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
  /// The blob lines a warm has ALREADY QUERIED (0-based), tracked separately from the
  /// runs map: a line that was queried but produced no tokens has NO entry in `store`,
  /// yet it is NOT missing — re-querying it forever is the runaway warm→repaint loop.
  /// `missingRanges` reads THIS, not `store`, so the warmer converges.
  private var coveredStore: [Key: IndexSet] = [:]
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

  /// Record `lines` as QUERIED for `key` (independent of whether they yielded tokens).
  /// The warmer marks the full requested range covered — even lines past the blob end or
  /// with no tokens — so `missingRanges` never re-reports them and the warm converges.
  func markCovered(_ lines: Range<Int>, for key: Key) {
    guard !lines.isEmpty else { return }
    coveredStore[key, default: IndexSet()].insert(integersIn: lines)
    touch(key)
    evict()
  }

  /// The coalesced sub-ranges of `lines` NOT yet covered (queried) for `key` — the gaps
  /// the warmer must still query. All covered ⇒ `[]`; nothing covered ⇒ `[lines]`.
  func missingRanges(_ lines: Range<Int>, for key: Key) -> [Range<Int>] {
    guard !lines.isEmpty else { return [] }
    guard let covered = coveredStore[key] else { return [lines] }
    var ranges: [Range<Int>] = []
    var runStart: Int?
    for line in lines {
      if covered.contains(line) {
        if let start = runStart {
          ranges.append(start..<line)
          runStart = nil
        }
      } else if runStart == nil {
        runStart = line
      }
    }
    if let start = runStart { ranges.append(start..<lines.upperBound) }
    return ranges
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
    evict()
  }

  private func touch(_ key: Key) {
    order.removeAll { $0 == key }
    order.append(key)
  }

  /// Drop least-recently-used entries past `capacity` from BOTH the runs and covered maps.
  private func evict() {
    while order.count > capacity, let evicted = order.first {
      order.removeFirst()
      store[evicted] = nil
      coveredStore[evicted] = nil
    }
  }
}
