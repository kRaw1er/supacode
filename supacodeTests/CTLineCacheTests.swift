import CoreText
import Foundation
import Testing

@testable import supacode

/// Phase 3 — the wrapped-`CTLine` LRU cache (3.10). Keyed by `(contentHash,
/// styleGeneration, widthBucket)`: same key hits, a style-generation change
/// misses, sub-quantum width changes quantize to the same bucket, count-limit
/// eviction is LRU, and `invalidateStyle()` drops everything.
@MainActor
struct CTLineCacheTests {
  private func stub() -> LineTypesetter.Wrapped {
    LineTypesetter.Wrapped(ctLines: [CoreTextHarness.ctLine("x")], height: 20)
  }

  @Test func ctLineCacheHitMissByKey() {
    let cache = CTLineCache(countLimit: 2, widthQuantum: 4)
    var builds = 0
    let build: () -> LineTypesetter.Wrapped = {
      builds += 1
      return self.stub()
    }

    let key1 = cache.key(contentHash: 1, styleGeneration: 0, width: 100)
    _ = cache.wrapped(key1, build: build)
    #expect(builds == 1)  // miss → build
    _ = cache.wrapped(key1, build: build)
    #expect(builds == 1)  // hit → no build

    // Sub-quantum width change (100 → 101, quantum 4) buckets identically ⇒ hit.
    let key1b = cache.key(contentHash: 1, styleGeneration: 0, width: 101)
    #expect(key1b == key1)
    _ = cache.wrapped(key1b, build: build)
    #expect(builds == 1)

    // A style-generation change is a DIFFERENT key ⇒ miss.
    let key1gen = cache.key(contentHash: 1, styleGeneration: 1, width: 100)
    #expect(key1gen != key1)
    _ = cache.wrapped(key1gen, build: build)
    #expect(builds == 2)
    #expect(cache.count == 2)

    // Count-limit eviction is LRU: touch key1 (MRU), then insert a third key ⇒ the
    // least-recently-used (key1gen) is evicted, key1 survives.
    _ = cache.wrapped(key1, build: build)  // touch (hit)
    #expect(builds == 2)
    let key3 = cache.key(contentHash: 3, styleGeneration: 0, width: 100)
    _ = cache.wrapped(key3, build: build)
    #expect(builds == 3)
    #expect(cache.count == 2)
    #expect(cache.contains(key1))
    #expect(cache.contains(key3))
    #expect(!cache.contains(key1gen))  // LRU-evicted

    // A global style flip drops the whole cache.
    cache.invalidateStyle()
    #expect(cache.count == 0)
    _ = cache.wrapped(key1, build: build)
    #expect(builds == 4)  // miss after clear
  }

  @Test func widthBucketQuantizesAcrossQuantumBoundary() {
    let cache = CTLineCache(widthQuantum: 4)
    // 100 and 103 round to bucket 25/26 respectively (100/4=25.0→25; 103/4=25.75→26).
    let bucket100 = cache.key(contentHash: 7, styleGeneration: 0, width: 100)
    let bucket103 = cache.key(contentHash: 7, styleGeneration: 0, width: 103)
    #expect(bucket100 != bucket103)  // crossed a quantum boundary ⇒ distinct bucket
    let bucket99 = cache.key(contentHash: 7, styleGeneration: 0, width: 99)
    #expect(bucket100 == bucket99)  // 99/4 = 24.75 → 25 == 25
  }
}
