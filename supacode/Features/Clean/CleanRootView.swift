import ComposableArchitecture
import SwiftUI

internal struct CleanRootView: View {
  @Bindable internal var store: StoreOf<CleanAppFeature>
  internal let terminalHost: CleanTerminalHost

  internal var body: some View {
    HStack(spacing: 0) {
      if store.herdrTerminalChrome.isVisible {
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
            )
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
    .alert($store.scope(state: \.alert, action: \.alert))
  }
}
