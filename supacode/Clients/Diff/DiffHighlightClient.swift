import ComposableArchitecture
import Foundation

/// TCA seam between the reducer and the `@MainActor DiffHighlightEngine` (neon).
/// A struct of `@Sendable` closures — the same shape as `DiffClient` /
/// `DiffStreamConsumerClient` — so a `TestStore` can stub `styleRuns` / `isPlain`
/// without a live parser. This is a real engine client (it owns a bounded parse +
/// span cache), NOT a `@Shared` wrapper, so it is a legitimate dependency (CLAUDE.md's
/// ban is on the latter).
///
/// `styleRuns` is `@MainActor` because the engine and its `TreeSitterClient` are
/// (`TreeSitterClient.swift:22-24`); calling it from a `.run` effect hops to the main
/// actor via `await`. `isPlain` is pure (the size gate on counts).
nonisolated struct DiffHighlightClient: Sendable {
  /// Windowed, both-sides highlight for ONE blob: `line → runs` for the visible
  /// range. Empty when there is no grammar / nothing visible / the parse failed.
  var styleRuns:
    @MainActor @Sendable (_ input: HighlightBlobInput, _ visibleLines: Range<Int>) async -> [Int: [StyleRun]]
  /// The size gate, evaluated on counts BEFORE any parse — `true` ⇒ render plain.
  var isPlain:
    @Sendable (_ oldChangedLines: Int, _ newChangedLines: Int, _ oldBlobUTF16: Int, _ newBlobUTF16: Int) -> Bool
}

extension DiffHighlightClient: DependencyKey {
  static let liveValue = DiffHighlightClient(
    styleRuns: { input, visibleLines in
      await DiffHighlightEngine.shared.styleRuns(for: input, visibleLines: visibleLines)
    },
    isPlain: { oldChanged, newChanged, oldBlob, newBlob in
      DiffHighlightPolicy.isPlain(
        oldChangedLines: oldChanged, newChangedLines: newChanged, oldBlobUTF16: oldBlob, newBlobUTF16: newBlob)
    }
  )

  /// Quiet default (the app is its own test host — `.appLaunched` runs during every
  /// test): no highlighting unless a test overrides `styleRuns`. `isPlain` stays the
  /// real pure gate so a test that doesn't override it still gates correctly.
  static var testValue: DiffHighlightClient {
    DiffHighlightClient(
      styleRuns: { _, _ in [:] },
      isPlain: { oldChanged, newChanged, oldBlob, newBlob in
        DiffHighlightPolicy.isPlain(
          oldChangedLines: oldChanged, newChangedLines: newChanged, oldBlobUTF16: oldBlob, newBlobUTF16: newBlob)
      }
    )
  }
}

extension DependencyValues {
  var diffHighlight: DiffHighlightClient {
    get { self[DiffHighlightClient.self] }
    set { self[DiffHighlightClient.self] = newValue }
  }
}
