import ComposableArchitecture
import Foundation
import Sharing
import SupacodeSettingsShared

/// Canonical (owned by Phase 2). Unified vs split viewer preference. Phase 3 consumes this exact
/// type + key — it must NOT define a parallel `DiffMode` / `"diffMode"`.
enum DiffViewMode: String, Codable, Sendable, Equatable, CaseIterable { case unified, split }

/// Per-open-file diff document living in `DiffReviewFeature.State.openDiffs`,
/// keyed by file path. Owns everything the center diff tab renders: the file
/// metadata, the raw hunks (the ChunkTree viewport projects these directly — no
/// flat `[DiffRow]` anymore, Phase 13 seam swap), the load state, the "no longer
/// changed" stale flag, the **declarative expansion state** (Phase 7), and a
/// viewport handoff cache of revealed blob slices. The tree-backed
/// `DiffViewerRepresentable` re-applies whenever the document's content signature
/// changes (`generation` + comments + expansion), scroll-preserving.
struct DiffDocument: Equatable, Sendable {
  var file: FileChange
  /// Which diff this document renders. Part of its `DiffDocumentKey` identity so
  /// a working-tree tab and a base-branch tab of the same file are distinct.
  var source: DiffSource = .workingTree
  var hunks: [DiffHunk] = []
  var loadState: LoadState = .loading
  var isStale: Bool = false
  /// Declarative, document-level collapse/expand (Phase 7). Keyed by gap INDEX
  /// (`GapKey.hunkIndex`) so it survives a re-diff — the incremental replacement
  /// for the deleted 1M-context re-diff (`expanded: Set<Int>` was line-number keyed
  /// and did NOT survive an edit above the gap). The ChunkTree viewport is a
  /// projection of this; THIS is the source of truth.
  var expansion: ExpansionState = .collapsed
  /// Viewport handoff cache: per-gap blob-sliced context lines the reducer read for
  /// the current `expansion` (gap index → sorted-by-new-line context `DiffLine`s).
  /// The viewport reads it to `tree.insert(after: expanderChunk, …)` O(log n). Reset
  /// on a re-diff (the materialized slices are re-sliced against the fresh geometry);
  /// the declarative `expansion` persists.
  var revealed: [Int: [DiffLine]] = [:]
  /// Generation guard for this document's in-flight `diff` request (8.1). A
  /// returning `.diffLoaded/.diffFailed` whose token no longer matches is dropped.
  var generation: Int = 0

  // MARK: Phase 4 — neon syntax highlighting

  /// The old-side blob to highlight (HEAD / three-dot merge-base, per `source`), or
  /// `nil` on an added file / working-tree new side. Populated from the Phase-9
  /// `FileDiffBatch` — the correct blob per `DiffSource` (fixes bug #1, no disk read).
  var oldBlob: HighlightBlobInput?
  /// The new-side blob (branch tip for a base diff), or `nil` on a deleted file /
  /// the working-tree new side (workdir, not decoded).
  var newBlob: HighlightBlobInput?
  /// The last per-side visible SOURCE-line window the highlighter was asked about
  /// (1-based line numbers, split by blob side — NOT rendered-row indices).
  var visibleLineWindow: VisibleLineWindow = .empty
  /// Set once by the size gate at load; short-circuits the highlight driver so a
  /// 200k-line / >2.5M-unit file renders plain with a header affordance, no stall.
  var highlightingDisabled: Bool = false
  /// Set once by the word-diff gate (`WordDiffPolicy`) at load: a file whose changed
  /// lines exceed the per-side cap gets NO intra-line word-diff (only the row-level
  /// `+`/`-` tint). The render path reads this so `WordDiff` is never invoked for a
  /// massively-changed file — the "gate lives upstream" contract.
  var wordDiffDisabled: Bool = false
  /// The fully-changed-huge-file header affordance (`LargeFileRenderPolicy`), or
  /// `nil` when the file renders fully. Surfaced in the diff-tab header so a dropped
  /// render feature (highlight / word-diff) is never a silent drop.
  var renderBannerKey: LargeFileRenderPolicy.BannerKey?
  /// `line → runs` for the OLD side of the visible window (both sides highlighted —
  /// fixes bug #2, the old path forced the old side `[]`).
  var oldStyleRuns: [Int: [StyleRun]] = [:]
  /// `line → runs` for the NEW side of the visible window.
  var newStyleRuns: [Int: [StyleRun]] = [:]
  /// Monotonic guard for the in-flight highlight query. Bumped on every
  /// visible-range change (the REQUEST); a returning `.highlightsReady` whose token
  /// no longer matches is dropped (pierre `isCurrentRequest`).
  var highlightGeneration: Int = 0
  /// Monotonic revision bumped whenever the STORED runs change (a highlight ARRIVES,
  /// or a re-diff clears them). This — NOT `highlightGeneration` (which bumps on the
  /// request, before the runs exist) — is what the view observes to push fresh runs
  /// into the viewport: gating delivery on `highlightGeneration` skipped the arriving
  /// colors because the request had already advanced the token.
  var styleRunsVersion: Int = 0

  enum LoadState: Equatable, Sendable {
    case loading
    case loaded
    case error(DiffError)
  }
}

/// Composite identity for an open center diff tab: a file path scoped to the
/// diff it belongs to. A file that changed both in the working tree and against
/// the base opens two independent documents/tabs, one per `source` (Phase 2).
nonisolated struct DiffDocumentKey: Hashable, Sendable {
  var path: String
  var source: DiffSource
}

/// A one-shot scroll intent the diff viewport consumes once (jump-to-file from the
/// inspector, Phase 10). Distinct from the tree's geometric `ScrollTarget`: this is
/// the reducer-level "please scroll the body to this file" the representable drains
/// on its next `updateNSView`, then clears via `.diffScrollTargetConsumed` — the same
/// consume-once pattern the app uses for setup-script consumption.
nonisolated enum PendingScrollTarget: Equatable, Sendable {
  case file(FileChange.ID)
}

// MARK: - Gap geometry (Phase 7 — bounding-hunk math, mirrored from the builder)

extension DiffDocument {
  /// A gap index is TRAILING (after the last hunk) when it equals `hunks.count`
  /// (matches `virtualDiffLayout.ts:197` / `ChunkTreeBuilder.appendHunks`).
  func isTrailingGap(_ gap: Int) -> Bool { gap == hunks.count }

  /// The first hidden NEW-side line number of gap `gap` — the line just below the
  /// hunk ABOVE the gap. The leading gap (index 0) starts at new line 1.
  func gapNewLineStart(_ gap: Int) -> Int {
    guard gap >= 1, gap - 1 < hunks.count else { return 1 }
    let above = hunks[gap - 1]
    return above.newStart + above.newCount
  }

  /// The gap's hidden-line count (`rangeSize`), from the bounding hunks — the
  /// current `ChunkTreeBuilder` gap math. Returns `0` for a gap
  /// index that no longer maps to a real gap after a re-diff (degrade to collapsed,
  /// never a crash). The trailing gap is EOF-unbounded, so `Int.max` — the reducer
  /// caps the eager slice and the `BlobSliceProvider` clamps at EOF.
  func gapRangeSize(_ gap: Int) -> Int {
    guard let first = hunks.first else { return 0 }
    if gap <= 0 { return max(first.newStart - 1, 0) }  // leading gap
    if gap >= hunks.count { return .max }  // trailing gap — unbounded to EOF
    let above = hunks[gap - 1]
    let below = hunks[gap]
    return max(below.newStart - (above.newStart + above.newCount), 0)
  }

