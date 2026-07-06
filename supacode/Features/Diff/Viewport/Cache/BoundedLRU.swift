import Foundation

/// Capacity- and cost-bounded LRU. Not thread-safe by design — every diff side
/// cache is `@MainActor`, so the hot scroll path pays no lock (`NSCache` was
/// rejected: its eviction is non-deterministic — no true LRU, no scroll-off hook —
/// so "evict on scroll-off" and the byte ceiling could not be unit-tested). The
/// count cap mirrors pierre's per-cache `totalASTLRUCacheSize`
/// (`WorkerPoolContext.tsx:30` desktop 100); the cost cap is the byte ceiling gap
/// #1 wants for the CTLine cache.
///
/// The array `order` keeps this readable — `touch` / `demote` are O(n) here; the
/// plan flags an intrusive doubly-linked list as the O(1) follow-up (functional
/// parity, not a correctness risk). Every mutation keeps `store`, `order`, and
/// `totalCost` in lock-step.
@MainActor
struct BoundedLRU<Key: Hashable, Value> {
  private struct Entry {
    var value: Value
    var cost: Int
  }

  private var store: [Key: Entry] = [:]
  /// LRU head (`order.first`, evicted first) … MRU tail (`order.last`, freshest).
  private var order: [Key] = []
  private(set) var totalCost = 0

  /// Hard entry-count cap.
  let countLimit: Int
  /// Byte (cost) ceiling; `.max` disables it. A single oversized insert can still
  /// exceed it transiently, but `evictIfNeeded` drops LRU entries until it holds
  /// (down to the last-inserted key, which is protected as MRU).
  let costLimit: Int

  init(countLimit: Int, costLimit: Int = .max) {
    self.countLimit = max(1, countLimit)
    self.costLimit = max(1, costLimit)
  }

  var count: Int { store.count }
  var isEmpty: Bool { store.isEmpty }

  /// The current LRU→MRU key order (LRU head first). Test/diagnostic surface.
  var orderedKeys: [Key] { order }

  func contains(_ key: Key) -> Bool { store[key] != nil }

  /// Peek WITHOUT bumping recency (diagnostics / tests — the live path uses
  /// `value(forKey:)` which touches).
  func peek(_ key: Key) -> Value? { store[key]?.value }

  /// Fetch + bump recency (the read path). A hit moves the key to the MRU tail so
  /// it survives longer under pressure.
  mutating func value(forKey key: Key) -> Value? {
    guard let entry = store[key] else { return nil }
    touch(key)
    return entry.value
  }

  /// Insert (or overwrite) `value` at `cost`. Overwriting an existing key replaces
  /// its cost accounting, bumps recency, then evicts past either bound.
  mutating func insert(_ value: Value, forKey key: Key, cost: Int = 0) {
    let cost = max(0, cost)
    if let old = store[key] { totalCost -= old.cost }
    store[key] = Entry(value: value, cost: cost)
    totalCost += cost
    touch(key)
    evictIfNeeded()
  }

  /// "Evict on scroll-off" (gap #1): demote the recycled keys to the LRU head so
  /// they drop FIRST under pressure WITHOUT evicting eagerly — a fling-back within
  /// cap is still an instant hit; the byte ceiling / count cap is the real trigger.
  /// Preserves the relative order of the demoted keys.
  mutating func demote(_ keys: some Sequence<Key>) {
    let present = keys.filter { store[$0] != nil }
    guard !present.isEmpty else { return }
    let demoted = Set(present)
    // Keep any already-present demoted keys in the caller's order, drop the rest,
    // then prepend the demoted block at the LRU head.
    order.removeAll { demoted.contains($0) }
    order.insert(contentsOf: present, at: 0)
    evictIfNeeded()
  }

  /// Drop entries (LRU-first) until at most `target` remain — the memory-warning trim.
  mutating func trim(toCount target: Int) {
    let limit = max(0, target)
    while store.count > limit, let lru = order.first { drop(lru) }
  }

  mutating func removeAll() {
    store.removeAll(keepingCapacity: true)
    order.removeAll(keepingCapacity: true)
    totalCost = 0
  }

  @discardableResult
  mutating func removeValue(forKey key: Key) -> Value? {
    guard let entry = store[key] else { return nil }
    drop(key)
    return entry.value
  }

  // MARK: - Order bookkeeping

  private mutating func touch(_ key: Key) {
    order.removeAll { $0 == key }
    order.append(key)
  }

  private mutating func drop(_ key: Key) {
    order.removeAll { $0 == key }
    if let entry = store.removeValue(forKey: key) { totalCost -= entry.cost }
  }

  /// Evict LRU entries while EITHER bound is breached. Never evicts below one
  /// entry for a single over-cost insert (the freshest key is MRU/tail, so the
  /// head is dropped first and the just-inserted key is the last standing).
  @discardableResult
  private mutating func evictIfNeeded() -> Int {
    var evicted = 0
    while store.count > countLimit || totalCost > costLimit, let lru = order.first {
      drop(lru)
      evicted += 1
    }
    return evicted
  }
}
