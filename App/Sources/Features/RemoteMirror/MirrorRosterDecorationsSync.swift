import ComposableArchitecture
import SwiftUI

/// Pushes the sidebar's project names, colors and order to the Mirror Host (docs-ai 089). A
/// separate view, so that repository changes re-render only this, not the window content.
struct MirrorRosterDecorationsSync: View {
  let store: StoreOf<RepositoriesFeature>
  @Environment(RemoteMirrorStore.self) private var mirrors
  @Shared(.repositoryAppearances) private var appearances

  var body: some View {
    let decorations = MirrorRosterDecorations(
      layout: store.state.materializedSidebarLayout(),
      appearances: appearances,
      customTitles: store.repositoryCustomTitles)
    Color.clear
      .accessibilityHidden(true)
      .onChange(of: decorations, initial: true) { _, decorations in
        mirrors.updateRosterDecorations(decorations)
      }
  }
}