  /// The new→old delta inside gap `gap`'s unchanged run (`old = new + delta`).
  /// Unchanged gap lines advance old/new in lockstep, so a single delta is exact.
  /// Derived from the hunk ABOVE the gap (`DiffModels.swift:42-45`); the leading
  /// gap ⇒ delta `0`; the trailing gap ⇒ delta of the final hunk.
  func gapOldLineDelta(_ gap: Int) -> Int {
    guard gap >= 1, gap - 1 < hunks.count else { return 0 }
    let above = hunks[gap - 1]
    return (above.oldStart + above.oldCount) - (above.newStart + above.newCount)
  }

  /// The newly-revealed NEW-side sub-ranges when gap `gap`'s region grows from
  /// `before` → `after`. The top portion grows downward from the gap start
  /// (`fromStart`); the bottom portion grows upward from the gap end (`fromEnd`,
  /// never for a trailing gap). Bounded to `cap` total lines so a whole-file expand
  /// eager-slices only the first window; the viewport windows the rest on scroll.
  func newlyRevealedRanges(
    gap: Int,
    before: ExpansionState.ResolvedRegion,
    after: ExpansionState.ResolvedRegion,
    cap: Int
  ) -> [Range<Int>] {
    guard cap > 0 else { return [] }
    let start = gapNewLineStart(gap)
    var remaining = cap
    var ranges: [Range<Int>] = []
    // Top: reveal `[start + before.fromStart, start + after.fromStart)`, capped.
    let topRevealed = after.fromStart - before.fromStart
    if topRevealed > 0 {
      let (lower, overflow) = start.addingReportingOverflow(before.fromStart)
      if !overflow {
        let take = min(topRevealed, remaining)
        ranges.append(lower..<(lower + take))
        remaining -= take
      }
    }
    // Bottom: only for a bounded (non-trailing, finite-size) gap.
    let size = gapRangeSize(gap)
    if remaining > 0, !isTrailingGap(gap), size != .max {
      let bottomRevealed = after.fromEnd - before.fromEnd
      if bottomRevealed > 0 {
        let end = start + size  // one past the gap's last new line
        let take = min(bottomRevealed, remaining)
        let lower = end - after.fromEnd  // the newly-revealed bottom span starts here
        ranges.append(lower..<(lower + take))
        remaining -= take
      }
    }
    return ranges
  }
}

@Reducer
struct DiffReviewFeature {
  @ObservableState
  struct State: Equatable {
    /// The worktree whose changes are shown, or nil when nothing is selected.
    var selectedWorktree: Worktree?
    /// Last successfully loaded file list. Kept across an `.indexLocked` refresh
    /// (last-good) so the panel never flashes empty on a transient lock.
    var files: [FileChange] = []
    var loadState: LoadState = .idle
    /// Monotonic request token. Bumped on every (re)selection and load; a returning
    /// `.loaded/.failed` whose `generation` no longer matches is discarded (8.1).
    var generation: Int = 0
    /// Mid-operation repo state from the last successful load (Phase 1 produces it
    /// on `WorktreeDiff.operation`; Phase 6 renders the banner). `.none` outside a
    /// merge / rebase / cherry-pick / etc. Reset on deselect + unsupported worktrees.
    var repositoryOperation: RepositoryOperation = .none
    /// Unified vs split viewer preference (consumed in Phase 3; declared here so the
    /// panel owns the pref). Global.
    @Shared(.appStorage("diffViewMode")) var diffViewMode: DiffViewMode = .unified

    // MARK: Base-branch diff (second source) — committed `merge-base..HEAD` changes
    /// Committed branch changes vs the resolved base. Independent of `files`; a
    /// file may appear in both lists. Kept across an `.indexLocked` refresh.
    var baseFiles: [FileChange] = []
    /// The resolved base ref (PR base → default branch). `nil` ⇒ nothing
    /// resolved ⇒ the base section is hidden entirely (never an error).
    var baseRef: String?
    var baseLoadState: LoadState = .idle
    /// Stale token for the base list, independent of `generation`: a slow base
    /// diff from a previous worktree can't overwrite the current one (8.1).
    var baseGeneration: Int = 0

    // MARK: Phase 10 — sticky header / keyboard nav / scroll-spy

    /// The file currently owning the diff viewport's top edge (scroll-spy body →
    /// list). Display-only: drives the inspector row highlight + auto-scroll; does
    /// NOT trigger any structural recompute. `nil` before the first scroll-spy tick.
    var activeFileID: FileChange.ID?
    /// A one-shot jump-to-file scroll intent (inspector list → body). Set by
    /// `.diffJumpToFile`, drained by the viewport representable, cleared by
    /// `.diffScrollTargetConsumed` (consume-once).
    var pendingScrollTarget: PendingScrollTarget?
    /// Whether the `?` keyboard-shortcuts help overlay is showing (toggled by
    /// `.diffShowKeyboardHelp` from `DiffKeyboardNav`).
    var keyboardHelpVisible = false
    /// Set true by `.diffBeginFind` (`/`) — the entry-point flag the Phase-11 find
    /// bar consumes to open itself. Cleared when find opens.
    var findRequested = false

    /// Open center diff tabs, keyed by `(path, source)`. Additive over the
    /// Phase 0 state (`DiffTabPayload` stays `filePath`-only; the document lives here).
    var openDiffs: [DiffDocumentKey: DiffDocument] = [:]
    /// Monotonic token stamped onto a document on each (re)load; the returning
    /// `.diffLoaded/.diffFailed` is discarded when it no longer matches (8.1).
    var diffLoadToken: Int = 0

    /// Review comments for the selected worktree, spanning every open diff tab
    /// (5.4/5.9). Session-only — not persisted (no `Codable` on `State`). Kept
    /// across a diff-tab close/reopen; cleared only on send or explicit discard.
    var comments: IdentifiedArrayOf<ReviewComment> = []
    /// The inline comment composer (new or edit), when open.
    @Presents var composer: CommentComposer.State?
    /// True while a send is in flight so a double-send can't duplicate (5.5).
    var batchLocked = false
    /// "No agent terminal to send to." (5.7).
    @Presents var alert: AlertState<Action.Alert>?
    /// Confirm-on-close for a non-empty batch (3.4).
    @Presents var discardConfirm: ConfirmationDialogState<Action.DiscardConfirm>?

