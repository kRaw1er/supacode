import ComposableArchitecture
import Foundation

/// TCA seam between the reducer and the `@MainActor DiffStreamConsumer` (the
/// tree-backed streaming engine, `Features/Diff/Viewport/StreamConsumer.swift`).
/// A struct of `@Sendable` closures, keyed by `DiffDocumentKey` so each open diff
/// tab's stream drives its own consumer once the tree-backed viewport is the live
/// renderer.
///
/// **Live wiring is Phase 13's seam flip.** Until the tree-backed viewport
/// replaces `DiffTableController` in `DiffViewerRepresentable`, there is no live
/// per-view viewport to bind a consumer to, so `liveValue` is a no-op — the
/// streaming reducer path is gated OFF in production by `diffStreamingEnabled`
/// (also `false` in `liveValue`), exactly as the disabled `modeToggleBumpsRevisionOnly`
/// test documents. The `DiffStreamConsumer` itself is fully exercised by its own
/// unit tests; this seam lets the reducer tests assert "the consumer was fed".
struct DiffStreamConsumerClient: Sendable {
  /// `.started`: scaffold (first load) / adopt generation (re-diff).
  var begin: @Sendable (_ key: DiffDocumentKey, _ fileCount: Int, _ mode: DiffViewMode, _ generation: Int) async -> Void
  /// `.fileReady`: reconcile one file by content identity (reuse / splice / append).
  var consume: @Sendable (_ key: DiffDocumentKey, _ batch: FileDiffBatch, _ mode: DiffViewMode) async -> Void
  /// `.finished`: prune vanished files + drop the scaffold + settle scroll.
  var finish: @Sendable (_ key: DiffDocumentKey, _ generation: Int) async -> Void
}

extension DiffStreamConsumerClient: DependencyKey {
  /// No-op until Phase 13 binds a live consumer to the tree-backed viewport.
  static let liveValue = DiffStreamConsumerClient(
    begin: { _, _, _, _ in },
    consume: { _, _, _ in },
    finish: { _, _ in }
  )
  static var testValue: DiffStreamConsumerClient { liveValue }
}

extension DependencyValues {
  var diffStreamConsumer: DiffStreamConsumerClient {
    get { self[DiffStreamConsumerClient.self] }
    set { self[DiffStreamConsumerClient.self] = newValue }
  }
}

/// Feature gate for the tree-backed streaming reducer path. `false` in production
/// and by default in tests — the streaming reducer arms are real and tested, but
/// `.openFile` / `refreshOpenDiffs` keep issuing the per-file `diffEffect` (the
/// live `[DiffRow]` path) until Phase 13 flips the viewport seam. Streaming tests
/// override this to `true`.
enum DiffStreamingEnabledKey: DependencyKey {
  static let liveValue = false
  static let testValue = false
}

extension DependencyValues {
  var diffStreamingEnabled: Bool {
    get { self[DiffStreamingEnabledKey.self] }
    set { self[DiffStreamingEnabledKey.self] = newValue }
  }
}
