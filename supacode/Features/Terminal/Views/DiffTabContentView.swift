import SwiftUI

/// Placeholder content for a surface-less diff tab. Phase 3 replaces this with
/// the real diff viewer (`DiffViewerRepresentable`); Phase 0 only needs the tab
/// to render, switch, and close alongside terminal tabs.
struct DiffTabContentView: View {
  let filePath: String?

  var body: some View {
    ContentUnavailableView(
      "Diff",
      systemImage: "plus.forwardslash.minus",
      description: Text(filePath ?? "")
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