    /// Count of comments that would actually send (non-empty body); drives the
    /// send button's label + disabled state.
    var sendableCommentCount: Int {
      comments.count { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Comments scoped to one diff tab, keyed by `(filePath, source)` so a
    /// working-tree thread and a base-branch thread on the same file stay apart.
    func comments(forPath path: String, source: DiffSource) -> [ReviewComment] {
      comments.filter { $0.filePath == path && $0.source == source }
    }

    enum LoadState: Equatable {
      case idle  // no selection (1.1)
      case loading  // in-flight, no prior list to show
      case loaded  // files.isEmpty == false
      case empty  // git worktree, zero changes (1.6)
      case refreshing  // index.lock: keep `files`, show subtle "updating…" (1.7)
      case error(DiffError)  // other libgit2 failure
      case unsupported(Unsupported)  // folder / remote (1.4 / 1.5)
    }
    enum Unsupported: Equatable {
      case folder  // "Not a git repository"
      case remote  // "Diff review isn't available for remote worktrees yet"
    }

    /// The toolbar toggle is hidden when the panel can't apply to this worktree.
    var supportsDiffReview: Bool {
      guard let worktree = selectedWorktree else { return false }
      return !worktree.isFolder && worktree.host == nil
    }

    /// The base section renders only when the panel is supported AND a base ref
    /// resolved; otherwise section 2 is hidden entirely (Phase 3 consumes this).
    var supportsBaseDiff: Bool { supportsDiffReview && baseRef != nil }

    /// Header for the "vs `<base>`" inspector section, or `nil` when the section
    /// is hidden (no base resolved). The view switches section visibility on this
    /// so the render decision stays testable without a view harness (Phase 3).
    var baseSectionTitle: String? {
      guard supportsBaseDiff, let ref = baseRef else { return nil }
      return "vs \(DiffSource.baseBranch(ref: ref).displayName ?? "base")"
    }
  }

  enum Action: Equatable {
    /// Fan-out from AppFeature. `prBaseRefName` carries the worktree's PR base
    /// (read from `sidebarItems`) so the reducer resolves the base ref PR-first.
    case worktreeSelected(Worktree?, prBaseRefName: String?)
    case load  // (re)issue a changedFiles request (both sources)
    case loaded([FileChange], operation: RepositoryOperation, generation: Int)  // working-tree success
    case failed(DiffError, generation: Int)  // working-tree failure
    // MARK: Base-branch source
    case baseRefResolved(ref: String?, generation: Int)  // resolver result; nil ⇒ hide section 2
    case baseLoaded([FileChange], generation: Int)  // base `changedFiles` success
    case baseFailed(DiffError, generation: Int)  // base `changedFiles` failure
    case filesChanged(Worktree.ID)  // raw info-event tick (pre-debounce)
    case refreshTick  // post-debounce: re-load
    case openFile(path: String, source: DiffSource)  // row tap → open center diff tab
    case diffLoaded(key: DiffDocumentKey, hunks: [DiffHunk], token: Int)  // per-file hunk load success
    case diffFailed(key: DiffDocumentKey, DiffError, token: Int)  // per-file hunk load failure
    // MARK: Phase 9 — streaming producer↔consumer
    case streamStarted(key: DiffDocumentKey, fileCount: Int, token: Int)  // `.started` → scaffold the consumer
    case streamFileReady(key: DiffDocumentKey, batch: FileDiffBatch, token: Int)  // `.fileReady` → feed + build rows
    case streamFinished(key: DiffDocumentKey, token: Int)  // `.finished` → mark loaded
    case diffModeChanged(DiffViewMode)  // unified/split toggle → rebuild all open docs
    // MARK: Phase 7 — incremental collapse / expand (blob-slice, NO re-diff)
    /// Expander tap → mutate `ExpansionState` (pure) + fire a blob-slice effect for
    /// ONLY the newly-revealed delta range (one gap, incremental). Never re-diffs.
    case expandGap(key: DiffDocumentKey, gap: Int, step: ExpansionState.Step, direction: ExpansionState.Direction)
    /// Re-hide a gap → drop its region + revealed slices, cancel any in-flight slice.
    case collapseGap(key: DiffDocumentKey, gap: Int)
    /// A blob slice came back → stash it in `revealed[gap]` for the viewport.
    case gapSliceLoaded(key: DiffDocumentKey, gap: Int, lines: [DiffLine], token: Int)
    /// A blob slice failed (non-fatal) → the gap stays collapsed.
    case gapSliceFailed(key: DiffDocumentKey, gap: Int, DiffError, token: Int)

    // MARK: Phase 10 — sticky header / keyboard nav / scroll-spy
    /// Body → list: the diff viewport scroll-spy resolved a new owning file
    /// (`y → chunk → file`, change-only dedupe). Display-only (row highlight).
    case diffActiveFileChanged(FileChange.ID)
    /// List → body: the user picked a file in the inspector → record a one-shot
    /// scroll intent the viewport drains, and highlight the row immediately.
    case diffJumpToFile(FileChange.ID)
    /// The viewport consumed the pending scroll target (consume-once).
    case diffScrollTargetConsumed
    /// `?` — toggle the keyboard-shortcuts help overlay.
    case diffShowKeyboardHelp
    /// `/` — request the find bar (Phase 11 entry point).
    case diffBeginFind
    /// `o` — reveal every collapsed gap of a file (declarative whole-file expand,
    /// reuses Phase-7 `ExpansionState.full`).
    case diffExpandWholeFile(fileID: FileChange.ID)
    /// `e` / `⇧E` — grow (`delta > 0`) or re-hide (`delta < 0`) a file's inter-hunk
    /// context (declarative, reuses Phase-7 `ExpansionState`).
    case diffExpandContext(fileID: FileChange.ID, delta: Int)

    // MARK: Phase 4 — neon syntax highlighting driver
    /// Viewport scrolled/resized → (re)issue a windowed highlight for the per-side
    /// visible SOURCE-line `window`, debounced with the injected clock, superseding
    /// any in-flight pass.
    case highlightVisibleRangeChanged(key: DiffDocumentKey, window: VisibleLineWindow)
    /// Both sides' windowed runs came back; applied when `generation` is still live.
    case highlightsReady(
      key: DiffDocumentKey, old: [Int: [StyleRun]], new: [Int: [StyleRun]], generation: Int)

    // MARK: Phase 5 — comments + send-to-agent
    /// Gutter "+"/drag resolved a range. Opens the composer (edit mode if a
    /// comment already covers the identical `(filePath, side, range)`).
    case openCommentComposer(
      filePath: String, source: DiffSource, side: DiffSide, startLine: Int, endLine: Int, anchorSnippet: String,
      contextBefore: String)
    case composer(PresentationAction<CommentComposer.Action>)
    case commentsLoaded([ReviewComment])  // persisted set restored on worktree open (D2)
    case commitComment(ReviewComment)  // upsert (replace by id on edit, else append)
    case editComment(id: UUID)  // open an existing thread to edit
    case deleteComment(id: UUID)  // remove a thread
    case sendBatchToAgent  // serialize + inject into the worktree terminal
    case sendBatchFinished(TextInjectionResult)  // clears lock; on `.sent` clears comments
    case requestDiscardBatch  // close-with-unsent → confirm
    case discardConfirm(PresentationAction<DiscardConfirm>)
    case alert(PresentationAction<Alert>)

    /// Outcome of a batch injection.
    enum TextInjectionResult: Equatable {
      case sent
      case noTerminal
    }
    /// The "no agent terminal" alert has a single dismiss button, no payload.
    enum Alert: Equatable {}
    enum DiscardConfirm: Equatable {
      case discard
    }
  }

  private nonisolated enum CancelID: Hashable, Sendable {
    case load, debounce
    case baseLoad, baseResolve
    case commentsLoad
    case diff(DiffDocumentKey)
    case stream(DiffDocumentKey)
    case highlight(DiffDocumentKey)
    case slice(DiffDocumentKey, Int)  // per (document, gap) blob-slice request
  }

  /// OUR eager-slice cap (NOT a pierre constant): a whole-file / huge-gap expand
  /// reads at most this many lines up front; the viewport windows the rest on
  /// scroll, so a `.whole` never resurrects the O(fileLen) decode we deleted.
  private static let maxEagerSliceLines = 500

  private static let logger = SupaLogger("DiffReview")

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      @Dependency(DiffClient.self) var diffClient
      @Dependency(BlobSliceClient.self) var blobSliceClient
      @Dependency(DiffStreamConsumerClient.self) var diffStreamConsumer
      @Dependency(DiffStreamingEnabledKey.self) var diffStreamingEnabled
      @Dependency(DiffHighlightClient.self) var diffHighlight
      @Dependency(TerminalClient.self) var terminalClient
      @Dependency(GitClientDependency.self) var gitClient
      @Dependency(CommentPersistenceStoreClient.self) var persistenceStore
      @Dependency(\.continuousClock) var clock
      @Dependency(\.date.now) var now
      switch action {

      case .worktreeSelected(let worktree, let prBaseRefName):
        // Any selection change invalidates in-flight results (8.1) for BOTH
        // sources and cancels the load, base load, base resolve, and debounce.
        state.generation &+= 1
        state.baseGeneration &+= 1
        // Comments are per-worktree and disk-persisted (D2). A real worktree change
        // drops the prior in-memory batch so it never leaks across worktrees, then
        // the persisted set for the new worktree is loaded-then-relocated on open;
        // a re-select of the same worktree keeps the in-memory batch untouched.
        let worktreeChanged = state.selectedWorktree?.id != worktree?.id
        if worktreeChanged {
          state.comments.removeAll()
          state.composer = nil
        }
        state.selectedWorktree = worktree
        // Base list resets to hidden on every (re)selection until resolution runs.
        state.baseFiles = []
        state.baseRef = nil
        state.baseLoadState = .idle
        let cancelAll: Effect<Action> = .merge(
          .cancel(id: CancelID.load), .cancel(id: CancelID.debounce),
          .cancel(id: CancelID.baseLoad), .cancel(id: CancelID.baseResolve),
          .cancel(id: CancelID.commentsLoad))
        guard let worktree else {
          state.files = []
          state.loadState = .idle
          state.repositoryOperation = .none
          return cancelAll
        }
        // Gate BEFORE touching the client: never call libgit2 for folder/remote (1.4/1.5).
        // The base resolve/load lives inside this guarded branch, so it is never
        // issued for an unsupported worktree.
        if worktree.isFolder {
          state.files = []
          state.loadState = .unsupported(.folder)
          state.repositoryOperation = .none
          return cancelAll
        }
        if worktree.host != nil {
          state.files = []
          state.loadState = .unsupported(.remote)
          state.repositoryOperation = .none
          return cancelAll
        }
        state.files = []  // new worktree ⇒ drop the prior list
        state.loadState = .loading
        state.baseLoadState = .loading
        var selectionEffects: [Effect<Action>] = [
          Self.loadEffect(worktree: worktree, generation: state.generation, diffClient: diffClient),
          Self.resolveBaseRefEffect(
            worktree: worktree, prBaseRefName: prBaseRefName, generation: state.baseGeneration, gitClient: gitClient),
        ]
        // Load-then-relocate on open: restore the persisted comments for this
        // worktree (they re-anchor against the fresh lines when the diffs load).
        // Only on a real worktree change, so a re-select doesn't clobber the batch.
        if worktreeChanged {
          selectionEffects.append(
            Self.loadPersistedCommentsEffect(worktreeID: worktree.id.rawValue, persistenceStore: persistenceStore))
        }
        return .merge(selectionEffects)

      case .load:
        guard let worktree = state.selectedWorktree,
          !worktree.isFolder, worktree.host == nil
        else { return .none }
        state.generation &+= 1
        // Keep `files` on a re-load so live refresh doesn't flash empty; the row
        // list swaps atomically on `.loaded`.
        if state.files.isEmpty { state.loadState = .loading }
        var effects: [Effect<Action>] = [
          Self.loadEffect(worktree: worktree, generation: state.generation, diffClient: diffClient)
        ]
        // HEAD moving (a new commit) changes `base...HEAD`, so refresh the base
        // list on the tick — against the ALREADY-resolved ref (no re-resolution;
        // that is on-selection only). Base list keeps last-good (no `.loading`
        // flash) and swaps atomically on `.baseLoaded`.
        if let ref = state.baseRef {
          state.baseGeneration &+= 1
          effects.append(
            Self.baseLoadEffect(worktree: worktree, ref: ref, generation: state.baseGeneration, diffClient: diffClient)
          )
        }
        return .merge(effects)

      case .loaded(let files, let operation, let generation):
        guard generation == state.generation else { return .none }  // discard stale (8.1)
        state.files = files
        state.repositoryOperation = operation
        state.loadState = files.isEmpty ? .empty : .loaded
        // Live-update every open working-tree center diff tab: re-diff the ones
        // still changed, flag the vanished ones as stale (tab stays open).
        return Self.refreshOpenDiffs(
          &state, scope: .workingTree, diffClient: diffClient, streamingEnabled: diffStreamingEnabled)

      case .failed(let error, let generation):
        guard generation == state.generation else { return .none }  // discard stale (8.1)
        switch error {
        case .indexLocked:
          // Keep the last-good list; show "updating…" instead of clearing (1.7).
          state.loadState = state.files.isEmpty ? .loading : .refreshing
        default:
          state.loadState = .error(error)
        }
        return .none

      case .baseRefResolved(let ref, let generation):
        guard generation == state.baseGeneration else { return .none }  // discard stale (8.1)
        state.baseRef = ref
        // Nothing resolved (no PR, base branch gone, unusual HEAD) → hide section 2.
        guard let ref else {
          state.baseLoadState = .idle
          return .none
        }
        guard let worktree = state.selectedWorktree else {
          state.baseLoadState = .idle
          return .none
        }
        state.baseLoadState = .loading
        return Self.baseLoadEffect(worktree: worktree, ref: ref, generation: generation, diffClient: diffClient)

      case .baseLoaded(let files, let generation):
        guard generation == state.baseGeneration else { return .none }  // discard stale (8.1)
        state.baseFiles = files
        // `base == HEAD` (no commits ahead) → empty → "up to date with <base>".
        state.baseLoadState = files.isEmpty ? .empty : .loaded
        return Self.refreshOpenDiffs(
          &state, scope: .base, diffClient: diffClient, streamingEnabled: diffStreamingEnabled)

      case .baseFailed(let error, let generation):
        guard generation == state.baseGeneration else { return .none }  // discard stale (8.1)
        switch error {
        case .baseRefUnresolved:
          // Not a user-visible error — the ref stopped resolving; hide section 2.
          state.baseRef = nil
          state.baseLoadState = .idle
        case .indexLocked:
          // Keep the last-good base list; show "updating…" instead of clearing.
          state.baseLoadState = state.baseFiles.isEmpty ? .loading : .refreshing
        default:
          state.baseLoadState = .error(error)
        }
        return .none

      case .filesChanged(let worktreeID):
        // Only the currently selected, supported worktree drives a refresh.
        guard let worktree = state.selectedWorktree, worktree.id == worktreeID,
          !worktree.isFolder, worktree.host == nil
        else { return .none }
        // Coalesce a burst of agent edits into one reload (4.4). cancelInFlight
        // restarts the 250ms window on each new tick.
        return .run { send in
          try await clock.sleep(for: .milliseconds(250))
          await send(.refreshTick)
        }
        .cancellable(id: CancelID.debounce, cancelInFlight: true)

      case .refreshTick:
        return .send(.load)

      case .openFile(let path, let source):
        guard let worktree = state.selectedWorktree else { return .none }
        let key = DiffDocumentKey(path: path, source: source)
        let focusEffect: Effect<Action> = .run { _ in
          // Reducer can't touch the @Observable manager directly; go through the
          // TerminalClient command path (mirrors every other terminal reach-out).
          await terminalClient.send(.openDiffTab(worktree, filePath: path, source: source))
        }
        // Resolve the file from the source's own list.
        let fileList = source == .workingTree ? state.files : state.baseFiles
        // Without file metadata there is nothing to diff — just open/focus the tab.
        guard let file = fileList.first(where: { $0.id == path }) else { return focusEffect }
        // Already open and healthy: focus it, keep its rows (no redundant reload).
        // A prior error re-loads (Retry routes here).
        if let existing = state.openDiffs[key] {
          if case .error = existing.loadState {} else { return focusEffect }
        }
        state.diffLoadToken &+= 1
        let token = state.diffLoadToken
        var document = state.openDiffs[key] ?? DiffDocument(file: file, source: source)
        document.file = file
        document.source = source
        document.loadState = .loading
        document.generation = token
        state.openDiffs[key] = document
        // Streaming path (Phase 9) replaces the single per-file round-trip with a
        // stream pump feeding the tree consumer; gated OFF by default so the
        // per-file `.diffLoaded` hunk path stays authoritative in production.
        let loadEffect: Effect<Action> =
          diffStreamingEnabled
          ? Self.streamEffect(
            StreamRequest(key: key, worktree: worktree, source: source, contextLines: 3, token: token),
            diffClient: diffClient)
          : Self.diffEffect(
            DiffRequest(key: key, file: file, worktree: worktree, contextLines: 3, token: token),
            diffClient: diffClient)
        return .merge(focusEffect, loadEffect)

      case .diffLoaded(let key, let hunks, let token):
        guard var document = state.openDiffs[key], document.generation == token else { return .none }
        document.hunks = hunks
        document.loadState = .loaded
        document.isStale = false
        // A re-diff re-materializes revealed slices against the fresh geometry; the
        // declarative `expansion` (gap-index keyed) persists across the re-diff.
        document.revealed.removeAll()
        // Re-anchor this document's comments against the fresh lines (5.1);
        // orphans are marked, never dropped. The tree-backed viewport projects
        // `hunks` + `comments` directly — no flat row rebuild (Phase 13 swap).
        Self.relocateComments(&state, key: key, lines: hunks.flatMap(\.lines))
        state.openDiffs[key] = document
        return .none

      case .diffFailed(let key, let error, let token):
        guard var document = state.openDiffs[key], document.generation == token else { return .none }
        document.loadState = .error(error)
        state.openDiffs[key] = document
        return .none

      // MARK: Phase 9 — streaming producer↔consumer

      case .streamStarted(let key, let fileCount, let token):
        // Stale drop (8.1): a superseded stream's `.started` never scaffolds.
        guard let document = state.openDiffs[key], document.generation == token else { return .none }
        let mode = state.diffViewMode
        return .run { _ in await diffStreamConsumer.begin(key, fileCount, mode, token) }

      case .streamFileReady(let key, let batch, let token):
        // Stale drop ON ARRIVAL (mirror of the KEPT reducer guard) — belt-and-
        // suspenders with the consumer's own generation check.
        guard var document = state.openDiffs[key], document.generation == token else { return .none }
        let mode = state.diffViewMode
        // Feed the tree consumer (zero-I/O, MainActor).
        let feed: Effect<Action> = .run { _ in await diffStreamConsumer.consume(key, batch, mode) }
        // The batch for THIS document's file also supplies its hunks so the
        // tree-backed viewport re-projects progressively as files stream in.
        guard batch.file.id == key.path else { return feed }
        document.file = batch.file
        document.hunks = batch.hunks
        document.loadState = .loaded
        document.isStale = false
        // Phase 4: capture the correct blob per side (fixes bug #1 — no on-disk read)
        // and evaluate the size gate ONCE on counts, so a deep hunk in a huge file
        // never triggers a contiguous parse. A re-diff changes blobs → drop stale
        // runs; the next `.highlightVisibleRangeChanged` re-queries the fresh blobs.
        let (oldBlob, newBlob) = DiffHighlightDriver.blobInputs(for: batch)
        document.oldBlob = oldBlob
        document.newBlob = newBlob
        // Fully-changed-huge-file gate (Phase 13 `LargeFileRenderPolicy`) — the
        // unified decision over the same per-side counts + the longest rendered line
        // (protects the CTLine byte ceiling from a 2MB minified line). Produces the
        // header affordance so a dropped feature is never silent.
        let changedLines = max(batch.file.removedLines, batch.file.addedLines)
        let longestLine = batch.hunks.reduce(0) { partial, hunk in
          hunk.lines.reduce(partial) { max($0, $1.content.utf16.count) }
        }
        let renderDecision = LargeFileRenderPolicy.decide(
          file: batch.file, changedLines: changedLines, maxLineLength: longestLine)
        // Highlight off when the policy says plain OR the absolute blob-size gate
        // trips (the ≈2.5M-UTF16-unit ceiling `LargeFileRenderPolicy` leaves to the
        // size gate, which reads the decoded blob lengths).
        document.highlightingDisabled =
          !renderDecision.highlight
          || diffHighlight.isPlain(
            batch.file.removedLines, batch.file.addedLines, oldBlob?.utf16.count ?? 0, newBlob?.utf16.count ?? 0)
        // Word-diff gate: the render path never invokes `WordDiff` for a
        // massively-changed / long-lined file (only the row-level `+`/`-` tint).
        document.wordDiffDisabled = !renderDecision.wordDiff
        document.renderBannerKey = renderDecision.bannerKey
        if let banner = renderDecision.bannerKey {
          Self.logger.info("large-file render gate for \(key.path): \(String(describing: banner))")
        }
        document.oldStyleRuns = [:]
        document.newStyleRuns = [:]
        document.styleRunsVersion &+= 1  // cleared — the view repaints without stale colors
        // A re-diff re-materializes revealed slices; the declarative `expansion`
        // (gap-index keyed) survives the line shift (Phase 7).
        document.revealed.removeAll()
        Self.relocateComments(&state, key: key, lines: batch.hunks.flatMap(\.lines))
        state.openDiffs[key] = document
        return feed

      case .streamFinished(let key, let token):
        guard var document = state.openDiffs[key], document.generation == token else { return .none }
        document.loadState = .loaded
        document.isStale = false
        state.openDiffs[key] = document
        return .run { _ in await diffStreamConsumer.finish(key, token) }

      case .diffModeChanged(let mode):
        // The tree is dual-mode: the viewport re-seeks unified↔split with no row
        // rebuild (Phase 8). Only persist the global preference; the representable
        // observes `diffViewMode` and drives `controller.toggleMode` (Phase 13 swap).
        state.$diffViewMode.withLock { $0 = mode }
        return .none

      // MARK: Phase 7 — incremental collapse / expand (blob-slice, NO re-diff)

      case .expandGap(let key, let gap, let step, let direction):
        guard let worktree = state.selectedWorktree, var document = state.openDiffs[key] else { return .none }
        let size = document.gapRangeSize(gap)
        let isTrailing = document.isTrailingGap(gap)
        let before = document.expansion.resolve(gap: gap, rangeSize: size, isTrailing: isTrailing)
        document.expansion.expand(gap: gap, by: step, direction: direction)
        let after = document.expansion.resolve(gap: gap, rangeSize: size, isTrailing: isTrailing)
        state.diffLoadToken &+= 1
        let token = state.diffLoadToken
        document.generation = token
        state.openDiffs[key] = document
        // Only the NEWLY revealed sub-ranges hit the blob (incremental, one gap
        // only) — never `DiffClient.diff` at a raised context. Whole-file: bounded
        // to `maxEagerSliceLines` so it materializes lazily.
        let ranges = document.newlyRevealedRanges(
          gap: gap, before: before, after: after, cap: Self.maxEagerSliceLines)
        guard !ranges.isEmpty else { return .none }
        return Self.sliceEffect(
          SliceRequest(
            key: key, gap: gap, file: document.file, source: key.source, worktree: worktree,
            ranges: ranges, oldLineDelta: document.gapOldLineDelta(gap), token: token),
          blobSliceClient: blobSliceClient)

      case .collapseGap(let key, let gap):
        guard var document = state.openDiffs[key] else { return .none }
        document.expansion.collapse(gap: gap)
        document.revealed[gap] = nil
        state.openDiffs[key] = document
        // Cancel any in-flight slice for this gap and re-insert the (full) expander.
        return .cancel(id: CancelID.slice(key, gap))

      case .gapSliceLoaded(let key, let gap, let lines, let token):
        // Stale drop (mirrors `.diffLoaded`): a superseded expand never appends.
        guard var document = state.openDiffs[key], document.generation == token else { return .none }
        var revealed = document.revealed[gap] ?? []
        var seen = Set(revealed.compactMap(\.newLineNumber))
        for line in lines {
          if let number = line.newLineNumber {
            guard seen.insert(number).inserted else { continue }  // dedup an overlapping re-slice
          }
          revealed.append(line)
        }
        revealed.sort { ($0.newLineNumber ?? 0) < ($1.newLineNumber ?? 0) }
        document.revealed[gap] = revealed
        state.openDiffs[key] = document
        return .none

      case .gapSliceFailed(let key, let gap, let error, let token):
        guard state.openDiffs[key]?.generation == token else { return .none }
        // Non-fatal: the gap stays collapsed (last-good), the user can retry.
        Self.logger.error("gap slice failed for \(key.path) gap \(gap): \(String(describing: error))")
        return .none

      // MARK: Phase 10 — sticky header / keyboard nav / scroll-spy

      case .diffActiveFileChanged(let id):
        // Display-only: highlight the inspector row. NO structural recompute — this
        // reducer is disjoint from the sidebar structure cache (CLAUDE.md sidebar-perf
        // discipline: a display-only mutation must not invalidate unrelated state).
        state.activeFileID = id
        return .none

      case .diffJumpToFile(let id):
        // List → body: record the one-shot scroll intent for the viewport to drain,
        // and highlight the row now so the inspector reflects the pick immediately.
        state.pendingScrollTarget = .file(id)
        state.activeFileID = id
        return .none

      case .diffScrollTargetConsumed:
        state.pendingScrollTarget = nil
        return .none

      case .diffShowKeyboardHelp:
        state.keyboardHelpVisible.toggle()
        return .none

      case .diffBeginFind:
        state.findRequested = true
        return .none

      case .diffExpandWholeFile(let fileID):
        // Declarative whole-file reveal (Phase-7 `ExpansionState.full`). The ChunkTree
        // viewport is a projection of `expansion` (the source of truth) and windows the
        // revealed lines lazily on scroll, so no eager blob slice is needed here — the
        // per-gap `.expandGap` path owns the incremental slice.
        for key in state.openDiffs.keys where key.path == fileID {
          guard var document = state.openDiffs[key], document.expansion != .full else { continue }
          document.expansion = .full
          state.openDiffs[key] = document
        }
        return .none

      case .diffExpandContext(let fileID, let delta):
        for key in state.openDiffs.keys where key.path == fileID {
          guard var document = state.openDiffs[key] else { continue }
          if delta > 0 {
            // Grow every gap's context by one fine step, both ends (`.full` is
            // all-or-nothing and a no-op under `expand`).
            for gap in 0...document.hunks.count {
              document.expansion.expand(gap: gap, by: .fine, direction: .both)
            }
          } else if delta < 0 {
            // Re-hide: drop back to the collapsed default.
            document.expansion = .collapsed
            document.revealed.removeAll()
          } else {
            continue
          }
          state.openDiffs[key] = document
        }
        return .none

      // MARK: Phase 4 — neon syntax highlighting driver

      case .highlightVisibleRangeChanged(let key, let window):
        guard var document = state.openDiffs[key] else { return .none }
        document.visibleLineWindow = window
        // The size gate (set at load) short-circuits before any client is built or
        // any parse runs — a 200k-line / oversized file renders plain, no stall.
        guard !document.highlightingDisabled else {
          state.openDiffs[key] = document
          return .none
        }
        document.highlightGeneration &+= 1
        let generation = document.highlightGeneration
        let old = document.oldBlob
        let new = document.newBlob
        state.openDiffs[key] = document
        // Nothing to highlight on either side (plain-text file / no bundled grammar):
        // still clear any stale runs, but skip the effect.
        guard old != nil || new != nil else { return .none }
        // Each side is queried with ITS OWN visible line range (old / new line numbers
        // differ). The client speaks 1-based line numbers in and out, so the returned
        // runs are keyed exactly how `LineRowView` looks them up.
        return .run { send in
          try await clock.sleep(for: .milliseconds(16))  // coalesce scroll bursts (no Task.sleep)
          let oldRuns = old == nil || window.old.isEmpty ? [:] : await diffHighlight.styleRuns(old!, window.old)
          let newRuns = new == nil || window.new.isEmpty ? [:] : await diffHighlight.styleRuns(new!, window.new)
          await send(.highlightsReady(key: key, old: oldRuns, new: newRuns, generation: generation))
        }
        .cancellable(id: CancelID.highlight(key), cancelInFlight: true)

      case .highlightsReady(let key, let old, let new, let generation):
        // Drop a stale/superseded result (pierre isCurrentRequest) — a re-diff or a
        // newer visible range already bumped `highlightGeneration`.
        guard var document = state.openDiffs[key], generation == document.highlightGeneration else { return .none }
        document.oldStyleRuns = old
        document.newStyleRuns = new
        document.styleRunsVersion &+= 1  // runs ARRIVED — the view keys delivery off this
        state.openDiffs[key] = document
        return .none

      // MARK: Phase 5 — comments

      case .openCommentComposer(
        let filePath, let source, let side, let startLine, let endLine, let snippet, let context):
        // Editing an existing identical-range comment instead of stacking a dup.
        // Scoped by `source` too, so the same range on the working-tree and the
        // base-branch diff are distinct threads.
        if let existing = state.comments.first(where: {
          $0.filePath == filePath && $0.source == source && $0.side == side && $0.startLine == startLine
            && $0.endLine == endLine
        }) {
          state.composer = CommentComposer.State(draft: existing, isEditing: true)
        } else {
          let draft = ReviewComment(
            filePath: filePath,
            source: source,
            side: side,
            startLine: startLine,
            endLine: endLine,
            anchorSnippet: snippet,
            contextBefore: context,
            body: "",
            createdAt: now
          )
          state.composer = CommentComposer.State(draft: draft, isEditing: false)
        }
        return .none

      case .composer(.presented(.delegate(.commit(let comment)))):
        return .send(.commitComment(comment))

      case .composer(.presented(.delegate(.cancel))):
        state.composer = nil
        return .none

      case .composer(.presented(.delegate(.delete(let id)))):
        state.composer = nil
        return .send(.deleteComment(id: id))

      case .composer:
        return .none

      case .commentsLoaded(let loaded):
        // Restore the persisted set for the just-opened worktree (deduped by id
        // against corrupt-disk dup ids). Relocation runs when the diffs load.
        var restored: IdentifiedArrayOf<ReviewComment> = []
        for comment in loaded where restored[id: comment.id] == nil {
          restored[id: comment.id] = comment
        }
        state.comments = restored
        return .none

      case .commitComment(let comment):
        // Source of truth is `state.comments`; the viewport reconciles the tree
        // widget (O(log n) insert / update) — NO flat `rebuildRows` (S7).
        var committed = comment
        committed.updatedAt = now
        state.comments[id: committed.id] = committed
        state.composer = nil
        return Self.persistEffect(state, persistenceStore: persistenceStore)

      case .editComment(let id):
        guard let comment = state.comments[id: id] else { return .none }
        state.composer = CommentComposer.State(draft: comment, isEditing: true)
        return .none

      case .deleteComment(let id):
        guard state.comments[id: id] != nil else { return .none }
        state.comments.remove(id: id)  // viewport removes the widget leaf; NO rebuildRows (S7)
        return Self.persistEffect(state, persistenceStore: persistenceStore)

      case .sendBatchToAgent:
        guard !state.batchLocked,
          let worktree = state.selectedWorktree,
          let output = ReviewPromptBuilder.build(Array(state.comments))
        else { return .none }
        guard terminalClient.hasAgentTerminalSurface(worktree.id) else {
          state.discardConfirm = nil
          state.alert = .noAgentTerminal
          return .none
        }
        state.batchLocked = true
        return .merge(
          .run { _ in
            await terminalClient.send(.insertTextIntoFocusedSurface(worktree, text: output.markdown, submit: true))
          },
          // Optimistic; a same-tick `.textInjectionFailed` routes `.noTerminal`.
          .send(.sendBatchFinished(.sent))
        )

      case .sendBatchFinished(.sent):
        state.comments.removeAll()
        state.batchLocked = false
        // The sent batch is cleared everywhere; persist the empty set so a reopen
        // shows no ghost comments. The viewport drops the widget leaves (NO
        // rebuildRows, S7).
        return Self.persistEffect(state, persistenceStore: persistenceStore)

      case .sendBatchFinished(.noTerminal):
        state.batchLocked = false
        state.alert = .noAgentTerminal
        return .none

      case .requestDiscardBatch:
        guard !state.comments.isEmpty, !state.batchLocked else { return .none }
        state.discardConfirm = Self.discardConfirmDialog(count: state.comments.count)
        return .none

      case .discardConfirm(.presented(.discard)):
        state.comments.removeAll()
        return Self.persistEffect(state, persistenceStore: persistenceStore)

      case .discardConfirm:
        return .none

      case .alert:
        return .none
      }
    }
    .ifLet(\.$composer, action: \.composer) {
      CommentComposer()
    }
    .ifLet(\.$alert, action: \.alert)
    .ifLet(\.$discardConfirm, action: \.discardConfirm)
  }

