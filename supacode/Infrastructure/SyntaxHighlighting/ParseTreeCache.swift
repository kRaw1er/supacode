import Dispatch
import Foundation
import SupacodeSettingsShared
import TreeSitterClient

/// LRU of `TreeSitterClient`s keyed by **content identity** `(blobOID, queryName)` —
/// NOT by row position, theme, font, or `styleGeneration`. The client OWNS its parse
/// tree, so this is the parse-tree cache: the base blob parses once and is shared
/// across every worktree diff that references the same commit. An appearance /
/// Dynamic Type / zoom flip bumps the Phase-3 CTLine `styleGeneration` — which is
/// deliberately absent from `Key`, so those flips never invalidate a parse.
///
/// Bounded by count (16–32 range, default 24) AND a memory-pressure evict: a
/// `.warning` trims to `memoryWarningKeepCount`, a `.critical` clears — Apple's
/// canonical low-memory signal (`DispatchSource.makeMemoryPressureSource`). The
/// handler runs on `.main` but is not statically main-actor-isolated, so it bridges
/// via `MainActor.assumeIsolated` (precedent `GhosttyRuntime.swift`).
///
/// `@MainActor` because `TreeSitterClient` is `@MainActor` and non-`Sendable`
/// (`TreeSitterClient.swift:22-24`).
@MainActor
final class ParseTreeCache {
  struct Key: Hashable {
    let blobOID: String
    let queryName: String
  }

  /// What a memory-pressure event does to the cache. Pure so it is unit-testable
  /// without waiting on (or faking the kernel delivery of) a real pressure event.
  enum PressureResponse: Equatable {
    case none
    case trim(toCount: Int)
    case clear
  }

  /// The count a `.warning` trims down to (keeps the hottest handful of parses so
  /// the next scroll is not a cold reparse of everything).
  static let memoryWarningKeepCount = 8

  private var store: [Key: TreeSitterClient] = [:]
  /// MRU order: front == least-recently-used, back == most-recently-used.
  private var order: [Key] = []
  private let capacity: Int
  private var pressureSource: DispatchSourceMemoryPressure?
  private static let log = SupaLogger("DiffParseTreeCache")

  /// `monitorMemoryPressure: false` skips installing the real `DispatchSource`
  /// (tests drive `respond(to:)` / `handleMemoryPressure(...)` directly).
  init(capacity: Int = 24, monitorMemoryPressure: Bool = true) {
    self.capacity = max(1, capacity)
    if monitorMemoryPressure { installMemoryPressureMonitor() }
  }

  deinit { pressureSource?.cancel() }

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

  // MARK: - Eviction

  /// Drop entries (LRU-first) until at most `target` remain.
  func trim(toCount target: Int) {
    let limit = max(0, target)
    while store.count > limit, let evicted = order.first {
      order.removeFirst()
      store[evicted] = nil
    }
  }

  /// Drop every cached parse (`.critical` pressure / a hard reset).
  func clear() {
    store.removeAll(keepingCapacity: true)
    order.removeAll(keepingCapacity: true)
  }

  // MARK: - Memory pressure

  /// The response to a raw event mask — `.critical` wins over `.warning` (a
  /// coalesced event carrying both is treated as critical). Pure; no side effects.
  static func pressureResponse(critical: Bool, warning: Bool) -> PressureResponse {
    if critical { return .clear }
    if warning { return .trim(toCount: memoryWarningKeepCount) }
    return .none
  }

  /// Apply a `PressureResponse` to the cache (the seam the real handler and the
  /// tests both drive).
  func respond(to response: PressureResponse) {
    switch response {
    case .none:
      break
    case .trim(let count):
      trim(toCount: count)
      Self.log.info("trimmed to \(count) on memory warning")
    case .clear:
      clear()
      Self.log.warning("cleared on critical memory pressure")
    }
  }

  /// Map a raw event mask to a response and apply it. Exposed so a test injects a
  /// synthetic `.critical` / `.warning` without waiting on the OS.
  func handleMemoryPressure(critical: Bool, warning: Bool) {
    respond(to: Self.pressureResponse(critical: critical, warning: warning))
  }

  private func installMemoryPressureMonitor() {
    // DISPATCH_SOURCE_TYPE_MEMORYPRESSURE — Apple's canonical low-memory signal.
    let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
    source.setEventHandler { [weak self] in
      // queue:.main ⇒ runs on the main thread; bridge to the actor like
      // `GhosttyRuntime.swift` does for its main-queue notification handlers.
      MainActor.assumeIsolated {
        guard let self else { return }
        let mask = source.data
        self.handleMemoryPressure(critical: mask.contains(.critical), warning: mask.contains(.warning))
      }
    }
    source.resume()
    pressureSource = source
  }

  private func touch(_ key: Key) {
    order.removeAll { $0 == key }
    order.append(key)
  }
}
