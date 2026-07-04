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

    /// Open center diff tabs, keyed by file path. Additive over the Phase 2 state
    /// (Phase 0's `DiffTabPayload` stays `filePath`-only; the document lives here).
    var openDiffs: [String: DiffDocument] = [:]
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

    /// Comments scoped to one diff tab (grouped by `filePath`).
    func commentsForPath(_ path: String) -> [ReviewComment] {
      comments.filter { $0.filePath == path }
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
  }

  enum Action: Equatable {
    case worktreeSelected(Worktree?)  // fan-out from AppFeature :313
    case load  // (re)issue a changedFiles request
    case loaded([FileChange], operation: RepositoryOperation, generation: Int)  // client success
    case failed(DiffError, generation: Int)  // client failure
    case filesChanged(Worktree.ID)  // raw info-event tick (pre-debounce)
    case refreshTick  // post-debounce: re-load
    case openFile(path: String)  // row tap → open center diff tab
    case diffLoaded(path: String, hunks: [DiffHunk], token: Int)  // per-file hunk load success
    case diffFailed(path: String, DiffError, token: Int)  // per-file hunk load failure
    case diffModeChanged(DiffViewMode)  // unified/split toggle → rebuild all open docs
    case expandGap(path: String, anchor: Int)  // expander tap → re-diff with raised context

    // MARK: Phase 5 — comments + send-to-agent
    /// Gutter "+"/drag resolved a range. Opens the composer (edit mode if a
    /// comment already covers the identical `(filePath, side, range)`).
    case openCommentComposer(
      filePath: String, side: DiffSide, startLine: Int, endLine: Int, anchorSnippet: String, contextBefore: String)
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
    case diff(String)
  }

  /// libgit2 `context_lines` used to materialize an expanded gap. High enough to
  /// pull the full unchanged region into the hunk; the builder then shows the
  /// whole file (the expander is a "reveal everything" affordance in v1).
  private static let expandedContextLines: UInt32 = 1_000_000

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      @Dependency(DiffClient.self) var diffClient
      @Dependency(TerminalClient.self) var terminalClient
      @Dependency(\.continuousClock) var clock
      @Dependency(\.date.now) var now
      switch action {

      case .worktreeSelected(let worktree):
        // Any selection change invalidates in-flight results (8.1) and cancels
        // both the load and a pending debounce.
        state.generation &+= 1
        // Comments are per-worktree and session-only (not persisted). A real
        // worktree change drops the prior batch so it never leaks across
        // worktrees; a re-select of the same worktree keeps it.
        if state.selectedWorktree?.id != worktree?.id {
          state.comments.removeAll()
          state.composer = nil
        }
        state.selectedWorktree = worktree
        guard let worktree else {
          state.files = []
          state.loadState = .idle
          state.repositoryOperation = .none
          return .merge(.cancel(id: CancelID.load), .cancel(id: CancelID.debounce))
        }
        // Gate BEFORE touching the client: never call libgit2 for folder/remote (1.4/1.5).
        if worktree.isFolder {
          state.files = []
          state.loadState = .unsupported(.folder)
          state.repositoryOperation = .none
          return .merge(.cancel(id: CancelID.load), .cancel(id: CancelID.debounce))
        }
        if worktree.host != nil {
          state.files = []
          state.loadState = .unsupported(.remote)
          state.repositoryOperation = .none
          return .merge(.cancel(id: CancelID.load), .cancel(id: CancelID.debounce))
        }
        state.files = []  // new worktree ⇒ drop the prior list
        state.loadState = .loading
        return Self.loadEffect(worktree: worktree, generation: state.generation, diffClient: diffClient)

      case .load:
        guard let worktree = state.selectedWorktree,
          !worktree.isFolder, worktree.host == nil
        else { return .none }
        state.generation &+= 1
        // Keep `files` on a re-load so live refresh doesn't flash empty; the row
        // list swaps atomically on `.loaded`.
        if state.files.isEmpty { state.loadState = .loading }
        return Self.loadEffect(worktree: worktree, generation: state.generation, diffClient: diffClient)

      case .loaded(let files, let operation, let generation):
        guard generation == state.generation else { return .none }  // discard stale (8.1)
        state.files = files
        state.repositoryOperation = operation
        state.loadState = files.isEmpty ? .empty : .loaded
        // Live-update every open center diff tab: re-diff the ones still changed,
        // flag the ones that dropped out of the set as stale (tab stays open).
        return Self.refreshOpenDiffs(&state, diffClient: diffClient)

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

      case .openFile(let path):
        guard let worktree = state.selectedWorktree else { return .none }
        let focusEffect: Effect<Action> = .run { _ in
          // Reducer can't touch the @Observable manager directly; go through the
          // TerminalClient command path (mirrors every other terminal reach-out).
          await terminalClient.send(.openDiffTab(worktree, filePath: path))
        }
        // Without file metadata there is nothing to diff — just open/focus the tab.
        guard let file = state.files.first(where: { $0.id == path }) else { return focusEffect }
        // Already open and healthy: focus it, keep its rows (no redundant reload).
        // A prior error re-loads (Retry routes here).
        if let existing = state.openDiffs[path] {
          if case .error = existing.loadState {} else { return focusEffect }
        }
        state.diffLoadToken &+= 1
        let token = state.diffLoadToken
        var document = state.openDiffs[path] ?? DiffDocument(file: file)
        document.file = file
        document.loadState = .loading
        document.generation = token
        state.openDiffs[path] = document
        return .merge(
          focusEffect,
          Self.diffEffect(
            DiffRequest(path: path, file: file, worktree: worktree, contextLines: 3, token: token),
            diffClient: diffClient
          )
        )

      case .diffLoaded(let path, let hunks, let token):
        guard var document = state.openDiffs[path], document.generation == token else { return .none }
        document.hunks = hunks
        document.loadState = .loaded
        document.isStale = false
        // Re-anchor this file's comments against the fresh lines (5.1); orphans
        // are marked, never dropped.
        Self.relocateComments(&state, path: path, lines: hunks.flatMap(\.lines))
        document.rows = Self.buildRows(
          document: document, mode: state.diffViewMode, comments: state.commentsForPath(path))
        document.revision &+= 1
        state.openDiffs[path] = document
        return .none

      case .diffFailed(let path, let error, let token):
        guard var document = state.openDiffs[path], document.generation == token else { return .none }
        document.loadState = .error(error)
        document.revision &+= 1
        state.openDiffs[path] = document
        return .none

      case .diffModeChanged(let mode):
        state.$diffViewMode.withLock { $0 = mode }
        // Rebuild every open document's rows from its cached hunks (no I/O).
        for path in state.openDiffs.keys {
          guard var document = state.openDiffs[path] else { continue }
          document.rows = Self.buildRows(document: document, mode: mode, comments: state.commentsForPath(path))
          document.revision &+= 1
          state.openDiffs[path] = document
        }
        return .none

      case .expandGap(let path, let anchor):
        guard let worktree = state.selectedWorktree, var document = state.openDiffs[path] else { return .none }
        document.expanded.insert(anchor)
        state.diffLoadToken &+= 1
        let token = state.diffLoadToken
        document.generation = token
        state.openDiffs[path] = document
        // Re-diff with full context so the gap's real lines materialize; the
        // rebuild (in `.diffLoaded`) then shows the whole file.
        return Self.diffEffect(
          DiffRequest(
            path: path,
            file: document.file,
            worktree: worktree,
            contextLines: Self.expandedContextLines,
            token: token
          ),
          diffClient: diffClient
        )

      // MARK: Phase 5 — comments

      case .openCommentComposer(let filePath, let side, let startLine, let endLine, let snippet, let context):
        // Editing an existing identical-range comment instead of stacking a dup.
        if let existing = state.comments.first(where: {
          $0.filePath == filePath && $0.side == side && $0.startLine == startLine && $0.endLine == endLine
        }) {
          state.composer = CommentComposer.State(draft: existing, isEditing: true)
        } else {
          let draft = ReviewComment(
            filePath: filePath,
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
        Self.rebuildRows(&state, path: comment.filePath)
        return .none

      case .editComment(let id):
        guard let comment = state.comments[id: id] else { return .none }
        state.composer = CommentComposer.State(draft: comment, isEditing: true)
        return .none

      case .deleteComment(let id):
        guard let comment = state.comments[id: id] else { return .none }
        state.comments.remove(id: id)
        Self.rebuildRows(&state, path: comment.filePath)
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
        for path in state.openDiffs.keys {
          Self.rebuildRows(&state, path: path)
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
        for path in state.openDiffs.keys {
          Self.rebuildRows(&state, path: path)
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
  /// comments for its path, bumping `revision` so the viewer re-applies. No I/O.
  private static func rebuildRows(_ state: inout State, path: String) {
    guard var document = state.openDiffs[path] else { return }
    document.rows = Self.buildRows(
      document: document, mode: state.diffViewMode, comments: state.commentsForPath(path))
    document.revision &+= 1
    state.openDiffs[path] = document
  }

  /// Re-anchors every comment for `path` against the freshly re-diffed `lines`
  /// (5.1). A comment whose lines vanished is marked `orphaned`, never removed.
  private static func relocateComments(_ state: inout State, path: String, lines: [DiffLine]) {
    for comment in state.comments where comment.filePath == path {
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
    let path: String
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
          .workingTree
        )
        await send(.diffLoaded(path: request.path, hunks: hunks, token: request.token))
      } catch let error as DiffError {
        await send(.diffFailed(path: request.path, error, token: request.token))
      } catch {
        await send(.diffFailed(path: request.path, .libgit2(code: -1, message: "\(error)"), token: request.token))
      }
    }
    .cancellable(id: CancelID.diff(request.path), cancelInFlight: true)
  }

  /// Live-update fan-out for open center diff tabs after the changed-file list
  /// reloads: re-diff the ones still in the set, flag the vanished ones as stale
  /// while keeping the tab and its last rows (3.2/3.3).
  private static func refreshOpenDiffs(_ state: inout State, diffClient: DiffClient) -> Effect<Action> {
    guard let worktree = state.selectedWorktree, !state.openDiffs.isEmpty else { return .none }
    var effects: [Effect<Action>] = []
    for path in state.openDiffs.keys {
      guard var document = state.openDiffs[path] else { continue }
      guard let file = state.files.first(where: { $0.id == path }) else {
        document.isStale = true
        state.openDiffs[path] = document
        continue
      }
      document.file = file
      document.isStale = false
      state.diffLoadToken &+= 1
      let token = state.diffLoadToken
      document.generation = token
      state.openDiffs[path] = document
      let contextLines: UInt32 = document.expanded.isEmpty ? 3 : Self.expandedContextLines
      effects.append(
        Self.diffEffect(
          DiffRequest(path: path, file: file, worktree: worktree, contextLines: contextLines, token: token),
          diffClient: diffClient
        )
      )
    }
    return .merge(effects)
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