  /// Tags the request with `generation`; the return is checked against the live
  /// generation in `.loaded/.failed`, so a late result after a selection change
  /// is dropped. `static` so the `@Sendable` `Reduce` closure can call it under
  /// the module's default main-actor isolation (mirrors the feature's peers).
  private static func loadEffect(
    worktree: Worktree,
    generation: Int,
    diffClient: DiffClient
  ) -> Effect<Action> {
    .run { send in
      do {
        // Phase 1 returns `WorktreeDiff`; the row list consumes `.files` and the
        // mid-operation banner consumes `.operation`.
        let diff = try await diffClient.changedFiles(.workingTree, worktree.workingDirectory)
        await send(.loaded(diff.files, operation: diff.operation, generation: generation))
      } catch let error as DiffError {
        await send(.failed(error, generation: generation))
      } catch {
        await send(.failed(.libgit2(code: -1, message: "\(error)"), generation: generation))
      }
    }
    .cancellable(id: CancelID.load, cancelInFlight: true)
  }

  /// Persist the current comment set for the selected worktree (fire-and-forget;
  /// source of truth stays `state.comments`). No-op when nothing is selected.
  private static func persistEffect(
    _ state: State, persistenceStore: CommentPersistenceStoreClient
  ) -> Effect<Action> {
    guard let worktreeID = state.selectedWorktree?.id.rawValue else { return .none }
    let comments = Array(state.comments)
    return .run { _ in await persistenceStore.save(worktreeID, comments) }
  }

