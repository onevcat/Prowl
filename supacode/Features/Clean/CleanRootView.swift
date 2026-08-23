import ComposableArchitecture
import SwiftUI

internal struct CleanRootView: View {
  @Bindable internal var store: StoreOf<CleanAppFeature>
  @Bindable internal var terminalHost: CleanTerminalHost

  internal var body: some View {
    HStack(spacing: 0) {
      if store.herdrTerminalChrome.isVisible && store.isSidebarVisible {
        HerdrSidebarView(
          store: store.scope(
            state: \.herdrTerminalChrome,
            action: \.herdrTerminalChrome
          )
        )
        .frame(width: HerdrSidebarLayout.width)
      }

      VStack(spacing: 0) {
        if store.herdrTerminalChrome.isVisible {
          HerdrTabBarView(
            store: store.scope(
              state: \.herdrTerminalChrome,
              action: \.herdrTerminalChrome
            ),
            processInfoByPaneID: terminalHost.processInfoByPaneID
          )
        }

        if let surface = terminalHost.surface {
          GhosttyTerminalView(surfaceView: surface)
        } else {
          Color.clear
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .ignoresSafeArea(.container, edges: .top)
    .toolbarVisibility(.hidden, for: .windowToolbar)
    .background {
      CleanWindowConfigurator()
      WindowFocusObserverView { activity in
        terminalHost.updateWindowActivity(activity)
      }
      .frame(width: 0, height: 0)
    }
    .onAppear {
      terminalHost.start()
    }
    .onDisappear {
      terminalHost.suspend()
    }
    .task(id: herdrProcessPaneKey) {
      terminalHost.updateHerdrProcessPanes(
        store.herdrTerminalChrome.snapshot.panes,
        focusedPaneID: herdrProcessFocusedPaneID
      )
    }
    .alert($store.scope(state: \.alert, action: \.alert))
  }

  private var herdrProcessPaneKey: String {
    let snapshot = store.herdrTerminalChrome.snapshot
    return snapshot.panes
      .map { "\($0.id):\($0.tabID):\($0.focused)" }
      .joined(separator: "|") + "|focused:\(herdrProcessFocusedPaneID ?? "")"
  }

  private var herdrProcessFocusedPaneID: String? {
    HerdrProcessPaneTracking.resolvedFocusedPaneID(
      selectedPaneID: store.herdrTerminalChrome.selectedPaneID,
      snapshotFocusedPaneID: store.herdrTerminalChrome.snapshot.focusedPaneID
    )
  }
}
