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
  /// Windowed highlight for ONE blob. `visibleLines` is a **1-based source-line**
  /// range (the `DiffLine.old/newLineNumber` space) and the result is keyed the same
  /// way, so `LineRowView.syntaxRuns` looks the runs up with no coordinate skew. The
  /// live adapter converts to/from the engine's 0-based blob-line space. Empty when
  /// there is no grammar / nothing visible / the parse failed.
  var styleRuns:
    @MainActor @Sendable (_ input: HighlightBlobInput, _ visibleLines: Range<Int>) async -> [Int: [StyleRun]]
  /// Synchronous "paint-now" fast path (Phase-4 C9): returns runs immediately when the
  /// parse is already warm so the render path colors in the SAME reduction with no async
  /// round-trip; `nil` ⇒ the parse is still pending and the caller schedules the async
  /// pass; `[:]` ⇒ a legitimate plain render (no grammar / empty window). Same 1-based
  /// line-number contract as `styleRuns`. Defaults to always-pending (`nil`) so a test
  /// or an unset construction transparently keeps the async-only behaviour.
  var syncStyleRuns:
    @MainActor @Sendable (_ input: HighlightBlobInput, _ visibleLines: Range<Int>) -> [Int: [StyleRun]]? = {
      _, _ in nil
    }
  /// The size gate, evaluated on counts BEFORE any parse — `true` ⇒ render plain.
  var isPlain:
    @Sendable (_ oldChangedLines: Int, _ newChangedLines: Int, _ oldBlobUTF16: Int, _ newBlobUTF16: Int) -> Bool
}

extension DiffHighlightClient {
  /// 1-based visible line-number range → the 0-based blob-line window the engine
  /// queries (`DiffHighlightEngine` indexes `lineStarts` 0-based, blob line `i` ==
  /// source line number `i + 1`). An empty / degenerate range stays empty.
  nonisolated static func blobWindow(forLineNumbers lines: Range<Int>) -> Range<Int> {
    guard !lines.isEmpty else { return 0..<0 }
    let lower = max(0, lines.lowerBound - 1)
    let upper = max(lower, lines.upperBound - 1)
    return lower..<upper
  }

  /// 0-based blob-line keys (engine output) → 1-based source line numbers (the
  /// `DiffLine.old/newLineNumber` space the row lookup keys off). This `+1` is the
  /// single fix for the "runs bucketed one line off from where the row reads them"
  /// skew — confined to the one adapter that straddles blob-space and line-space.
  nonisolated static func lineNumberKeyed(_ byBlobLine: [Int: [StyleRun]]) -> [Int: [StyleRun]] {
    var out: [Int: [StyleRun]] = [:]
    out.reserveCapacity(byBlobLine.count)
    for (blobLine, runs) in byBlobLine { out[blobLine + 1] = runs }
    return out
  }
}

extension DiffHighlightClient: DependencyKey {
  static let liveValue = DiffHighlightClient(
    styleRuns: { input, visibleLines in
      let window = blobWindow(forLineNumbers: visibleLines)
      guard !window.isEmpty else { return [:] }
      let byBlobLine = await DiffHighlightEngine.shared.styleRuns(for: input, visibleLines: window)
      return lineNumberKeyed(byBlobLine)
    },
    syncStyleRuns: { input, visibleLines in
      // Same 1-based↔0-based adapter as the async path; a `nil` engine result (parse
      // pending, C9) propagates so the reducer falls back to the async pass.
      let window = blobWindow(forLineNumbers: visibleLines)
      guard !window.isEmpty else { return [:] }
      guard let byBlobLine = DiffHighlightEngine.shared.syncStyleRuns(for: input, visibleLines: window) else {
        return nil
      }
      return lineNumberKeyed(byBlobLine)
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