  /// Load the persisted comments for a worktree on open, feeding them back as
  /// `.commentsLoaded` only when non-empty (so a fresh worktree adds no action).
  /// `cancelInFlight` so a rapid re-selection supersedes a slow disk read (8.1).
  private static func loadPersistedCommentsEffect(
    worktreeID: String, persistenceStore: CommentPersistenceStoreClient
  ) -> Effect<Action> {
    .run { send in
      let loaded = await persistenceStore.load(worktreeID)
      guard !loaded.isEmpty else { return }
      await send(.commentsLoaded(loaded))
    }
    .cancellable(id: CancelID.commentsLoad, cancelInFlight: true)
  }

  /// Re-anchors every comment for `key` (matched on both `filePath` and
  /// `source`) against the freshly re-diffed `lines` (5.1). A comment whose
  /// lines vanished is marked `orphaned`, never removed.
  private static func relocateComments(_ state: inout State, key: DiffDocumentKey, lines: [DiffLine]) {
    for comment in state.comments where comment.filePath == key.path && comment.source == key.source {
      state.comments[id: comment.id] = CommentAnchor.relocate(comment, in: lines, side: comment.side)
    }
  }

  /// Single dismiss-only alert for the missing-terminal case (5.7).
  static func discardConfirmDialog(count: Int) -> ConfirmationDialogState<Action.DiscardConfirm> {
    ConfirmationDialogState {
      TextState("Discard \(count) comment\(count == 1 ? "" : "s")?")
    } actions: {
      ButtonState(role: .destructive, action: .discard) {
        TextState("Discard")
      }
      ButtonState(role: .cancel) {
        TextState("Keep")
      }
    } message: {
      TextState("These review comments haven't been sent to the agent yet.")
    }
  }

