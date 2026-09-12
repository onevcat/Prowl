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
            processInfoByPaneTarget: store.herdrTerminalChrome.authorityMode == .aggregate
              ? store.herdrTerminalChrome.aggregateProcessInfoByPaneTarget
              : store.herdrTerminalChrome.acceptsLegacyAuthority
                ? terminalHost.processInfoByPaneTarget
                : [:]
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
        authorityMode: store.herdrTerminalChrome.authorityMode,
        endpointKey: store.herdrTerminalChrome.committedActiveEndpointKey,
        focusedPaneID: herdrProcessFocusedPaneID
      )
    }
    .task(id: herdrAuthorityContextKey) {
      terminalHost.updateHerdrAuthority(
        mode: store.herdrTerminalChrome.authorityMode,
        endpointKey: store.herdrTerminalChrome.committedActiveEndpointKey,
        focusedPane: focusedNativePane
      )
    }
    .alert($store.scope(state: \.alert, action: \.alert))
  }

  private var herdrProcessPaneKey: String {
    let snapshot = store.herdrTerminalChrome.snapshot
    let authority = store.herdrTerminalChrome.authorityMode
    let endpoint = store.herdrTerminalChrome.committedActiveEndpointKey?.storageKey ?? "none"
    return "\(authority)|\(endpoint)|"
      + snapshot.panes
      .map { "\($0.id):\($0.tabID):\($0.focused)" }
      .joined(separator: "|") + "|focused:\(herdrProcessFocusedPaneID ?? "")"
  }

  private var herdrProcessFocusedPaneID: String? {
    HerdrProcessPaneTracking.resolvedFocusedPaneID(
      selectedPaneID: store.herdrTerminalChrome.selectedPaneID,
      snapshotFocusedPaneID: store.herdrTerminalChrome.snapshot.focusedPaneID
    )
  }

  private var focusedNativePane: HerdrClientShellPane? {
    guard let endpoint = store.herdrTerminalChrome.aggregateState?.committedEndpoint else {
      return nil
    }
    let paneID =
      store.herdrTerminalChrome.aggregateState?.committedActiveSelection?.paneID
      ?? endpoint.snapshot?.focusedPaneID
    return endpoint.snapshot?.panes.first { $0.paneID == paneID }
  }

  private var herdrAuthorityContextKey: String {
    let state = store.herdrTerminalChrome
    let endpoint = state.committedActiveEndpointKey?.storageKey ?? "none"
    let pane = focusedNativePane
    return
      "\(state.authorityMode)-\(endpoint)-\(pane?.paneID ?? "none")-\(pane?.inputContext.kind ?? "none")"
  }
}
