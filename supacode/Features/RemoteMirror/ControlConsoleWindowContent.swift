import SwiftUI

struct ControlConsoleWindowContent: View {
  let console: HostControlConsole
  let manager: WorktreeTerminalManager
  let shortcuts: GhosttyShortcutManager
  let commandKeyObserver: CommandKeyObserver
  var keybindings: ResolvedKeybindingMap = .appDefaults

  var body: some View {
    WorktreeTerminalTabsView(
      worktree: console.worktree, manager: manager, shouldRunSetupScript: false,
      forceAutoFocus: true,
      createTab: {
        _ = manager.createTabInDirectory(
          console.worktree, directory: HostControlConsole.defaultDirectory)
      }
    )
    .environment(shortcuts)
    .environment(commandKeyObserver)
    .environment(\.resolvedKeybindings, keybindings)
  }
}
