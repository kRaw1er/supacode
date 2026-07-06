import ComposableArchitecture
import Foundation
import Sharing

/// Canonical (owned by Phase 2). Unified vs split viewer preference. Phase 3 consumes this exact
/// type + key — it must NOT define a parallel `DiffMode` / `"diffMode"`.
enum DiffViewMode: String, Codable, Sendable, Equatable, CaseIterable { case unified, split }

/// Per-open-file diff document living in `DiffReviewFeature.State.openDiffs`,
/// keyed by file path. Owns everything the center diff tab renders: the file
/// metadata, the raw hunks (kept so a mode toggle rebuilds rows without I/O),
/// the flat `[DiffRow]` for the viewer, the load state, the "no longer changed"
/// stale flag, the set of user-expanded gap anchors, and a monotonic `revision`
/// the viewer watches to re-apply while preserving scroll.
struct DiffDocument: Equatable, Sendable {
  var file: FileChange
  /// Which diff this document renders. Part of its `DiffDocumentKey` identity so
  /// a working-tree tab and a base-branch tab of the same file are distinct.
  var source: DiffSource = .workingTree
  var hunks: [DiffHunk] = []
  var rows: [DiffRow] = []
  var loadState: LoadState = .loading
  var isStale: Bool = false
  var expanded: Set<Int> = []
  var revision: Int = 0
  /// Generation guard for this document's in-flight `diff` request (8.1). A
  /// returning `.diffLoaded/.diffFailed` whose token no longer matches is dropped.
  var generation: Int = 0

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
    case streamFinished(key: DiffDocumentKey, token: Int)  // `.finished` → mark loaded, bump revision
    case diffModeChanged(DiffViewMode)  // unified/split toggle → rebuild all open docs
    case expandGap(path: String, source: DiffSource, anchor: Int)  // expander tap → re-diff with raised context

