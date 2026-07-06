import CoreGraphics
import CoreText

/// LRU of wrapped `CTLine` arrays. Key = CONTENT IDENTITY, never row position
/// (brainstorm §Round-3 "keyed by CONTENT IDENTITY, not position"). Bounded by
/// entry count AND an approximate byte ceiling; evict LRU on overflow (§gap #1).
/// CoreText line-building is the hot cost — this cache is what keeps re-layout on
/// scroll O(viewport).
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

  private var map: [Key: LineTypesetter.Wrapped] = [:]
  /// MRU order: front == least-recently-used, back == most-recently-used.
  private var order: [Key] = []
  private var bytesByKey: [Key: Int] = [:]
  private var approxBytes = 0

  let countLimit: Int
  let byteLimit: Int
  let widthQuantum: CGFloat

  init(countLimit: Int = 4000, byteLimit: Int = 32 * 1024 * 1024, widthQuantum: CGFloat = 4) {
    self.countLimit = max(1, countLimit)
    self.byteLimit = max(1, byteLimit)
    self.widthQuantum = max(1, widthQuantum)
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

  /// Cache-through: return the hit (touching it), else `build()` and insert,
  /// evicting LRU entries past either bound.
  func wrapped(_ key: Key, build: () -> LineTypesetter.Wrapped) -> LineTypesetter.Wrapped {
    if let hit = map[key] {
      touch(key)
      return hit
    }
    let built = build()
    map[key] = built
    order.append(key)
    let bytes = Self.estimateBytes(built)
    bytesByKey[key] = bytes
    approxBytes += bytes
    evictIfNeeded()
    return built
  }

  /// Appearance / Dynamic Type / zoom: drop the whole cache. Cheaper + safer than
  /// per-key for a global flip; parse trees are NOT here so they survive.
  func invalidateStyle() {
    map.removeAll(keepingCapacity: true)
    order.removeAll(keepingCapacity: true)
    bytesByKey.removeAll(keepingCapacity: true)
    approxBytes = 0
  }

  var count: Int { map.count }
  func contains(_ key: Key) -> Bool { map[key] != nil }

  private func touch(_ key: Key) {
    guard let index = order.firstIndex(of: key) else { return }
    order.remove(at: index)
    order.append(key)
  }

  private func evictIfNeeded() {
    while map.count > countLimit || approxBytes > byteLimit, let oldest = order.first {
      order.removeFirst()
      map.removeValue(forKey: oldest)
      approxBytes -= bytesByKey.removeValue(forKey: oldest) ?? 0
    }
  }

  /// Rough per-entry cost: one wrapped line's `CTLine` array. CoreText retains
  /// glyph runs internally; ~512 bytes/sub-line is a conservative accounting seed
  /// for the byte ceiling (the count limit is the primary bound).
  private static func estimateBytes(_ wrapped: LineTypesetter.Wrapped) -> Int {
    max(1, wrapped.ctLines.count) * 512
  }
}
