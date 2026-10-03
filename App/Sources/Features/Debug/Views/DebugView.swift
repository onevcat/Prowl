import ComposableArchitecture
import SwiftUI

#if DEBUG

  /// Root of the Debug Window. NavigationSplitView with a sidebar so
  /// future debug surfaces (detector state, analytics events,
  /// ghostty internals…) can be added by extending `DebugSection`
  /// and the sidebar list / detail switch below. The store is held
  /// only to mirror the app-wide appearance setting on this window;
  /// individual debug surfaces don't have to thread it.
  struct DebugView: View {
    let store: StoreOf<AppFeature>
    @State private var selection: DebugSection = .iconCatalog

    var body: some View {
      NavigationSplitView(columnVisibility: .constant(.all)) {
        List(selection: $selection) {
          Label("Icon Catalog", systemImage: "square.grid.2x2")
            .tag(DebugSection.iconCatalog)
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200, maxHeight: .infinity)
        .navigationSplitViewColumnWidth(200)
      } detail: {
        Group {
          switch selection {
          case .iconCatalog:
            IconCatalogView()
              .navigationTitle("Icon Catalog")
              .navigationSubtitle("CommandIconMap entries (DEBUG)")
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .navigationSplitViewStyle(.balanced)
      .frame(minWidth: 700, minHeight: 500)
      .background {
        // Standalone NSWindow doesn't pick up `.preferredColorScheme`
        // (only WindowGroup scenes do), so route through the same
        // bridge SettingsView uses to honour the user's appearance.
        WindowAppearanceSetter(colorScheme: store.settings.appearanceMode.colorScheme)
      }
    }
  }

#endif
