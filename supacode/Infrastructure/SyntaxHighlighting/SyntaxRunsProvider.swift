import Foundation

/// The render-layer seam for pulling resolved syntax runs, injected into the draw path
/// (wired in a later phase) so `LineRowView` colors each drawn row from a `µs`
/// dictionary read instead of the reducer push. A value type of one `@MainActor`
/// closure — the live implementation reads `DiffHighlightEngine`'s span cache, a stub
/// (`.empty`) returns nothing, keeping the view testable without an engine (like the
/// `CTLineCache` seam).
///
/// LINE SPACE: `blobLine` is a **0-based blob line**, exactly what the span cache keys
/// (`DiffHighlightEngine.cachedRuns`). Any 1-based↔0-based translation belongs to the
/// caller (the warmer / client adapter), never here.
///
/// `nonisolated struct` + `Sendable` so it rides into `@Sendable` render context /
/// effect closures unchanged; the stored closure is `@MainActor` because the cache read
/// touches main-actor state.
nonisolated struct SyntaxRunsProvider: Sendable {
  /// Resolves the cached runs for one blob line. A cache MISS returns `[]` (base color),
  /// exactly as a missing highlight does today.
  var runs: @MainActor @Sendable (_ blobOID: String, _ queryName: String, _ blobLine: Int) -> [StyleRun]

  init(runs: @escaping @MainActor @Sendable (_ blobOID: String, _ queryName: String, _ blobLine: Int) -> [StyleRun]) {
    self.runs = runs
  }

  /// A stub that colors nothing — every row renders in the base color. Used by tests /
  /// the plain-render size gate.
  static let empty = SyntaxRunsProvider { _, _, _ in [] }

  /// Reads a single blob line's runs straight from `engine`'s span cache — a pure read
  /// (no parse, no client build). A miss (blob not warmed, or that line not yet queried)
  /// returns `[]`.
  static func live(_ engine: DiffHighlightEngine) -> SyntaxRunsProvider {
    SyntaxRunsProvider { blobOID, queryName, blobLine in
      engine.cachedRuns(blobOID: blobOID, queryName: queryName, blobLine: blobLine)
    }
  }
}
