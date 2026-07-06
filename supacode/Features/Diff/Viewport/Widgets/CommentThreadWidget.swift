import AppKit
import ComposableArchitecture
import SwiftUI

/// The rich, resolved-by-`WidgetKey` model for a comment-thread widget (D3 — the
/// tree chunk carries ONLY `.commentThread(anchorID:)`; this lives in a side cache
/// resolved from the reducer's `comments`). `mode` (display / editing) is derived
/// from whether the reducer has an open composer for `anchorID`, not stored here.
struct CommentThreadModel: Equatable {
  var anchorID: UUID
  var comments: [ReviewComment]
  var isCollapsed: Bool

  init(anchorID: UUID, comments: [ReviewComment], isCollapsed: Bool = false) {
    self.anchorID = anchorID
    self.comments = comments
    self.isCollapsed = isCollapsed
  }

  /// The head comment (thread anchor). `anchorID == head.id`.
  var head: ReviewComment? { comments.first }
}

/// A comment thread as a full-height, collapsable, `NSHostingView`-backed widget.
/// NO inner `ScrollView` UNLESS the expanded content exceeds
/// `min(0.6·viewportHeight, 600pt)` (brainstorm §409) — then it scrolls inside a
/// capped frame. `.editing` mode embeds the ported composer (Esc → cancel,
/// ⌘↩ → save) and REFUSES a recycled-host swap (`update` → `false`) because an
/// `NSHostingView` `rootView` swap over the live `TextEditor` loses the cursor.
@MainActor
final class CommentThreadWidget: DiffWidget {
  let key: WidgetKey
  var model: CommentThreadModel
  /// Drives the `min(0.6·viewportHeight, 600pt)` inner-scroll cap.
  var viewportHeight: CGFloat
  private unowned let coalescer: LayoutCoalescer
  /// Present only while this thread is being composed / edited (`.editing`).
  private let composerStore: StoreOf<CommentComposer>?
  private let onToggleCollapse: () -> Void
  private let onEdit: (UUID) -> Void

  /// `.editing` when the reducer has an open composer for this anchor.
  var isEditing: Bool { composerStore != nil }

  /// A live editor is an app-owned subview, so a host mounting one stays bound to
  /// this chunk until drained (B §3) — the harness never hands it to another chunk.
  var occupiesHostExclusively: Bool { isEditing }

  var estimatedHeight: CGFloat { ChunkLayoutMetrics.production.commentThreadHeight }

  /// The expanded-content height cap; beyond it the thread scrolls internally.
  var heightCap: CGFloat { min(0.6 * viewportHeight, 600) }

  init(
    key: WidgetKey,
    model: CommentThreadModel,
    viewportHeight: CGFloat = 600,
    coalescer: LayoutCoalescer,
    composerStore: StoreOf<CommentComposer>? = nil,
    onToggleCollapse: @escaping () -> Void = {},
    onEdit: @escaping (UUID) -> Void = { _ in }
  ) {
    self.key = key
    self.model = model
    self.viewportHeight = viewportHeight
    self.coalescer = coalescer
    self.composerStore = composerStore
    self.onToggleCollapse = onToggleCollapse
    self.onEdit = onEdit
  }

  func makeHostView(reporter: HeightReporter) -> NSView {
    let host = NSHostingView(rootView: AnyView(content(reporter: reporter)))
    host.sizingOptions = []
    return host
  }

  func update(hostView: NSView, width: CGFloat) -> Bool {
    // A live TextEditor loses its cursor on an NSHostingView rootView swap, so the
    // editing thread refuses recycle — the harness rebuilds a fresh host (D-note).
    guard !isEditing else { return false }
    guard let hosting = hostView as? NSHostingView<AnyView> else { return false }
    hosting.rootView = AnyView(content(reporter: HeightReporter(key: key, coalescer: coalescer)))
    return true
  }

  @ViewBuilder
  private func content(reporter: HeightReporter) -> some View {
    Group {
      if let composerStore {
        CommentThreadEditorView(store: composerStore)
      } else {
        CommentThreadDisplayView(
          comments: model.comments,
          isCollapsed: model.isCollapsed,
          heightCap: heightCap,
          onToggleCollapse: onToggleCollapse,
          onEdit: onEdit
        )
      }
    }
    .onGeometryChange(for: CGSize.self) {
      $0.size
    } action: { size in
      reporter.report(width: size.width, height: size.height)
    }
  }
}

/// The `.editing` body: the ported composer with an explicit Esc → cancel handback
/// (`onExitCommand`) on top of the composer's own ⌘↩ / ⎋ shortcuts.
private struct CommentThreadEditorView: View {
  @Bindable var store: StoreOf<CommentComposer>

  var body: some View {
    CommentComposerView(store: store)
      .onExitCommand { store.send(.cancelTapped) }
  }
}

/// The `.display` body: a collapsed summary row or the expanded thread. Full-
/// height; the expanded thread scrolls internally only when it exceeds `heightCap`.
private struct CommentThreadDisplayView: View {
  let comments: [ReviewComment]
  let isCollapsed: Bool
  let heightCap: CGFloat
  let onToggleCollapse: () -> Void
  let onEdit: (UUID) -> Void
  @State private var contentHeight: CGFloat = 0

  var body: some View {
    if isCollapsed {
      collapsedRow
    } else {
      expanded
    }
  }

  private var chevron: some View {
    Button(action: onToggleCollapse) {
      Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
    }
    .buttonStyle(.borderless)
    .help(isCollapsed ? "Expand comments" : "Collapse comments")
    .accessibilityLabel(isCollapsed ? "Expand comments" : "Collapse comments")
  }

  private var collapsedRow: some View {
    HStack(spacing: 8) {
      chevron
      Image(systemName: "text.bubble")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("\(comments.count) comment\(comments.count == 1 ? "" : "s")")
        .font(.callout.weight(.medium))
      Text(preview)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .frame(minHeight: 32)
  }

  private var expanded: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        chevron
        Text("\(comments.count) comment\(comments.count == 1 ? "" : "s")")
          .font(.callout.weight(.medium))
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.top, 8)

      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(comments) { comment in
            CommentRowView(comment: comment) { onEdit(comment.id) }
          }
        }
        .padding(12)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          contentHeight = $0
        }
      }
      .frame(height: min(max(contentHeight, 1), heightCap))
    }
  }

  private var preview: String {
    let body = comments.first?.body ?? ""
    return body.replacing("\n", with: " ")
  }
}

/// One comment inside an expanded thread — tap to edit; an orphaned comment shows
/// the same warning affordance as the composer.
private struct CommentRowView: View {
  let comment: ReviewComment
  let onEdit: () -> Void

  var body: some View {
    Button(action: onEdit) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(rangeLabel)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
          if comment.orphaned {
            Label("Orphaned", systemImage: "exclamationmark.triangle")
              .font(.caption2)
              .foregroundStyle(.orange)
              .labelStyle(.titleAndIcon)
          }
          Spacer(minLength: 0)
        }
        Text(comment.body)
          .font(.body)
          .foregroundStyle(.primary)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .buttonStyle(.plain)
    .help("Edit this comment")
  }

  private var rangeLabel: String {
    let side = comment.side == .old ? "-L" : "L"
    return comment.startLine == comment.endLine
      ? "\(side)\(comment.startLine)"
      : "\(side)\(comment.startLine)–\(comment.endLine)"
  }
}