  /// Fetches one file's hunks (generation-guarded, 8.1) and feeds them back as
  /// `.diffLoaded` (or `.diffFailed`). Cancellable per path so a re-diff replaces
  /// any in-flight request for the same file.
  /// One per-file hunk request (grouped so the effect factory stays a two-arg
  /// call site).
  private struct DiffRequest {
    let key: DiffDocumentKey
    let file: FileChange
    let worktree: Worktree
    let contextLines: UInt32
    let token: Int
  }

  private static func diffEffect(_ request: DiffRequest, diffClient: DiffClient) -> Effect<Action> {
    .run { send in
      do {
        let hunks = try await diffClient.diff(
          request.file,
          request.worktree.workingDirectory,
          request.contextLines,
          request.key.source
        )
        await send(.diffLoaded(key: request.key, hunks: hunks, token: request.token))
      } catch let error as DiffError {
        await send(.diffFailed(key: request.key, error, token: request.token))
      } catch {
        await send(.diffFailed(key: request.key, .libgit2(code: -1, message: "\(error)"), token: request.token))
      }
    }
    .cancellable(id: CancelID.diff(request.key), cancelInFlight: true)
  }

  /// One incremental blob-slice request: the newly-revealed NEW-side sub-ranges of
  /// a single gap (top + bottom fit in one effect so a two-ended expand does not
  /// self-cancel under a shared `CancelID`).
  private struct SliceRequest {
    let key: DiffDocumentKey
    let gap: Int
    let file: FileChange
    let source: DiffSource
    let worktree: Worktree
    let ranges: [Range<Int>]
    let oldLineDelta: Int
    let token: Int
  }

