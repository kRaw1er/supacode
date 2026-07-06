import ComposableArchitecture
import Foundation

/// TCA dependency mirroring `DiffClient` (DiffClient.swift:13-25). Reveals hidden
/// unchanged lines by reading the git blob — the incremental replacement for the
/// deleted 1M-context re-diff. The `liveValue` wraps the shared `BlobSliceProvider`
/// actor, serialized behind the same confinement discipline as `LibGit2DiffProvider`
/// so libgit2 (`GIT_THREADS=1`) stays single-threaded.
struct BlobSliceClient: Sendable {
  /// New-side context lines for the half-open `newLineRange`. `oldLineDelta` maps
  /// new→old numbers inside the unchanged gap (`old = new + delta`). NEVER re-diffs.
  var slice:
    @Sendable (
      _ file: FileChange, _ worktreeURL: URL, _ source: DiffSource, _ newLineRange: Range<Int>, _ oldLineDelta: Int
    ) async throws -> [DiffLine]
}

extension BlobSliceClient: DependencyKey {
  static let liveValue: BlobSliceClient = {
    // One shared actor for the whole app so blob reads serialize with the diff
    // walk's `GIT_THREADS=1` contract.
    let provider = BlobSliceProvider()
    return BlobSliceClient(
      slice: { file, worktreeURL, source, newLineRange, oldLineDelta in
        try await provider.slice(
          file: file, worktreeURL: worktreeURL, source: source, newLineRange: newLineRange, oldLineDelta: oldLineDelta)
      }
    )
  }()

  /// Deterministic fixture: numbered context lines over the requested new range, so
  /// reducer `TestStore` tests need no filesystem. `old = new + delta` in lockstep,
  /// matching the real unchanged-gap numbering.
  static var testValue: BlobSliceClient {
    BlobSliceClient(
      slice: { _, _, _, newLineRange, oldLineDelta in
        newLineRange.map { number in
          DiffLine(
            origin: .context,
            oldLineNumber: number + oldLineDelta,
            newLineNumber: number,
            content: "context line \(number)",
            noNewlineAtEof: false
          )
        }
      }
    )
  }
}

extension DependencyValues {
  var blobSliceClient: BlobSliceClient {
    get { self[BlobSliceClient.self] }
    set { self[BlobSliceClient.self] = newValue }
  }
}
