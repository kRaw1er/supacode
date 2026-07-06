import AppKit
import SwiftUI

/// Pinned file-header overlay. pierre stickies the header with CSS
/// `position: sticky` (`packages/diffs/src/style.css:257`); we have no CSS sticky,
/// so we float a header over the CLIP view via
/// `NSScrollView.addFloatingSubview(_:for: .vertical)` — the canonical native
/// "floating header" API (adds the view to `contentView`, keeps it fixed during
/// vertical scroll) — never the flipped document view. On scroll we resolve the
/// owning file (via `ScrollSpyController`, i.e. `y → chunk → file`) and the incoming
/// next-file header physically shoves the pinned one out, reproducing CSS sticky's
/// shove by hand.
///
/// The overlay is a floating subview, so it reserves **no** layout space and never
/// changes the document height or scroll offset (the scrollbar is unaffected).
///
/// > ⚠️ Geometry: the exact sign of the push-out offset and the flipped/non-flipped
/// > clip math must be validated on the Release manual pass at 1×/2×/1.5× (same
/// > class of retina/flip risk Phase 2 flags for anchors). The `overlap → pushUp`
/// > arithmetic is unit-tested in isolation (`StickyHeaderOverlay.pushUp`); the live
/// > pixel placement is a manual check.
@MainActor
final class StickyHeaderOverlay {
  /// pierre `diffHeaderHeight` (brainstorm §Round-3 constants). Matches
  /// `ChunkLayoutMetrics.production.diffHeaderHeight`.
  static let headerHeight: CGFloat = 44

  private let container = NSView()
  private let hosting = NSHostingView(rootView: StickyFileHeaderView(model: nil))
  private unowned let scrollView: NSScrollView
  private unowned let spy: ScrollSpyController
  /// Resolves the rich header model for a file id — the SAME `FileHeaderWidget.Model`
  /// the in-flow header uses, so the pinned copy is a 1:1 mirror. Injected (the tree
  /// stores scalars only, not the rich model).
  private let resolveModel: (FileChange.ID) -> FileHeaderWidget.Model?
  private var pinnedFileID: FileChange.ID?

  init(
    scrollView: NSScrollView,
    spy: ScrollSpyController,
    resolveModel: @escaping (FileChange.ID) -> FileHeaderWidget.Model?
  ) {
    self.scrollView = scrollView
    self.spy = spy
    self.resolveModel = resolveModel
    hosting.sizingOptions = []  // harness owns the frame (Phase 6 widget rule)
    container.addSubview(hosting)
    // Phase 12: the pinned overlay duplicates a file-header widget that already lives
    // in the tree (and is an AX element via the synthesized set), so hide the whole
    // overlay subtree from VoiceOver — otherwise the file is announced twice while
    // scrolling. `setAccessibilityHidden(true)` hides the container AND its hosted
    // SwiftUI header (`NSAccessibility.h:462`).
    container.setAccessibilityElement(false)
    container.setAccessibilityHidden(true)
    container.isHidden = true
    scrollView.addFloatingSubview(container, for: .vertical)  // subview of contentView (clip view)
  }

  /// `clipTop` = document-space y of the clip's top edge (flipped doc). Called from
  /// the viewport's `onVisibleRangeChanged` / scroll handler.
  func update(clipTop: CGFloat, viewportWidth: CGFloat) {
    guard let fileID = spy.fileID(atTop: clipTop) else {
      container.isHidden = true
      pinnedFileID = nil
      return
    }
    container.isHidden = false
    if fileID != pinnedFileID {
      pinnedFileID = fileID
      hosting.rootView = StickyFileHeaderView(model: resolveModel(fileID))
    }
    let up = Self.pushUp(nextFileTop: spy.nextFileTop(after: fileID), clipTop: clipTop)
    // Floating subviews live in the clip's space: pin to the clip top, shove up by
    // `pushUp` as the next file's header enters the header band.
    let clipHeight = scrollView.contentView.bounds.height
    container.frame = CGRect(
      x: 0,
      y: Self.frameY(clipHeight: clipHeight, pushUp: up),
      width: viewportWidth,
      height: Self.headerHeight
    )
    hosting.frame = container.bounds
  }

  /// The current pinned state — the hidden flag, the resolved file, and the
  /// container's clip-space top y. Read by tests (the geometry is otherwise private).
  struct PinnedState: Equatable {
    var isHidden: Bool
    var fileID: FileChange.ID?
    var frameY: CGFloat
  }

  var pinnedState: PinnedState {
    PinnedState(isHidden: container.isHidden, fileID: pinnedFileID, frameY: container.frame.origin.y)
  }

  // MARK: - Pure push-out arithmetic (unit-tested in isolation)

  /// How far (≥ 0) the pinned header is shoved up as the next file's header enters
  /// the header band. `overlap = nextFileTop − clipTop`:
  /// - next header far below (`overlap ≥ headerHeight`, or no next file) → `0`
  ///   (header sits flush, HEADER_ONLY at the clip top);
  /// - next header entering (`0 < overlap < headerHeight`) → `headerHeight − overlap`,
  ///   so the pinned header's bottom edge meets the incoming header's top exactly
  ///   (contiguity — the region ends at the logical bottom);
  /// - next header at/above the clip top (`overlap ≤ 0`) → `headerHeight` (fully out).
  static func pushUp(nextFileTop: CGFloat?, clipTop: CGFloat, headerHeight: CGFloat = headerHeight) -> CGFloat {
    let overlap = nextFileTop.map { $0 - clipTop } ?? .greatestFiniteMagnitude
    return -min(0, overlap - headerHeight)
  }

  /// The pinned header's document-space bottom edge for a given `clipTop` / `pushUp`.
  /// When the next header is entering, this equals `nextFileTop` (push-out contiguity).
  static func pinnedBottom(clipTop: CGFloat, pushUp: CGFloat, headerHeight: CGFloat = headerHeight) -> CGFloat {
    clipTop + headerHeight - pushUp
  }

  /// The overlay container's clip-space top y (harness placement). The floating
  /// subview pins to the clip top and slides up by `pushUp`.
  static func frameY(clipHeight: CGFloat, pushUp: CGFloat, headerHeight: CGFloat = headerHeight) -> CGFloat {
    clipHeight - headerHeight + pushUp
  }
}
