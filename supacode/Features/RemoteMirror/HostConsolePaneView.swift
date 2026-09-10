import SwiftUI

struct HostConsoleSidebarRow: View {
  @Environment(RemoteMirrorStore.self) private var mirrors

  var body: some View {
    if mirrors.controlConsole.isAlive {
      Button {
        mirrors.controlConsole.show()
      } label: {
        HStack {
          Image(systemName: "terminal").accessibilityHidden(true)
          Text("Host Console")
          Spacer()
        }
        .padding(8)
        .background(
          mirrors.controlConsole.isSelected ? Color.accentColor.opacity(0.2) : .clear,
          in: RoundedRectangle(cornerRadius: 8))
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 10)
      .help("Open the Host control terminal")
      .accessibilityIdentifier("host-console-sidebar-row")
    }
  }
}

struct HostConsolePaneView: View {
  let console: HostControlConsole
  let manager: WorktreeTerminalManager

  var body: some View {
    WorktreeTerminalTabsView(
      worktree: console.worktree, manager: manager, shouldRunSetupScript: false,
      forceAutoFocus: true,
      createTab: {
        _ = manager.createTabInDirectory(
          console.worktree, directory: HostControlConsole.defaultDirectory)
      }
    )
    .navigationTitle("Host Console")
  }
}