  /// Mirrors `diffEffect` (`:652-669`) for the incremental path: reads the blob for
  /// only the newly-revealed ranges — NEVER `git_diff_*` — and feeds them back as
  /// `.gapSliceLoaded` / `.gapSliceFailed`. `.cancellable` per `(key, gap)` so a
  /// rapid re-expand of the same gap supersedes the in-flight slice.
  private static func sliceEffect(_ request: SliceRequest, blobSliceClient: BlobSliceClient) -> Effect<Action> {
    .run { send in
      do {
        var lines: [DiffLine] = []
        for range in request.ranges {
          lines += try await blobSliceClient.slice(
            request.file, request.worktree.workingDirectory, request.source, range, request.oldLineDelta)
        }
        await send(.gapSliceLoaded(key: request.key, gap: request.gap, lines: lines, token: request.token))
      } catch let error as DiffError {
        await send(.gapSliceFailed(key: request.key, gap: request.gap, error, token: request.token))
      } catch {
        await send(
          .gapSliceFailed(
            key: request.key, gap: request.gap, .libgit2(code: -1, message: "\(error)"), token: request.token))
      }
    }
    .cancellable(id: CancelID.slice(request.key, request.gap), cancelInFlight: true)
  }

  /// The whole-`source` stream request for one open document (Phase 9). The
  /// producer streams every file's batch; the reducer routes THIS document's file
  /// to its rows and feeds every batch to the tree consumer.
  private struct StreamRequest {
    let key: DiffDocumentKey
    let worktree: Worktree
    let source: DiffSource
    let contextLines: UInt32
    let token: Int
  }

