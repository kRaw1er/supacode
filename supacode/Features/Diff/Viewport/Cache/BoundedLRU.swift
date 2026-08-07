import Foundation

/// Capacity- and cost-bounded LRU. Not thread-safe by design — every diff side
/// cache is `@MainActor`, so the hot scroll path pays no lock (`NSCache` was
/// rejected: its eviction is non-deterministic — no true LRU, no scroll-off hook —
/// so "evict on scroll-off" and the byte ceiling could not be unit-tested). The
/// count cap mirrors pierre's per-cache `totalASTLRUCacheSize`
/// (`WorkerPoolContext.tsx:30` desktop 100); the cost cap is the byte ceiling gap
/// #1 wants for the CTLine cache.
///
/// Recency is an intrusive doubly-linked list over the keys (`head` == LRU/evict
/// first, `tail` == MRU/freshest), threaded through the `prevKey` / `nextKey`
/// dictionaries so `touch` / `value(forKey:)` / `insert` / `drop` are all **O(1)** —
/// NOT the old array `order.removeAll { $0 == key }`, which was O(n) on EVERY cache
/// hit and made a full CTLine cache (4000 entries) cost ~O(cache) per visible row
/// per frame (the scroll-fps-degrades-as-the-cache-fills stall). `orderedKeys`
/// (diagnostics/tests) walks the list in O(n); `demote` / `trim` / `evictIfNeeded`
/// are O(#affected). Every mutation keeps `store`, the list, and `totalCost` in
/// lock-step.
@MainActor
struct BoundedLRU<Key: Hashable, Value> {
  private struct Entry {
    var value: Value
    var cost: Int
  }

  private var store: [Key: Entry] = [:]
  /// Intrusive doubly-linked recency list: `head` == LRU (evicted first), `tail` ==
  /// MRU (freshest). A key is "linked" iff `store[key] != nil`.
  private var head: Key?
  private var tail: Key?
  private var prevKey: [Key: Key] = [:]
  private var nextKey: [Key: Key] = [:]
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

  /// The current LRU→MRU key order (LRU head first). Test/diagnostic surface — O(n).
  var orderedKeys: [Key] {
    var out: [Key] = []
    out.reserveCapacity(store.count)
    var cursor = head
    while let key = cursor {
      out.append(key)
      cursor = nextKey[key]
    }
    return out
  }

  func contains(_ key: Key) -> Bool { store[key] != nil }

  /// Peek WITHOUT bumping recency (diagnostics / tests — the live path uses
  /// `value(forKey:)` which touches).
  func peek(_ key: Key) -> Value? { store[key]?.value }

  /// Fetch + bump recency (the read path). A hit moves the key to the MRU tail so
  /// it survives longer under pressure. O(1).
  mutating func value(forKey key: Key) -> Value? {
    guard let entry = store[key] else { return nil }
    moveToTail(key)
    return entry.value
  }

  /// Insert (or overwrite) `value` at `cost`. Overwriting an existing key replaces
  /// its cost accounting, bumps recency, then evicts past either bound. O(1) amortized.
  mutating func insert(_ value: Value, forKey key: Key, cost: Int = 0) {
    let cost = max(0, cost)
    if let old = store[key] { totalCost -= old.cost }
    store[key] = Entry(value: value, cost: cost)
    totalCost += cost
    moveToTail(key)
    evictIfNeeded()
  }

  /// "Evict on scroll-off" (gap #1): demote the recycled keys to the LRU head so
  /// they drop FIRST under pressure WITHOUT evicting eagerly — a fling-back within
  /// cap is still an instant hit; the byte ceiling / count cap is the real trigger.
  /// Preserves the relative order of the demoted keys (`present[0]` becomes the LRU
  /// head). O(#demoted).
  mutating func demote(_ keys: some Sequence<Key>) {
    let present = keys.filter { store[$0] != nil }
    guard !present.isEmpty else { return }
    // Unlink all, then re-insert at the head preserving the caller's order so
    // `present[0]` ends up the LRU-most (matches the old `order.insert(…, at: 0)`).
    for key in present { unlink(key) }
    for key in present.reversed() { prependToHead(key) }
    evictIfNeeded()
  }

  /// Drop entries (LRU-first) until at most `target` remain — the memory-warning trim.
  mutating func trim(toCount target: Int) {
    let limit = max(0, target)
    while store.count > limit, let lru = head { drop(lru) }
  }

  mutating func removeAll() {
    store.removeAll(keepingCapacity: true)
    prevKey.removeAll(keepingCapacity: true)
    nextKey.removeAll(keepingCapacity: true)
    head = nil
    tail = nil
    totalCost = 0
  }

  @discardableResult
  mutating func removeValue(forKey key: Key) -> Value? {
    guard let entry = store[key] else { return nil }
    drop(key)
    return entry.value
  }

  // MARK: - Order bookkeeping (intrusive doubly-linked list, O(1))

  /// Whether `key` is currently threaded into the recency list.
  private func isLinked(_ key: Key) -> Bool {
    head == key || prevKey[key] != nil || nextKey[key] != nil
  }

  /// Detach `key` from the list (O(1)); no-op if it is not linked.
  private mutating func unlink(_ key: Key) {
    guard isLinked(key) else { return }
    let prev = prevKey[key]
    let next = nextKey[key]
    if let prev { nextKey[prev] = next } else if head == key { head = next }
    if let next { prevKey[next] = prev } else if tail == key { tail = prev }
    prevKey[key] = nil
    nextKey[key] = nil
  }

  private mutating func appendToTail(_ key: Key) {
    if let oldTail = tail {
      nextKey[oldTail] = key
      prevKey[key] = oldTail
      tail = key
    } else {
      head = key
      tail = key
    }
  }

  private mutating func prependToHead(_ key: Key) {
    if let oldHead = head {
      prevKey[oldHead] = key
      nextKey[key] = oldHead
      head = key
    } else {
      head = key
      tail = key
    }
  }

  /// Move `key` to the MRU tail (freshest). O(1). `key` must already be in `store`.
  private mutating func moveToTail(_ key: Key) {
    if tail == key { return }  // already MRU
    unlink(key)
    appendToTail(key)
  }

  private mutating func drop(_ key: Key) {
    unlink(key)
    if let entry = store.removeValue(forKey: key) { totalCost -= entry.cost }
  }

  /// Evict LRU entries while EITHER bound is breached. Never evicts below one
  /// entry for a single over-cost insert (the freshest key is MRU/tail, so the
  /// head is dropped first and the just-inserted key is the last standing).
  @discardableResult
  private mutating func evictIfNeeded() -> Int {
    var evicted = 0
    while store.count > countLimit || totalCost > costLimit, let lru = head {
      drop(lru)
      evicted += 1
    }
    return evicted
  }
}
