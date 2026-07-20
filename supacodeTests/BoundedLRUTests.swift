import Testing

@testable import supacode

/// Phase 13 — the shared bounded-LRU primitive every diff side cache is built on
/// (`C 15.1 / 15.2 / 15.7`). Count-cap eviction is LRU; the byte ceiling holds; a
/// `value(forKey:)` hit bumps recency; an `insert` over an existing key re-accounts
/// cost; `demote` moves recycled keys to the head so they drop first under pressure;
/// unbounded inserts stay bounded (leaks category).
@MainActor
struct BoundedLRUTests {

  // MARK: - Count-cap eviction (C 15.1)

  @Test func countCapEvictsInLRUOrder() {
    var lru = BoundedLRU<Int, String>(countLimit: 3)
    lru.insert("a", forKey: 1)
    lru.insert("b", forKey: 2)
    lru.insert("c", forKey: 3)
    #expect(lru.count == 3)
    // Over cap ⇒ the LRU head (key 1) is evicted.
    lru.insert("d", forKey: 4)
    #expect(lru.count == 3)
    #expect(!lru.contains(1))  // LRU-evicted
    #expect(lru.contains(2))
    #expect(lru.contains(4))
    #expect(lru.orderedKeys == [2, 3, 4])
  }

  @Test func valueForKeyBumpsRecency() {
    var lru = BoundedLRU<Int, String>(countLimit: 3)
    lru.insert("a", forKey: 1)
    lru.insert("b", forKey: 2)
    lru.insert("c", forKey: 3)
    // Touch key 1 (now MRU); the next over-cap insert evicts key 2 (the new LRU).
    #expect(lru.value(forKey: 1) == "a")
    #expect(lru.orderedKeys == [2, 3, 1])
    lru.insert("d", forKey: 4)
    #expect(!lru.contains(2))  // 2 was the LRU after 1 was bumped
    #expect(lru.contains(1))
  }

  @Test func insertOverExistingKeyUpdatesCost() {
    var lru = BoundedLRU<Int, String>(countLimit: 8, costLimit: 1_000)
    lru.insert("a", forKey: 1, cost: 100)
    #expect(lru.totalCost == 100)
    // Overwrite the same key with a larger cost ⇒ old cost removed, new counted.
    lru.insert("A", forKey: 1, cost: 250)
    #expect(lru.count == 1)
    #expect(lru.totalCost == 250)
    #expect(lru.peek(1) == "A")
  }

  // MARK: - Byte ceiling (C 15.2)

  @Test func byteCeilingEvictsOldestAndNeverExceeds() {
    var lru = BoundedLRU<Int, String>(countLimit: 100, costLimit: 300)
    lru.insert("a", forKey: 1, cost: 100)
    lru.insert("b", forKey: 2, cost: 100)
    lru.insert("c", forKey: 3, cost: 100)
    #expect(lru.totalCost == 300)
    // A 4th 100-cost entry breaches 300 ⇒ oldest (key 1) evicted, ceiling holds.
    lru.insert("d", forKey: 4, cost: 100)
    #expect(lru.totalCost <= 300)
    #expect(lru.totalCost == 300)
    #expect(!lru.contains(1))
    #expect(lru.contains(4))
  }

  // MARK: - Demote / evict-on-scroll-off (C 15.3 primitive)

  @Test func demoteMovesToHeadAndDropsFirst() {
    var lru = BoundedLRU<Int, String>(countLimit: 4)
    for key in 1...4 { lru.insert("v\(key)", forKey: key) }
    // Demote the freshest two (3, 4) — recycled rows scrolled off. They move to the
    // LRU head, preserving their relative order, WITHOUT eager eviction (still cap 4).
    lru.demote([3, 4])
    #expect(lru.count == 4)
    #expect(lru.orderedKeys == [3, 4, 1, 2])
    // The next over-cap insert drops the demoted head (3) first.
    lru.insert("v5", forKey: 5)
    #expect(!lru.contains(3))
    #expect(lru.contains(1))
    #expect(lru.contains(4))
  }

  // MARK: - Unbounded-growth guard (C 15.7 — leaks category)

  @Test func unboundedGrowthGuard() {
    var lru = BoundedLRU<Int, Int>(countLimit: 50, costLimit: 5_000)
    for key in 0..<10_000 {
      lru.insert(key, forKey: key, cost: 100)
      #expect(lru.count <= 50)
      #expect(lru.totalCost <= 5_000)
    }
    #expect(lru.count == 50)
    #expect(lru.totalCost <= 5_000)
  }

  // MARK: - trim / removeAll

  @Test func trimAndRemoveAll() {
    var lru = BoundedLRU<Int, String>(countLimit: 10)
    for key in 1...6 { lru.insert("v\(key)", forKey: key) }
    lru.trim(toCount: 2)
    #expect(lru.count == 2)
    #expect(lru.orderedKeys == [5, 6])  // the two freshest survive
    lru.removeAll()
    #expect(lru.isEmpty)
    #expect(lru.totalCost == 0)
  }

  // MARK: - Perf guard: a hit is O(1), NOT O(cache size)

  /// The scroll-fps regression: `touch` was `order.removeAll { $0 == key }` — O(cache
  /// size) on EVERY hit — so a full CTLine cache cost ~O(cache) per visible row per
  /// frame, degrading scroll as the cache filled. With the intrusive doubly-linked
  /// list a hit is O(1). 50k hits on a full 4000-entry cache is a few ms at O(1); the
  /// old O(n) path is ~2×10^8 element scans + array shifts (seconds), so the large
  /// margin catches the regression without being machine-fragile.
  @Test func hitIsConstantTimeNotLinearInCacheSize() {
    var lru = BoundedLRU<Int, Int>(countLimit: 4_000)
    for key in 0..<4_000 { lru.insert(key, forKey: key) }
    let elapsed = ContinuousClock().measure {
      for iteration in 0..<50_000 { _ = lru.value(forKey: iteration % 4_000) }
    }
    let millis = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    #expect(millis < 1_000, "50k cache hits took \(millis)ms — `touch` is O(cache size) again, not O(1)")
  }
}
