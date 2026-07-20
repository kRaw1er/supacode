import AppKit
import DequeModule

/// A recycled viewport view that must reset its borrowed state when it scrolls
/// off / is swapped to a new element. Ports CodeEditTextView's implicit reuse
/// contract + pierre's `onPostRenderPhase` unmount (B §20): the previous
/// element's teardown runs BEFORE the view is handed to a new borrower, so a
/// recycled row can never show a ghost of the prior line. Phase 6 extends this
/// with the widget-host mount / update / unmount lifecycle.
@MainActor
protocol DiffViewportRecyclable: NSView {
  /// Called exactly once as the view is enqueued (recycled off-screen). Clear
  /// stale content and restore the canonical reusable baseline.
  func prepareForReuse()
}

/// A keyed pool of reusable views — ported from CodeEditTextView
/// `Utils/ViewReuseQueue.swift` (`getOrCreateView(forKey:createView:)`,
/// `getView(forKey:)`, `enqueueView(forKey:)`, `enqueueViews(notInSet:)`) over a
/// `Deque<View> queued` free-list + `[Key: View] used` in-use map.
///
/// The viewport holds **one pool per `DiffReuseKind`** and the per-pool key is
/// the hit's `ChunkID`. Heterogeneous kinds MUST NOT share a pool — a queued
/// file-header must never be handed back to a line — which the controller
/// enforces structurally by keying the pool dictionary on `reuseKind`. The
/// free-list is capped at `minQueued`; anything beyond that is removed from the
/// view hierarchy outright so a fast fling can't leak an unbounded backlog.
@MainActor
final class ViewReuseQueue<View: NSView, Key: Hashable> {
  /// The free-list of recycled, ready-to-reuse views (CETV `queuedViews`).
  private(set) var queued: Deque<View> = []
  /// The in-use views, keyed by the caller's stable key (CETV `usedViews`).
  private(set) var used: [Key: View] = [:]
  /// Free-list cap (CETV `minimumViewCount`). Views past the cap are dropped.
  private let minQueued: Int

  /// Invoked once per view as it is enqueued (recycled off). The controller wires
  /// this to the view's `prepareForReuse()` unmount hook so teardown of the prior
  /// occupant precedes any later reuse.
  var onEnqueue: (@MainActor (View) -> Void)?

  init(minQueued: Int = 4) {
    self.minQueued = minQueued
  }

  /// Count of currently in-use views — the acceptance-criterion bound
  /// (Σ `usedCount` ≈ viewport + overscan, independent of tree size).
  var usedCount: Int { used.count }

  /// Return the in-use view for `key`, dequeuing a free view (or creating one)
  /// on first use (CETV `getOrCreateView`).
  func getOrCreateView(forKey key: Key, createView: () -> View) -> View {
    if let existing = used[key] { return existing }
    let view = queued.popFirst() ?? createView()
    // A view coming off the free-list was hidden by `enqueueView`; anything handed back
    // for use must be visible again. `LineRowView.configure` also clears this, but a
    // recycled widget host has no such hook — without this, a hunk-header / file-header /
    // expander that scrolled off and back stays HIDDEN (blank), the "no hunk headers,
    // only one hunk renders" bug. Hiding is exclusively `enqueueView`'s job.
    view.isHidden = false
    used[key] = view
    return view
  }

  /// The in-use view for `key`, without creating one (CETV `getView`).
  func getView(forKey key: Key) -> View? { used[key] }

  /// Recycle the in-use view for `key`: run its teardown hook, hide it, and put
  /// it back on the capped free-list (or drop it entirely past the cap) — CETV
  /// `enqueueView`.
  func enqueueView(forKey key: Key) {
    guard let view = used.removeValue(forKey: key) else { return }
    onEnqueue?(view)
    view.isHidden = true
    if queued.count < minQueued {
      queued.append(view)
    } else {
      view.removeFromSuperview()
    }
  }

  /// Recycle every in-use view whose key is NOT in `keep` (CETV `enqueueViews`).
  /// The keys are snapshotted before mutation so a one-jump fling that recycles
  /// the entire in-use set never mutates the dictionary mid-iteration.
  func enqueueViews(notInSet keep: Set<Key>) {
    let toEnqueue = used.keys.filter { !keep.contains($0) }
    for key in toEnqueue {
      enqueueView(forKey: key)
    }
  }
}