  /// Pumps `diffClient.stream` into `.streamStarted` / `.streamFileReady` /
  /// `.streamFinished`, generation-guarded by `token`. `.cancellable` per key so a
  /// re-diff cancels the in-flight stream (cooperative cancel at the next file
  /// boundary). Errors surface as `.diffFailed` (keep last-good, existing path).
  private static func streamEffect(_ request: StreamRequest, diffClient: DiffClient) -> Effect<Action> {
    .run { send in
      do {
        for try await event in diffClient.stream(
          request.source, request.worktree.workingDirectory, request.contextLines, request.token)
        {
          switch event {
          case .started(let fileCount, _, _):
            await send(.streamStarted(key: request.key, fileCount: fileCount, token: request.token))
          case .fileReady(let batch):
            await send(.streamFileReady(key: request.key, batch: batch, token: request.token))
          case .finished:
            await send(.streamFinished(key: request.key, token: request.token))
          }
        }
      } catch let error as DiffError {
        await send(.diffFailed(key: request.key, error, token: request.token))
      } catch {
        await send(.diffFailed(key: request.key, .libgit2(code: -1, message: "\(error)"), token: request.token))
      }
    }
    .cancellable(id: CancelID.stream(request.key), cancelInFlight: true)
  }

  /// Which open documents `refreshOpenDiffs` touches after a list reload. Keeps
  /// a working-tree `.loaded` from re-diffing base tabs (and vice versa) — each
  /// source's reload only refreshes its own open tabs.
  private enum RefreshScope { case workingTree, base }

  /// Live-update fan-out for open center diff tabs after the changed-file list
  /// reloads: re-diff the ones still in the set, flag the vanished ones as stale
  /// while keeping the tab and its last rows (3.2/3.3). Scoped to one `source`
  /// so it looks each document up in the matching file list.
  private static func refreshOpenDiffs(
    _ state: inout State, scope: RefreshScope, diffClient: DiffClient, streamingEnabled: Bool
  ) -> Effect<Action> {
    guard let worktree = state.selectedWorktree, !state.openDiffs.isEmpty else { return .none }
    let fileList = scope == .workingTree ? state.files : state.baseFiles
    var effects: [Effect<Action>] = []
    for key in state.openDiffs.keys {
      let isWorkingTree = key.source == .workingTree
      guard (scope == .workingTree) == isWorkingTree else { continue }
      guard var document = state.openDiffs[key] else { continue }
      guard let file = fileList.first(where: { $0.id == key.path }) else {
        document.isStale = true
        state.openDiffs[key] = document
        continue
      }
      document.file = file
      document.isStale = false
      state.diffLoadToken &+= 1
      let token = state.diffLoadToken
      document.generation = token
      state.openDiffs[key] = document
      // Always the git-default context 3 (the render collapse is orthogonal — it
      // lives in `ExpansionState`, materialized incrementally by the viewport, not
      // in a raised libgit2 `context_lines`). Streaming re-diffs incrementally
      // (unchanged files reuse their sub-trees, only edited hunks re-splice).
      if streamingEnabled {
        effects.append(
          Self.streamEffect(
            StreamRequest(key: key, worktree: worktree, source: key.source, contextLines: 3, token: token),
            diffClient: diffClient
          )
        )
      } else {
        effects.append(
          Self.diffEffect(
            DiffRequest(key: key, file: file, worktree: worktree, contextLines: 3, token: token),
            diffClient: diffClient
          )
        )
      }
    }
    return .merge(effects)
  }

  /// Resolves the base ref (PR base → default-branch fallback) off the main
  /// thread, then feeds it back as `.baseRefResolved`. `cancelInFlight` so a new
  /// selection cancels a slow in-flight resolution (8.1). Re-resolution is
  /// on-selection only — never re-run on a `filesChanged` tick.
  private static func resolveBaseRefEffect(
    worktree: Worktree,
    prBaseRefName: String?,
    generation: Int,
    gitClient: GitClientDependency
  ) -> Effect<Action> {
    .run { send in
      let ref = await DiffBaseRefResolver.resolve(
        prBaseRefName: prBaseRefName,
        repositoryRoot: worktree.repositoryRootURL,
        gitClient: gitClient
      )
      await send(.baseRefResolved(ref: ref, generation: generation))
    }
    .cancellable(id: CancelID.baseResolve, cancelInFlight: true)
  }

  /// Loads the base (three-dot `merge-base..HEAD`) changed-file list against the
  /// already-resolved `ref`, generation-guarded by `baseGeneration` (8.1).
  private static func baseLoadEffect(
    worktree: Worktree,
    ref: String,
    generation: Int,
    diffClient: DiffClient
  ) -> Effect<Action> {
    .run { send in
      do {
        let diff = try await diffClient.changedFiles(.baseBranch(ref: ref), worktree.workingDirectory)
        await send(.baseLoaded(diff.files, generation: generation))
      } catch let error as DiffError {
        await send(.baseFailed(error, generation: generation))
      } catch {
        await send(.baseFailed(.libgit2(code: -1, message: "\(error)"), generation: generation))
      }
    }
    .cancellable(id: CancelID.baseLoad, cancelInFlight: true)
  }
}

extension AlertState where Action == DiffReviewFeature.Action.Alert {
  /// "No agent terminal to send to." — dismiss-only (5.7).
  static var noAgentTerminal: Self {
    AlertState {
      TextState("No agent terminal to send to")
    } actions: {
      ButtonState(role: .cancel) {
        TextState("OK")
      }
    } message: {
      TextState("Open a terminal tab in this worktree, then send your review comments again.")
    }
  }
}
