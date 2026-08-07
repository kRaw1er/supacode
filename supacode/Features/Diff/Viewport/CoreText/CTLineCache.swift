import CoreGraphics
import CoreText

/// LRU of wrapped `CTLine` arrays. Key = CONTENT IDENTITY, never row position
/// (brainstorm §Round-3 "keyed by CONTENT IDENTITY, not position"). Bounded by
/// entry count AND an approximate byte ceiling; evict LRU on overflow (§gap #1).
/// CoreText line-building is the hot cost — this cache is what keeps re-layout on
/// scroll O(viewport).
///
/// Backed by the shared `BoundedLRU` primitive (count + byte-cost bound + the
/// "evict on scroll-off" demote), so the byte ceiling and the recycle demote are
/// the same tested code every diff cache uses.
///
/// The `styleGeneration` field in the key is what an appearance / Dynamic Type /
/// zoom flip bumps: a global `invalidateStyle()` drops the whole cache, and every
/// subsequent build mints keys under the new generation (parse trees are NOT
/// here, so they survive — §Round-3).
@MainActor
final class CTLineCache {
  struct Key: Hashable {
    let contentHash: Int  // hash of the line's UTF-16 units, NOT the Swift String
    let styleGeneration: Int  // appearance / Dynamic Type / zoom
    let widthBucket: Int  // (width / quantum).rounded — no thrash on sub-pt resizes
  }

  private var lru: BoundedLRU<Key, LineTypesetter.Wrapped>

  let countLimit: Int
  let byteLimit: Int
  let widthQuantum: CGFloat

  init(countLimit: Int = 4000, byteLimit: Int = 32 * 1024 * 1024, widthQuantum: CGFloat = 4) {
    self.countLimit = max(1, countLimit)
    self.byteLimit = max(1, byteLimit)
    self.widthQuantum = max(1, widthQuantum)
    lru = BoundedLRU(countLimit: self.countLimit, costLimit: self.byteLimit)
  }

  /// Quantize `width` into a bucket so a sub-point resize does not thrash the
  /// cache; fold in the content hash + current style generation.
  func key(contentHash: Int, styleGeneration: Int, width: CGFloat) -> Key {
    Key(
      contentHash: contentHash,
      styleGeneration: styleGeneration,
      widthBucket: Int((max(0, width) / widthQuantum).rounded())
    )
  }

  /// Instrumentation (mirrors `ChunkTree.diagnostics`): counts cache MISSES, i.e.
  /// actual CoreText line-typesets. A scroll of already-materialized content must
  /// leave this flat, and an initial layout must grow it by ~O(visible window),
  /// NOT O(segment) — the load-bearing "re-layout on scroll is O(viewport), not
  /// O(file)" perf assertion keys off its per-frame delta.
  private(set) var buildCount = 0

  /// Cache-through: return the hit (touching it), else `build()` and insert with
  /// its approximate backing-store cost, evicting LRU entries past either bound.
  func wrapped(_ key: Key, build: () -> LineTypesetter.Wrapped) -> LineTypesetter.Wrapped {
    if let hit = lru.value(forKey: key) { return hit }
    buildCount += 1
    let built = build()
    lru.insert(built, forKey: key, cost: Self.estimateBytes(built))
    return built
  }

  /// Phase-13 recycle hook (gap #1): the keys of rows that scrolled out of the
  /// viewport + overscan. They demote to the LRU head so they drop FIRST when the
  /// byte ceiling / count cap next trips — WITHOUT evicting eagerly, so a fling-back
  /// within cap is still an instant hit.
  func noteScrolledOff(_ keys: [Key]) {
    lru.demote(keys)
  }

  /// Appearance / Dynamic Type / zoom: drop the whole cache. Cheaper + safer than
  /// per-key for a global flip; parse trees are NOT here so they survive.
  func invalidateStyle() {
    lru.removeAll()
  }

  var count: Int { lru.count }
  var approxBytes: Int { lru.totalCost }
  func contains(_ key: Key) -> Bool { lru.contains(key) }

  /// Rough per-entry cost: one wrapped line's `CTLine` array. CoreText retains
  /// glyph runs internally; ~512 bytes/sub-line is a conservative accounting seed
  /// for the byte ceiling (the count limit is the primary bound).
  private static func estimateBytes(_ wrapped: LineTypesetter.Wrapped) -> Int {
    max(1, wrapped.ctLines.count) * 512
  }
}
