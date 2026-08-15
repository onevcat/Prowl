import ComposableArchitecture
import SwiftUI

internal struct StandardAppCommands: Commands {
  @Bindable internal var store: StoreOf<AppFeature>
  internal let terminalManager: WorktreeTerminalManager
  internal let ghosttyShortcuts: GhosttyShortcutManager
  internal let askAgentHelp: AskAgentHelpPresenter

  internal var body: some Commands {
    Group {
      WorktreeCommands(store: store)
      SidebarCommands(store: store)
      TerminalCommands(ghosttyShortcuts: ghosttyShortcuts)
      WindowCommands(
        store: store,
        terminalManager: terminalManager,
        ghosttyShortcuts: ghosttyShortcuts,
        resolvedKeybindings: store.resolvedKeybindings,
        settingsWindowManager: SettingsWindowManager.shared
      )
    }
    CommandGroup(after: .textEditing) {
      Button("Command Palette") {
        store.send(.commandPalette(.togglePresented))
      }
      .modifier(
        KeyboardShortcutModifier(
          shortcut: store.resolvedKeybindings.keyboardShortcut(
            for: AppShortcuts.CommandID.commandPalette
          )
        )
      )
      .help(helpText(title: "Command Palette", commandID: AppShortcuts.CommandID.commandPalette))
    }
    UpdateCommands(
      store: store.scope(state: \.updates, action: \.updates),
      resolvedKeybindings: store.resolvedKeybindings
    )
    CommandGroup(replacing: .appSettings) {
      Button("Settings...") {
        SettingsWindowManager.shared.show()
      }
      .modifier(
        KeyboardShortcutModifier(
          shortcut: store.resolvedKeybindings.keyboardShortcut(for: AppShortcuts.CommandID.openSettings)
        )
      )
    }
    CommandGroup(after: .appSettings) {
      Button("Install Command Line Tool") {
        store.send(.settings(.installCLIButtonTapped(showAlert: false)))
      }
      .help("Install the prowl command line tool to /usr/local/bin")
    }
    #if DEBUG
      CommandMenu("Debug") {
        Button("Icon Catalog") {
          DebugWindowManager.shared.show()
        }
      }
    #endif
    SharedHelpCommands(askAgentHelp: askAgentHelp)
    CommandGroup(replacing: .appTermination) {
      Button("Quit Prowl") {
        store.send(.requestQuit)
      }
      .modifier(
        KeyboardShortcutModifier(
          shortcut: store.resolvedKeybindings.keyboardShortcut(
            for: AppShortcuts.CommandID.quitApplication
          )
        )
      )
      .help(helpText(title: "Quit Prowl", commandID: AppShortcuts.CommandID.quitApplication))
    }
  }

  private func helpText(title: String, commandID: String) -> String {
    if let shortcut = store.resolvedKeybindings.display(for: commandID) {
      return "\(title) (\(shortcut))"
    }
    return title
  }
}

internal struct CleanAppCommands: Commands {
  @Bindable internal var store: StoreOf<CleanAppFeature>
  internal let resolvedKeybindings: ResolvedKeybindingMap
  @Environment(\.openWindow) private var openWindow

  internal var body: some Commands {
    let mainWindowOpenerRegistered = MainWindowOpener.shared.register(openWindow: openWindow)

    CommandGroup(replacing: .newItem) {}
    CommandGroup(replacing: .saveItem) {
      Button("Close Window", systemImage: "xmark") {
        NSApplication.shared.keyWindow?.performClose(nil)
      }
      .keyboardShortcut("w", modifiers: .command)
    }
    CommandGroup(replacing: .windowArrangement) {
      Button("Prowl") {
        guard mainWindowOpenerRegistered else { return }
        _ = NSApplication.shared.surfaceMainWindow()
      }
      .help("Show main window")
      if SettingsWindowManager.shared.isOpen {
        Button("Settings") {
          SettingsWindowManager.shared.show()
        }
        .help("Show Settings window")
      }
    }
    UpdateCommands(
      store: store.scope(state: \.updates, action: \.updates),
      resolvedKeybindings: resolvedKeybindings
    )
    CommandGroup(replacing: .appSettings) {
      Button("Settings...") {
        SettingsWindowManager.shared.show()
      }
      .modifier(
        KeyboardShortcutModifier(
          shortcut: resolvedKeybindings.keyboardShortcut(for: AppShortcuts.CommandID.openSettings)
        )
      )
    }
    CommandGroup(replacing: .help) {
      Button("Homepage", systemImage: "house") {
        if let url = URL(string: "https://prowl.onev.cat/") {
          NSWorkspace.shared.open(url)
        }
      }
      Button("Release Notes", systemImage: "note.text") {
        if let url = URL(string: "https://prowl.onev.cat/releases/") {
          NSWorkspace.shared.open(url)
        }
      }
    }
    CommandGroup(replacing: .appTermination) {
      Button("Quit Prowl") {
        store.send(.requestQuit)
      }
      .modifier(
        KeyboardShortcutModifier(
          shortcut: resolvedKeybindings.keyboardShortcut(for: AppShortcuts.CommandID.quitApplication)
        )
      )
    }
  }
}

private struct SharedHelpCommands: Commands {
  let askAgentHelp: AskAgentHelpPresenter

  var body: some Commands {
    CommandGroup(replacing: .help) {
      Button("Ask Agent About Prowl…", systemImage: "sparkles") {
        askAgentHelp.present()
      }
      .help("Copy a prompt that points your AI agent at Prowl's bundled docs")
      Divider()
      Button("Homepage", systemImage: "house") {
        if let url = URL(string: "https://prowl.onev.cat/") {
          NSWorkspace.shared.open(url)
        }
      }
      Button("Release Notes", systemImage: "note.text") {
        if let url = URL(string: "https://prowl.onev.cat/releases/") {
          NSWorkspace.shared.open(url)
        }
      }
    }
  }
}