    // MARK: Phase 5 — comments + send-to-agent
    /// Gutter "+"/drag resolved a range. Opens the composer (edit mode if a
    /// comment already covers the identical `(filePath, side, range)`).
    case openCommentComposer(
      filePath: String, source: DiffSource, side: DiffSide, startLine: Int, endLine: Int, anchorSnippet: String,
      contextBefore: String)
    case composer(PresentationAction<CommentComposer.Action>)
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
    case diff(DiffDocumentKey)
    case stream(DiffDocumentKey)
  }

  /// libgit2 `context_lines` used to materialize an expanded gap. High enough to
  /// pull the full unchanged region into the hunk; the builder then shows the
  /// whole file (the expander is a "reveal everything" affordance in v1).
  private static let expandedContextLines: UInt32 = 1_000_000

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      @Dependency(DiffClient.self) var diffClient
      @Dependency(DiffStreamConsumerClient.self) var diffStreamConsumer
      @Dependency(DiffStreamingEnabledKey.self) var diffStreamingEnabled
      @Dependency(TerminalClient.self) var terminalClient
      @Dependency(GitClientDependency.self) var gitClient
      @Dependency(\.continuousClock) var clock
      @Dependency(\.date.now) var now
      switch action {

      case .worktreeSelected(let worktree, let prBaseRefName):
        // Any selection change invalidates in-flight results (8.1) for BOTH
        // sources and cancels the load, base load, base resolve, and debounce.
        state.generation &+= 1
        state.baseGeneration &+= 1
        // Comments are per-worktree and session-only (not persisted). A real
        // worktree change drops the prior batch so it never leaks across
        // worktrees; a re-select of the same worktree keeps it.
        if state.selectedWorktree?.id != worktree?.id {
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
          .cancel(id: CancelID.baseLoad), .cancel(id: CancelID.baseResolve))
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
        return .merge(
          Self.loadEffect(worktree: worktree, generation: state.generation, diffClient: diffClient),
          Self.resolveBaseRefEffect(
            worktree: worktree, prBaseRefName: prBaseRefName, generation: state.baseGeneration, gitClient: gitClient)
        )

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
        // stream pump feeding the tree consumer; gated OFF until the P13 seam flip
        // so the live `[DiffRow]` path stays authoritative in production.
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
        // Re-anchor this document's comments against the fresh lines (5.1);
        // orphans are marked, never dropped.
        Self.relocateComments(&state, key: key, lines: hunks.flatMap(\.lines))
        document.rows = Self.buildRows(
          document: document, mode: state.diffViewMode, comments: state.comments(forPath: key.path, source: key.source))
        document.revision &+= 1
        state.openDiffs[key] = document
        return .none

      case .diffFailed(let key, let error, let token):
        guard var document = state.openDiffs[key], document.generation == token else { return .none }
        document.loadState = .error(error)
        document.revision &+= 1
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
        // The batch for THIS document's file also supplies its hunks/rows so the
        // live `[DiffRow]` view renders progressively (until the P13 seam flip
        // retires `rows` for the tree-backed viewport).
        guard batch.file.id == key.path else { return feed }
        document.file = batch.file
        document.hunks = batch.hunks
        document.loadState = .loaded
        document.isStale = false
        Self.relocateComments(&state, key: key, lines: batch.hunks.flatMap(\.lines))
        document.rows = Self.buildRows(
          document: document, mode: mode, comments: state.comments(forPath: key.path, source: key.source))
        document.revision &+= 1
        state.openDiffs[key] = document
        return feed

      case .streamFinished(let key, let token):
        guard var document = state.openDiffs[key], document.generation == token else { return .none }
        document.loadState = .loaded
        document.isStale = false
        document.revision &+= 1
        state.openDiffs[key] = document
        return .run { _ in await diffStreamConsumer.finish(key, token) }

      case .diffModeChanged(let mode):
        state.$diffViewMode.withLock { $0 = mode }
        // Rebuild every open document's rows from its cached hunks (no I/O).
        for key in state.openDiffs.keys {
          guard var document = state.openDiffs[key] else { continue }
          document.rows = Self.buildRows(
            document: document, mode: mode, comments: state.comments(forPath: key.path, source: key.source))
          document.revision &+= 1
          state.openDiffs[key] = document
        }
        return .none

      case .expandGap(let path, let source, let anchor):
        let key = DiffDocumentKey(path: path, source: source)
        guard let worktree = state.selectedWorktree, var document = state.openDiffs[key] else { return .none }
        document.expanded.insert(anchor)
        state.diffLoadToken &+= 1
        let token = state.diffLoadToken
        document.generation = token
        state.openDiffs[key] = document
        // Re-diff with full context so the gap's real lines materialize; the
        // rebuild (in `.diffLoaded`) then shows the whole file.
        return Self.diffEffect(
          DiffRequest(
            key: key,
            file: document.file,
            worktree: worktree,
            contextLines: Self.expandedContextLines,
            token: token
          ),
          diffClient: diffClient
        )

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

      case .commitComment(let comment):
        state.comments[id: comment.id] = comment
        state.composer = nil
        Self.rebuildRows(&state, key: DiffDocumentKey(path: comment.filePath, source: comment.source))
        return .none

      case .editComment(let id):
        guard let comment = state.comments[id: id] else { return .none }
        state.composer = CommentComposer.State(draft: comment, isEditing: true)
        return .none

      case .deleteComment(let id):
        guard let comment = state.comments[id: id] else { return .none }
        state.comments.remove(id: id)
        Self.rebuildRows(&state, key: DiffDocumentKey(path: comment.filePath, source: comment.source))
        return .none

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
        // Drop the now-stale comment threads from every open document.
        for key in state.openDiffs.keys {
          Self.rebuildRows(&state, key: key)
        }
        return .none

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
        for key in state.openDiffs.keys {
          Self.rebuildRows(&state, key: key)
        }
        return .none

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

  /// Builds the flat row list for a document. When the user has expanded a gap,
  /// collapsing is disabled (threshold → max) so the full-context re-diff renders
  /// the whole file.
  private static func buildRows(
    document: DiffDocument,
    mode: DiffViewMode,
    comments: [ReviewComment] = []
  ) -> [DiffRow] {
    DiffRowBuilder.build(
      file: document.file,
      hunks: document.hunks,
      mode: mode,
      expanded: document.expanded,
      options: DiffRowBuilder.Options(collapseThreshold: document.expanded.isEmpty ? 10 : .max),
      comments: comments
    )
  }

  /// Rebuilds one open document's rows from its cached hunks + the current
  /// comments for its `(path, source)`, bumping `revision` so the viewer
  /// re-applies. No I/O.
  private static func rebuildRows(_ state: inout State, key: DiffDocumentKey) {
    guard var document = state.openDiffs[key] else { return }
    document.rows = Self.buildRows(
      document: document, mode: state.diffViewMode, comments: state.comments(forPath: key.path, source: key.source))
    document.revision &+= 1
    state.openDiffs[key] = document
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
      // Non-expanded docs re-stream (Phase 9 incremental re-diff: unchanged files
      // reuse their sub-trees, only edited hunks re-splice). An expanded doc still
      // needs a per-file full-context re-diff, which the whole-`source` stream
      // can't express, so it stays on `diffEffect`.
      if streamingEnabled, document.expanded.isEmpty {
        effects.append(
          Self.streamEffect(
            StreamRequest(key: key, worktree: worktree, source: key.source, contextLines: 3, token: token),
            diffClient: diffClient
          )
        )
      } else {
        let contextLines: UInt32 = document.expanded.isEmpty ? 3 : Self.expandedContextLines
        effects.append(
          Self.diffEffect(
            DiffRequest(key: key, file: file, worktree: worktree, contextLines: contextLines, token: token),
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
