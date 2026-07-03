import ComposableArchitecture
import Foundation

/// The inline note editor for a single review comment (new or edit). A leaf
/// reducer so the composer view binds through `.composer(...)` actions instead
/// of mutating `store.*` directly (`store_state_mutation_in_views`). Its
/// delegate is drained by `DiffReviewFeature`.
@Reducer
struct CommentComposer {
  @ObservableState
  struct State: Equatable {
    /// The comment under composition. `id` is stable so an edit upserts in place.
    var draft: ReviewComment
    /// True when editing an existing comment (surfaces the Delete affordance).
    var isEditing: Bool

    /// Whether the current body has any non-whitespace content (Save gate).
    var canSave: Bool {
      !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  enum Action: BindableAction, Equatable {
    case binding(BindingAction<State>)
    case saveTapped
    case cancelTapped
    case deleteTapped
    case delegate(Delegate)
  }

  @CasePathable
  enum Delegate: Equatable {
    case commit(ReviewComment)
    case cancel
    case delete(UUID)
  }

  var body: some Reducer<State, Action> {
    BindingReducer()
    Reduce { state, action in
      switch action {
      case .binding:
        return .none
      case .saveTapped:
        guard state.canSave else { return .none }
        return .send(.delegate(.commit(state.draft)))
      case .cancelTapped:
        return .send(.delegate(.cancel))
      case .deleteTapped:
        return .send(.delegate(.delete(state.draft.id)))
      case .delegate:
        return .none
      }
    }
  }
}
