import ProwlCLIShared
import SwiftUI

struct AppShortcut: Equatable {
  let keyEquivalent: KeyEquivalent
  let modifiers: EventModifiers
  private let ghosttyKeyName: String

  init(key: Character, modifiers: EventModifiers) {
    self.keyEquivalent = KeyEquivalent(key)
    self.modifiers = modifiers
    self.ghosttyKeyName = String(key).lowercased()
  }

  init(keyEquivalent: KeyEquivalent, ghosttyKeyName: String, modifiers: EventModifiers) {
    self.keyEquivalent = keyEquivalent
    self.modifiers = modifiers
    self.ghosttyKeyName = ghosttyKeyName
  }

  var keyboardShortcut: KeyboardShortcut {
    KeyboardShortcut(keyEquivalent, modifiers: modifiers)
  }

  var keyToken: String {
    ghosttyKeyName
  }

  var ghosttyKeybind: String {
    let parts = ghosttyModifierParts + [ghosttyKeyName]
    return parts.joined(separator: "+")
  }

  var ghosttyUnbindArgument: String {
    "--keybind=\(ghosttyKeybind)=unbind"
  }

  func ghosttyBindArguments(action: String) -> [String] {
    var arguments = ["--keybind=\(ghosttyKeybind)=\(action)"]
    if let physicalKeyAlias {
      let parts = ghosttyModifierParts + [physicalKeyAlias]
      arguments.append("--keybind=\(parts.joined(separator: "+"))=\(action)")
    }
    return arguments
  }

  var display: String {
    let parts = displayModifierParts + [keyEquivalent.display]
    return parts.joined()
  }

  var displaySymbols: [String] {
    display.map { String($0) }
  }

  fileprivate var normalizedConflictKey: String? {
    guard ghosttyKeyName.count == 1 else { return nil }
    return ghosttyKeyName
  }

  private var ghosttyModifierParts: [String] {
    var parts: [String] = []
    if modifiers.contains(.control) { parts.append("ctrl") }
    if modifiers.contains(.option) { parts.append("alt") }
    if modifiers.contains(.shift) { parts.append("shift") }
    if modifiers.contains(.command) { parts.append("super") }
    return parts
  }

  private var displayModifierParts: [String] {
    var parts: [String] = []
    if modifiers.contains(.command) { parts.append("⌘") }
    if modifiers.contains(.shift) { parts.append("⇧") }
    if modifiers.contains(.option) { parts.append("⌥") }
    if modifiers.contains(.control) { parts.append("⌃") }
    return parts
  }

  private var physicalKeyAlias: String? {
    let value = String(keyEquivalent.character).lowercased()
    guard value.count == 1, let character = value.first, character.isNumber else { return nil }
    return "digit_\(value)"
  }
}

enum AppShortcuts {
  enum CommandID {
    static let newWorktree = "new_worktree"
    static let commandPalette = "command_palette"
    static let quitApplication = "quit_application"
    static let openSettings = "open_settings"
    static let openWorktree = "open_worktree"
    static let openRepository = "open_repository"
    static let openPullRequest = "open_pull_request"
    static let toggleLeftSidebar = "toggle_left_sidebar"
    static let toggleActiveAgentsPanel = "toggle_active_agents_panel"
    static let toggleAgentIsland = "toggle_agent_island"
    static let selectNextActiveAgent = "select_next_active_agent"
    static let selectPreviousActiveAgent = "select_previous_active_agent"
    static let refreshWorktrees = "refresh_worktrees"
    static let jumpToLatestUnread = "jump_to_latest_unread"
    static let runScript = "run_script"
    static let stopScript = "stop_script"
    static let checkForUpdates = "check_for_updates"
    static let showDiff = "show_diff"
    static let outgoingChanges = "outgoing_changes"
    static let toggleCanvas = "toggle_canvas"
    static let toggleShelf = "toggle_shelf"
    static let selectNextShelfBook = "select_next_shelf_book"
    static let selectPreviousShelfBook = "select_previous_shelf_book"
    static let selectShelfBook1 = "select_shelf_book_1"
    static let selectShelfBook2 = "select_shelf_book_2"
    static let selectShelfBook3 = "select_shelf_book_3"
    static let selectShelfBook4 = "select_shelf_book_4"
    static let selectShelfBook5 = "select_shelf_book_5"
    static let selectShelfBook6 = "select_shelf_book_6"
    static let selectShelfBook7 = "select_shelf_book_7"
    static let selectShelfBook8 = "select_shelf_book_8"
    static let selectShelfBook9 = "select_shelf_book_9"
    static let revealInSidebar = "reveal_in_sidebar"
    static let archivedWorktrees = "archived_worktrees"
    static let selectNextWorktree = "select_next_worktree"
    static let selectPreviousWorktree = "select_previous_worktree"
    static let worktreeHistoryBack = "worktree_history_back"
    static let worktreeHistoryForward = "worktree_history_forward"
    static let selectWorktree1 = "select_worktree_1"
    static let selectWorktree2 = "select_worktree_2"
    static let selectWorktree3 = "select_worktree_3"
    static let selectWorktree4 = "select_worktree_4"
    static let selectWorktree5 = "select_worktree_5"
    static let selectWorktree6 = "select_worktree_6"
    static let selectWorktree7 = "select_worktree_7"
    static let selectWorktree8 = "select_worktree_8"
    static let selectWorktree9 = "select_worktree_9"
    static let selectTerminalTab1 = "select_terminal_tab_1"
    static let selectTerminalTab2 = "select_terminal_tab_2"
    static let selectTerminalTab3 = "select_terminal_tab_3"
    static let selectTerminalTab4 = "select_terminal_tab_4"
    static let selectTerminalTab5 = "select_terminal_tab_5"
    static let selectTerminalTab6 = "select_terminal_tab_6"
    static let selectTerminalTab7 = "select_terminal_tab_7"
    static let selectTerminalTab8 = "select_terminal_tab_8"
    static let selectTerminalTab9 = "select_terminal_tab_9"
    static let renameBranch = "rename_branch"
    static let selectAllCanvasCards = "select_all_canvas_cards"
    static let arrangeCanvasCards = "arrange_canvas_cards"
    static let organizeCanvasCards = "organize_canvas_cards"
    static let tileCanvasCards = "tile_canvas_cards"
    static let expandCanvasCard = "expand_canvas_card"
    static let selectPreviousTerminalTab = "select_previous_terminal_tab"
    static let selectNextTerminalTab = "select_next_terminal_tab"
    static let selectPreviousTerminalPane = "select_previous_terminal_pane"
    static let selectNextTerminalPane = "select_next_terminal_pane"
    static let selectTerminalPaneUp = "select_terminal_pane_up"
    static let selectTerminalPaneDown = "select_terminal_pane_down"
    static let selectTerminalPaneLeft = "select_terminal_pane_left"
    static let selectTerminalPaneRight = "select_terminal_pane_right"
    static let toggleSplitZoom = "toggle_split_zoom"
    static let startSearch = "start_search"
    static let findNext = "find_next"
    static let findPrevious = "find_previous"
  }

  enum Scope: String {
    case configurableAppAction
    case systemFixedAppAction
    case localInteraction
  }

  struct Binding: Equatable {
    let id: String
    let title: String
    let scope: Scope
    let shortcut: AppShortcut?
  }

  struct CustomCommandOverrideConflict: Equatable {
    let commandTitle: String
    let commandShortcutDisplay: String
    let appActionTitle: String
    let appShortcutDisplay: String
  }

  private struct ReservedCustomCommandBinding {
    let actionTitle: String
    let shortcut: AppShortcut
  }

  static let newWorktree = AppShortcut(key: "n", modifiers: .command)
  static let commandPalette = AppShortcut(key: "p", modifiers: .command)
  static let quitApplication = AppShortcut(key: "q", modifiers: .command)
  static let openSettings = AppShortcut(key: ",", modifiers: .command)
  static let openFinder = AppShortcut(key: "o", modifiers: .command)
  static let openRepository = AppShortcut(key: "o", modifiers: [.command, .shift])
  static let openPullRequest = AppShortcut(key: "g", modifiers: [.command, .control])
  static let toggleLeftSidebar = AppShortcut(key: "s", modifiers: [.command, .control])
  static let toggleActiveAgentsPanel = AppShortcut(key: "p", modifiers: [.command, .option])
  static let selectNextActiveAgent = AppShortcut(
    keyEquivalent: .downArrow, ghosttyKeyName: "arrow_down", modifiers: [.control, .option]
  )
  static let selectPreviousActiveAgent = AppShortcut(
    keyEquivalent: .upArrow, ghosttyKeyName: "arrow_up", modifiers: [.control, .option]
  )
  static let refreshWorktrees = AppShortcut(key: "r", modifiers: [.command, .shift])
  static let jumpToLatestUnread = AppShortcut(key: "u", modifiers: [.command, .option])
  static let runScript = AppShortcut(key: "r", modifiers: .command)
  static let stopRunScript = AppShortcut(key: ".", modifiers: .command)
  static let checkForUpdates = AppShortcut(key: "u", modifiers: [.command, .shift])
  static let showDiff = AppShortcut(key: "y", modifiers: [.command, .shift])
  static let outgoingChanges = AppShortcut(key: "y", modifiers: [.command, .option, .shift])
  static let startSearch = AppShortcut(key: "f", modifiers: .command)
  static let findNext = AppShortcut(key: "g", modifiers: .command)
  static let findPrevious = AppShortcut(key: "g", modifiers: [.command, .shift])
  static let toggleCanvas = AppShortcut(
    keyEquivalent: .return, ghosttyKeyName: "return", modifiers: [.command, .option]
  )
  static let toggleShelf = AppShortcut(
    keyEquivalent: .return, ghosttyKeyName: "return", modifiers: [.command, .shift]
  )
  static let selectNextShelfBook = AppShortcut(
    keyEquivalent: .rightArrow, ghosttyKeyName: "arrow_right", modifiers: [.command, .control]
  )
  static let selectPreviousShelfBook = AppShortcut(
    keyEquivalent: .leftArrow, ghosttyKeyName: "arrow_left", modifiers: [.command, .control]
  )
  static let selectShelfBook1 = AppShortcut(key: "1", modifiers: [.control, .option])
  static let selectShelfBook2 = AppShortcut(key: "2", modifiers: [.control, .option])
  static let selectShelfBook3 = AppShortcut(key: "3", modifiers: [.control, .option])
  static let selectShelfBook4 = AppShortcut(key: "4", modifiers: [.control, .option])
  static let selectShelfBook5 = AppShortcut(key: "5", modifiers: [.control, .option])
  static let selectShelfBook6 = AppShortcut(key: "6", modifiers: [.control, .option])
  static let selectShelfBook7 = AppShortcut(key: "7", modifiers: [.control, .option])
  static let selectShelfBook8 = AppShortcut(key: "8", modifiers: [.control, .option])
  static let selectShelfBook9 = AppShortcut(key: "9", modifiers: [.control, .option])
  static let shelfBookSelection: [AppShortcut] = [
    selectShelfBook1,
    selectShelfBook2,
    selectShelfBook3,
    selectShelfBook4,
    selectShelfBook5,
    selectShelfBook6,
    selectShelfBook7,
    selectShelfBook8,
    selectShelfBook9,
  ]

  static let shelfBookSelectionCommandIDs: [String] = [
    CommandID.selectShelfBook1,
    CommandID.selectShelfBook2,
    CommandID.selectShelfBook3,
    CommandID.selectShelfBook4,
    CommandID.selectShelfBook5,
    CommandID.selectShelfBook6,
    CommandID.selectShelfBook7,
    CommandID.selectShelfBook8,
    CommandID.selectShelfBook9,
  ]
  static let revealInSidebar = AppShortcut(key: "l", modifiers: [.command, .shift])
  static let archivedWorktrees = AppShortcut(key: "a", modifiers: [.command, .control])
  static let selectNextWorktree = AppShortcut(
    keyEquivalent: .downArrow, ghosttyKeyName: "arrow_down", modifiers: [.command, .control]
  )
  static let selectPreviousWorktree = AppShortcut(
    keyEquivalent: .upArrow, ghosttyKeyName: "arrow_up", modifiers: [.command, .control]
  )
  static let worktreeHistoryBack = AppShortcut(key: "[", modifiers: [.command, .option])
  static let worktreeHistoryForward = AppShortcut(key: "]", modifiers: [.command, .option])
  static let selectWorktree1 = AppShortcut(key: "1", modifiers: [.control])
  static let selectWorktree2 = AppShortcut(key: "2", modifiers: [.control])
  static let selectWorktree3 = AppShortcut(key: "3", modifiers: [.control])
  static let selectWorktree4 = AppShortcut(key: "4", modifiers: [.control])
  static let selectWorktree5 = AppShortcut(key: "5", modifiers: [.control])
  static let selectWorktree6 = AppShortcut(key: "6", modifiers: [.control])
  static let selectWorktree7 = AppShortcut(key: "7", modifiers: [.control])
  static let selectWorktree8 = AppShortcut(key: "8", modifiers: [.control])
  static let selectWorktree9 = AppShortcut(key: "9", modifiers: [.control])
  static let selectTerminalTab1 = AppShortcut(key: "1", modifiers: [.command])
  static let selectTerminalTab2 = AppShortcut(key: "2", modifiers: [.command])
  static let selectTerminalTab3 = AppShortcut(key: "3", modifiers: [.command])
  static let selectTerminalTab4 = AppShortcut(key: "4", modifiers: [.command])
  static let selectTerminalTab5 = AppShortcut(key: "5", modifiers: [.command])
  static let selectTerminalTab6 = AppShortcut(key: "6", modifiers: [.command])
  static let selectTerminalTab7 = AppShortcut(key: "7", modifiers: [.command])
  static let selectTerminalTab8 = AppShortcut(key: "8", modifiers: [.command])
  static let selectTerminalTab9 = AppShortcut(key: "9", modifiers: [.command])
  static let selectPreviousTerminalTab = AppShortcut(key: "[", modifiers: [.command, .shift])
  static let selectNextTerminalTab = AppShortcut(key: "]", modifiers: [.command, .shift])
  static let selectPreviousTerminalPane = AppShortcut(key: "[", modifiers: [.command])
  static let selectNextTerminalPane = AppShortcut(key: "]", modifiers: [.command])
  static let selectTerminalPaneUp = AppShortcut(
    keyEquivalent: .upArrow, ghosttyKeyName: "arrow_up", modifiers: [.command, .option]
  )
  static let selectTerminalPaneDown = AppShortcut(
    keyEquivalent: .downArrow, ghosttyKeyName: "arrow_down", modifiers: [.command, .option]
  )
  static let selectTerminalPaneLeft = AppShortcut(
    keyEquivalent: .leftArrow, ghosttyKeyName: "arrow_left", modifiers: [.command, .option]
  )
  static let selectTerminalPaneRight = AppShortcut(
    keyEquivalent: .rightArrow, ghosttyKeyName: "arrow_right", modifiers: [.command, .option]
  )
  // ⌘⌃F is the system fullscreen toggle and ⌘⇧F is reserved for a future
  // focus mode, so split zoom takes the heavier chord on purpose.
  static let toggleSplitZoom = AppShortcut(key: "f", modifiers: [.command, .option, .shift])
  static let renameBranch = AppShortcut(key: "m", modifiers: [.command, .shift])
  static let selectAllCanvasCards = AppShortcut(key: "a", modifiers: [.command, .option])
  static let arrangeCanvasCards = AppShortcut(key: "r", modifiers: [.command, .option])
  static let organizeCanvasCards = AppShortcut(key: "g", modifiers: [.command, .option])
  static let tileCanvasCards = AppShortcut(key: "t", modifiers: [.command, .option])
  static let expandCanvasCard = AppShortcut(key: "e", modifiers: [.command, .option])
  static let worktreeSelection: [AppShortcut] = [
    selectWorktree1,
    selectWorktree2,
    selectWorktree3,
    selectWorktree4,
    selectWorktree5,
    selectWorktree6,
    selectWorktree7,
    selectWorktree8,
    selectWorktree9,
  ]

  static let worktreeSelectionCommandIDs: [String] = [
    CommandID.selectWorktree1,
    CommandID.selectWorktree2,
    CommandID.selectWorktree3,
    CommandID.selectWorktree4,
    CommandID.selectWorktree5,
    CommandID.selectWorktree6,
    CommandID.selectWorktree7,
    CommandID.selectWorktree8,
    CommandID.selectWorktree9,
  ]

  static let terminalTabSelection: [AppShortcut] = [
    selectTerminalTab1,
    selectTerminalTab2,
    selectTerminalTab3,
    selectTerminalTab4,
    selectTerminalTab5,
    selectTerminalTab6,
    selectTerminalTab7,
    selectTerminalTab8,
    selectTerminalTab9,
  ]

  static let terminalTabSelectionCommandIDs: [String] = [
    CommandID.selectTerminalTab1,
    CommandID.selectTerminalTab2,
    CommandID.selectTerminalTab3,
    CommandID.selectTerminalTab4,
    CommandID.selectTerminalTab5,
    CommandID.selectTerminalTab6,
    CommandID.selectTerminalTab7,
    CommandID.selectTerminalTab8,
    CommandID.selectTerminalTab9,
  ]

  private static let reservedCustomCommandBindings: [ReservedCustomCommandBinding] = [
    .init(actionTitle: "Open Settings", shortcut: openSettings),
    .init(actionTitle: "Toggle Left Sidebar", shortcut: toggleLeftSidebar),
    .init(actionTitle: "Toggle Active Agents Panel", shortcut: toggleActiveAgentsPanel),
    .init(actionTitle: "Select Next Agent", shortcut: selectNextActiveAgent),
    .init(actionTitle: "Select Previous Agent", shortcut: selectPreviousActiveAgent),
    .init(actionTitle: "Jump to Latest Unread", shortcut: jumpToLatestUnread),
    .init(actionTitle: "Run Script", shortcut: runScript),
    .init(actionTitle: "Stop Script", shortcut: stopRunScript),
    .init(actionTitle: "Check for Updates", shortcut: checkForUpdates),
    .init(actionTitle: "Show Diff", shortcut: showDiff),
    .init(actionTitle: "Show Outgoing Changes", shortcut: outgoingChanges),
    .init(actionTitle: "Open Worktree", shortcut: openFinder),
    .init(actionTitle: "Open Repository", shortcut: openRepository),
    .init(actionTitle: "Select Terminal Tab 1", shortcut: selectTerminalTab1),
    .init(actionTitle: "Select Terminal Tab 2", shortcut: selectTerminalTab2),
    .init(actionTitle: "Select Terminal Tab 3", shortcut: selectTerminalTab3),
    .init(actionTitle: "Select Terminal Tab 4", shortcut: selectTerminalTab4),
    .init(actionTitle: "Select Terminal Tab 5", shortcut: selectTerminalTab5),
    .init(actionTitle: "Select Terminal Tab 6", shortcut: selectTerminalTab6),
    .init(actionTitle: "Select Terminal Tab 7", shortcut: selectTerminalTab7),
    .init(actionTitle: "Select Terminal Tab 8", shortcut: selectTerminalTab8),
    .init(actionTitle: "Select Terminal Tab 9", shortcut: selectTerminalTab9),
    .init(actionTitle: "Select Previous Tab", shortcut: selectPreviousTerminalTab),
    .init(actionTitle: "Select Next Tab", shortcut: selectNextTerminalTab),
    .init(actionTitle: "Select Previous Pane", shortcut: selectPreviousTerminalPane),
    .init(actionTitle: "Select Next Pane", shortcut: selectNextTerminalPane),
    .init(actionTitle: "Select Pane Up", shortcut: selectTerminalPaneUp),
    .init(actionTitle: "Select Pane Down", shortcut: selectTerminalPaneDown),
    .init(actionTitle: "Select Pane Left", shortcut: selectTerminalPaneLeft),
    .init(actionTitle: "Select Pane Right", shortcut: selectTerminalPaneRight),
    .init(actionTitle: "Toggle Split Zoom", shortcut: toggleSplitZoom),
  ]

  static let bindings: [Binding] = [
    .init(
      id: CommandID.newWorktree,
      title: "New Worktree",
      scope: .configurableAppAction,
      shortcut: newWorktree
    ),
    .init(
      id: CommandID.openSettings,
      title: "Open Settings",
      scope: .configurableAppAction,
      shortcut: openSettings
    ),
    .init(
      id: CommandID.openWorktree,
      title: "Open Worktree",
      scope: .configurableAppAction,
      shortcut: openFinder
    ),
    .init(
      id: CommandID.openRepository,
      title: "Open Repository",
      scope: .configurableAppAction,
      shortcut: openRepository
    ),
    .init(
      id: CommandID.openPullRequest,
      title: "Open on Code Host",
      scope: .configurableAppAction,
      shortcut: openPullRequest
    ),
    .init(
      id: CommandID.toggleLeftSidebar,
      title: "Toggle Left Sidebar",
      scope: .configurableAppAction,
      shortcut: toggleLeftSidebar
    ),
    .init(
      id: CommandID.toggleActiveAgentsPanel,
      title: "Toggle Active Agents Panel",
      scope: .configurableAppAction,
      shortcut: toggleActiveAgentsPanel
    ),
    .init(
      id: CommandID.toggleAgentIsland,
      title: "Toggle Agent Island",
      scope: .configurableAppAction,
      shortcut: nil
    ),
    .init(
      id: CommandID.selectNextActiveAgent,
      title: "Select Next Agent",
      scope: .configurableAppAction,
      shortcut: selectNextActiveAgent
    ),
    .init(
      id: CommandID.selectPreviousActiveAgent,
      title: "Select Previous Agent",
      scope: .configurableAppAction,
      shortcut: selectPreviousActiveAgent
    ),
    .init(
      id: CommandID.refreshWorktrees,
      title: "Refresh Worktrees",
      scope: .configurableAppAction,
      shortcut: refreshWorktrees
    ),
    .init(
      id: CommandID.jumpToLatestUnread,
      title: "Jump to Latest Unread",
      scope: .configurableAppAction,
      shortcut: jumpToLatestUnread
    ),
    .init(
      id: CommandID.runScript,
      title: "Run Script",
      scope: .configurableAppAction,
      shortcut: runScript
    ),
    .init(
      id: CommandID.stopScript,
      title: "Stop Script",
      scope: .configurableAppAction,
      shortcut: stopRunScript
    ),
    .init(
      id: CommandID.checkForUpdates,
      title: "Check for Updates",
      scope: .configurableAppAction,
      shortcut: checkForUpdates
    ),
    .init(
      id: CommandID.showDiff,
      title: "Show Diff",
      scope: .configurableAppAction,
      shortcut: showDiff
    ),
    .init(
      id: CommandID.outgoingChanges,
      title: "Show Outgoing Changes",
      scope: .configurableAppAction,
      shortcut: outgoingChanges
    ),
    .init(
      id: CommandID.toggleCanvas,
      title: "Toggle Canvas",
      scope: .configurableAppAction,
      shortcut: toggleCanvas
    ),
    .init(
      id: CommandID.toggleShelf,
      title: "Toggle Shelf",
      scope: .configurableAppAction,
      shortcut: toggleShelf
    ),
    .init(
      id: CommandID.selectNextShelfBook,
      title: "Select Next Book",
      scope: .configurableAppAction,
      shortcut: selectNextShelfBook
    ),
    .init(
      id: CommandID.selectPreviousShelfBook,
      title: "Select Previous Book",
      scope: .configurableAppAction,
      shortcut: selectPreviousShelfBook
    ),
    .init(
      id: CommandID.selectShelfBook1,
      title: "Select Book 1",
      scope: .configurableAppAction,
      shortcut: selectShelfBook1
    ),
    .init(
      id: CommandID.selectShelfBook2,
      title: "Select Book 2",
      scope: .configurableAppAction,
      shortcut: selectShelfBook2
    ),
    .init(
      id: CommandID.selectShelfBook3,
      title: "Select Book 3",
      scope: .configurableAppAction,
      shortcut: selectShelfBook3
    ),
    .init(
      id: CommandID.selectShelfBook4,
      title: "Select Book 4",
      scope: .configurableAppAction,
      shortcut: selectShelfBook4
    ),
    .init(
      id: CommandID.selectShelfBook5,
      title: "Select Book 5",
      scope: .configurableAppAction,
      shortcut: selectShelfBook5
    ),
    .init(
      id: CommandID.selectShelfBook6,
      title: "Select Book 6",
      scope: .configurableAppAction,
      shortcut: selectShelfBook6
    ),
    .init(
      id: CommandID.selectShelfBook7,
      title: "Select Book 7",
      scope: .configurableAppAction,
      shortcut: selectShelfBook7
    ),
    .init(
      id: CommandID.selectShelfBook8,
      title: "Select Book 8",
      scope: .configurableAppAction,
      shortcut: selectShelfBook8
    ),
    .init(
      id: CommandID.selectShelfBook9,
      title: "Select Book 9",
      scope: .configurableAppAction,
      shortcut: selectShelfBook9
    ),
    .init(
      id: CommandID.revealInSidebar,
      title: "Reveal in Sidebar",
      scope: .configurableAppAction,
      shortcut: revealInSidebar
    ),
    .init(
      id: CommandID.archivedWorktrees,
      title: "Archived Worktrees",
      scope: .configurableAppAction,
      shortcut: archivedWorktrees
    ),
    .init(
      id: CommandID.selectNextWorktree,
      title: "Select Next Worktree (Tab in Shelf View)",
      scope: .configurableAppAction,
      shortcut: selectNextWorktree
    ),
    .init(
      id: CommandID.selectPreviousWorktree,
      title: "Select Previous Worktree (Tab in Shelf View)",
      scope: .configurableAppAction,
      shortcut: selectPreviousWorktree
    ),
    .init(
      id: CommandID.worktreeHistoryBack,
      title: "Back in Worktree History",
      scope: .configurableAppAction,
      shortcut: worktreeHistoryBack
    ),
    .init(
      id: CommandID.worktreeHistoryForward,
      title: "Forward in Worktree History",
      scope: .configurableAppAction,
      shortcut: worktreeHistoryForward
    ),
    .init(
      id: CommandID.selectWorktree1,
      title: "Select Worktree 1",
      scope: .configurableAppAction,
      shortcut: selectWorktree1
    ),
    .init(
      id: CommandID.selectWorktree2,
      title: "Select Worktree 2",
      scope: .configurableAppAction,
      shortcut: selectWorktree2
    ),
    .init(
      id: CommandID.selectWorktree3,
      title: "Select Worktree 3",
      scope: .configurableAppAction,
      shortcut: selectWorktree3
    ),
    .init(
      id: CommandID.selectWorktree4,
      title: "Select Worktree 4",
      scope: .configurableAppAction,
      shortcut: selectWorktree4
    ),
    .init(
      id: CommandID.selectWorktree5,
      title: "Select Worktree 5",
      scope: .configurableAppAction,
      shortcut: selectWorktree5
    ),
    .init(
      id: CommandID.selectWorktree6,
      title: "Select Worktree 6",
      scope: .configurableAppAction,
      shortcut: selectWorktree6
    ),
    .init(
      id: CommandID.selectWorktree7,
      title: "Select Worktree 7",
      scope: .configurableAppAction,
      shortcut: selectWorktree7
    ),
    .init(
      id: CommandID.selectWorktree8,
      title: "Select Worktree 8",
      scope: .configurableAppAction,
      shortcut: selectWorktree8
    ),
    .init(
      id: CommandID.selectWorktree9,
      title: "Select Worktree 9",
      scope: .configurableAppAction,
      shortcut: selectWorktree9
    ),
    .init(
      id: CommandID.selectTerminalTab1,
      title: "Select Terminal Tab 1",
      scope: .configurableAppAction,
      shortcut: selectTerminalTab1
    ),
    .init(
      id: CommandID.selectTerminalTab2,
      title: "Select Terminal Tab 2",
      scope: .configurableAppAction,
      shortcut: selectTerminalTab2
    ),
    .init(
      id: CommandID.selectTerminalTab3,
      title: "Select Terminal Tab 3",
      scope: .configurableAppAction,
      shortcut: selectTerminalTab3
    ),
    .init(
      id: CommandID.selectTerminalTab4,
      title: "Select Terminal Tab 4",
      scope: .configurableAppAction,
      shortcut: selectTerminalTab4
    ),
    .init(
      id: CommandID.selectTerminalTab5,
      title: "Select Terminal Tab 5",
      scope: .configurableAppAction,
      shortcut: selectTerminalTab5
    ),
    .init(
      id: CommandID.selectTerminalTab6,
      title: "Select Terminal Tab 6",
      scope: .configurableAppAction,
      shortcut: selectTerminalTab6
    ),
    .init(
      id: CommandID.selectTerminalTab7,
      title: "Select Terminal Tab 7",
      scope: .configurableAppAction,
      shortcut: selectTerminalTab7
    ),
    .init(
      id: CommandID.selectTerminalTab8,
      title: "Select Terminal Tab 8",
      scope: .configurableAppAction,
      shortcut: selectTerminalTab8
    ),
    .init(
      id: CommandID.selectTerminalTab9,
      title: "Select Terminal Tab 9",
      scope: .configurableAppAction,
      shortcut: selectTerminalTab9
    ),
    .init(
      id: CommandID.selectPreviousTerminalTab,
      title: "Select Previous Tab",
      scope: .configurableAppAction,
      shortcut: selectPreviousTerminalTab
    ),
    .init(
      id: CommandID.selectNextTerminalTab,
      title: "Select Next Tab",
      scope: .configurableAppAction,
      shortcut: selectNextTerminalTab
    ),
    .init(
      id: CommandID.selectPreviousTerminalPane,
      title: "Select Previous Pane",
      scope: .configurableAppAction,
      shortcut: selectPreviousTerminalPane
    ),
    .init(
      id: CommandID.selectNextTerminalPane,
      title: "Select Next Pane",
      scope: .configurableAppAction,
      shortcut: selectNextTerminalPane
    ),
    .init(
      id: CommandID.selectTerminalPaneUp,
      title: "Select Pane Up",
      scope: .configurableAppAction,
      shortcut: selectTerminalPaneUp
    ),
    .init(
      id: CommandID.selectTerminalPaneDown,
      title: "Select Pane Down",
      scope: .configurableAppAction,
      shortcut: selectTerminalPaneDown
    ),
    .init(
      id: CommandID.selectTerminalPaneLeft,
      title: "Select Pane Left",
      scope: .configurableAppAction,
      shortcut: selectTerminalPaneLeft
    ),
    .init(
      id: CommandID.selectTerminalPaneRight,
      title: "Select Pane Right",
      scope: .configurableAppAction,
      shortcut: selectTerminalPaneRight
    ),
    .init(
      id: CommandID.toggleSplitZoom,
      title: "Toggle Split Zoom",
      scope: .configurableAppAction,
      shortcut: toggleSplitZoom
    ),
    .init(
      id: CommandID.commandPalette,
      title: "Command Palette",
      scope: .configurableAppAction,
      shortcut: commandPalette
    ),
    .init(
      id: CommandID.quitApplication,
      title: "Quit Application",
      scope: .systemFixedAppAction,
      shortcut: quitApplication
    ),
    .init(
      id: CommandID.renameBranch,
      title: "Rename Branch",
      scope: .localInteraction,
      shortcut: renameBranch
    ),
    .init(
      id: CommandID.selectAllCanvasCards,
      title: "Select All Canvas Cards",
      scope: .localInteraction,
      shortcut: selectAllCanvasCards
    ),
    .init(
      id: CommandID.arrangeCanvasCards,
      title: "Arrange Canvas Cards",
      scope: .localInteraction,
      shortcut: arrangeCanvasCards
    ),
    .init(
      id: CommandID.organizeCanvasCards,
      title: "Organize Canvas Cards",
      scope: .localInteraction,
      shortcut: organizeCanvasCards
    ),
    .init(
      id: CommandID.tileCanvasCards,
      title: "Tile Canvas Cards",
      scope: .localInteraction,
      shortcut: tileCanvasCards
    ),
    .init(
      id: CommandID.expandCanvasCard,
      title: "Expand / Restore Canvas Card",
      scope: .localInteraction,
      shortcut: expandCanvasCard
    ),
    .init(
      id: CommandID.startSearch,
      title: "Find",
      scope: .configurableAppAction,
      shortcut: startSearch
    ),
    .init(
      id: CommandID.findNext,
      title: "Find Next",
      scope: .configurableAppAction,
      shortcut: findNext
    ),
    .init(
      id: CommandID.findPrevious,
      title: "Find Previous",
      scope: .configurableAppAction,
      shortcut: findPrevious
    ),
  ]

  static func userOverrideConflicts(
    in commands: [UserCustomCommand]
  ) -> [CustomCommandOverrideConflict] {
    userOverrideConflicts(in: commands.map { EffectiveCustomCommand(source: .repository, command: $0) })
  }

  static func userOverrideConflicts(
    in commands: [EffectiveCustomCommand]
  ) -> [CustomCommandOverrideConflict] {
    var seen = Set<String>()
    return commands.compactMap { effectiveCommand in
      let command = effectiveCommand.command
      guard let shortcut = command.shortcut?.normalized(), shortcut.isValid else { return nil }
      guard let appBinding = matchingReservedBinding(for: shortcut) else { return nil }

      let signature =
        "\(effectiveCommand.paletteID)|\(shortcut.display)|\(appBinding.actionTitle)|\(appBinding.shortcut.display)"
      guard seen.insert(signature).inserted else { return nil }

      return CustomCommandOverrideConflict(
        commandTitle: command.resolvedTitle,
        commandShortcutDisplay: shortcut.display,
        appActionTitle: appBinding.actionTitle,
        appShortcutDisplay: appBinding.shortcut.display
      )
    }
  }

  private static func matchingReservedBinding(
    for shortcut: UserCustomShortcut
  ) -> ReservedCustomCommandBinding? {
    guard let key = shortcut.normalizedConflictKey else { return nil }
    let modifiers = shortcut.modifiers.eventModifiers
    return reservedCustomCommandBindings.first {
      $0.shortcut.normalizedConflictKey == key && $0.shortcut.modifiers == modifiers
    }
  }

  static func binding(for id: String) -> Binding? {
    bindings.first { $0.id == id }
  }

  static func defaultShortcut(for id: String) -> AppShortcut? {
    binding(for: id)?.shortcut
  }

  static func resolvedShortcut(for id: String, in resolvedKeybindings: ResolvedKeybindingMap) -> AppShortcut? {
    guard let resolvedBinding = resolvedKeybindings.binding(for: id) else {
      return defaultShortcut(for: id)
    }
    return resolvedBinding.binding?.appShortcut
  }

  static func display(for commandID: String, in resolvedKeybindings: ResolvedKeybindingMap) -> String? {
    resolvedShortcut(for: commandID, in: resolvedKeybindings)?.display
  }

  static func helpText(
    title: String,
    commandID: String,
    in resolvedKeybindings: ResolvedKeybindingMap
  ) -> String {
    if let shortcut = display(for: commandID, in: resolvedKeybindings) {
      return "\(title) (\(shortcut))"
    }
    return title
  }

  static func worktreeSelectionDisplay(at index: Int, in resolvedKeybindings: ResolvedKeybindingMap) -> String? {
    guard worktreeSelectionCommandIDs.indices.contains(index) else { return nil }
    return display(for: worktreeSelectionCommandIDs[index], in: resolvedKeybindings)
  }

  /// Combined up/down display for the Active Agents list navigation (e.g. "⌥⌃↑↓").
  ///
  /// Returns `nil` once either binding has been customized, so callers can hide a
  /// hint that the merged glyph form could otherwise render inaccurately.
  static func activeAgentsNavigationDisplay(in resolvedKeybindings: ResolvedKeybindingMap) -> String? {
    guard
      let previous = resolvedKeybindings.binding(for: CommandID.selectPreviousActiveAgent),
      let next = resolvedKeybindings.binding(for: CommandID.selectNextActiveAgent),
      previous.source == .appDefault,
      next.source == .appDefault,
      let upDisplay = resolvedKeybindings.display(for: CommandID.selectPreviousActiveAgent),
      let downGlyph = resolvedKeybindings.display(for: CommandID.selectNextActiveAgent)?.last
    else {
      return nil
    }
    return upDisplay + String(downGlyph)
  }

  static func terminalTabSelectionDisplay(at index: Int, in resolvedKeybindings: ResolvedKeybindingMap) -> String? {
    guard terminalTabSelectionCommandIDs.indices.contains(index) else { return nil }
    return display(for: terminalTabSelectionCommandIDs[index], in: resolvedKeybindings)
  }

  private static let ghosttyManagedActionBindings: [(commandID: String, action: String)] = [
    (CommandID.selectTerminalTab1, "goto_tab:1"),
    (CommandID.selectTerminalTab2, "goto_tab:2"),
    (CommandID.selectTerminalTab3, "goto_tab:3"),
    (CommandID.selectTerminalTab4, "goto_tab:4"),
    (CommandID.selectTerminalTab5, "goto_tab:5"),
    (CommandID.selectTerminalTab6, "goto_tab:6"),
    (CommandID.selectTerminalTab7, "goto_tab:7"),
    (CommandID.selectTerminalTab8, "goto_tab:8"),
    (CommandID.selectTerminalTab9, "goto_tab:9"),
    (CommandID.selectPreviousTerminalTab, "previous_tab"),
    (CommandID.selectNextTerminalTab, "next_tab"),
    (CommandID.selectPreviousTerminalPane, "goto_split:previous"),
    (CommandID.selectNextTerminalPane, "goto_split:next"),
    (CommandID.selectTerminalPaneUp, "goto_split:up"),
    (CommandID.selectTerminalPaneDown, "goto_split:down"),
    (CommandID.selectTerminalPaneLeft, "goto_split:left"),
    (CommandID.selectTerminalPaneRight, "goto_split:right"),
    (CommandID.toggleSplitZoom, "toggle_split_zoom"),
  ]

  static func ghosttyCLIKeybindArguments(from resolvedKeybindings: ResolvedKeybindingMap) -> [String] {
    var unbindArguments: [String] = []
    var seenUnbindArguments = Set<String>()
    func appendUnbindArgument(_ argument: String) {
      if seenUnbindArguments.insert(argument).inserted {
        unbindArguments.append(argument)
      }
    }

    for binding in bindings where binding.scope == .configurableAppAction {
      if let argument = resolvedShortcut(for: binding.id, in: resolvedKeybindings)?.ghosttyUnbindArgument {
        appendUnbindArgument(argument)
      }
    }

    for (commandID, _) in ghosttyManagedActionBindings {
      if let defaultUnbind = binding(for: commandID)?.shortcut?.ghosttyUnbindArgument {
        appendUnbindArgument(defaultUnbind)
      }
    }

    var managedActionArguments: [String] = []
    for (commandID, action) in ghosttyManagedActionBindings {
      guard let shortcut = resolvedShortcut(for: commandID, in: resolvedKeybindings) else { continue }
      managedActionArguments.append(contentsOf: shortcut.ghosttyBindArguments(action: action))
    }

    return unbindArguments + managedActionArguments
  }

  static var ghosttyCLIKeybindArguments: [String] {
    ghosttyCLIKeybindArguments(from: .appDefaults)
  }

  static let all: [AppShortcut] = [
    newWorktree,
    openSettings,
    openFinder,
    openRepository,
    openPullRequest,
    toggleLeftSidebar,
    toggleActiveAgentsPanel,
    selectNextActiveAgent,
    selectPreviousActiveAgent,
    revealInSidebar,
    refreshWorktrees,
    jumpToLatestUnread,
    runScript,
    stopRunScript,
    checkForUpdates,
    showDiff,
    outgoingChanges,
    toggleCanvas,
    toggleShelf,
    selectNextShelfBook,
    selectPreviousShelfBook,
    selectShelfBook1,
    selectShelfBook2,
    selectShelfBook3,
    selectShelfBook4,
    selectShelfBook5,
    selectShelfBook6,
    selectShelfBook7,
    selectShelfBook8,
    selectShelfBook9,
    archivedWorktrees,
    selectNextWorktree,
    selectPreviousWorktree,
    worktreeHistoryBack,
    worktreeHistoryForward,
    selectWorktree1,
    selectWorktree2,
    selectWorktree3,
    selectWorktree4,
    selectWorktree5,
    selectWorktree6,
    selectWorktree7,
    selectWorktree8,
    selectWorktree9,
    selectTerminalTab1,
    selectTerminalTab2,
    selectTerminalTab3,
    selectTerminalTab4,
    selectTerminalTab5,
    selectTerminalTab6,
    selectTerminalTab7,
    selectTerminalTab8,
    selectTerminalTab9,
    selectPreviousTerminalTab,
    selectNextTerminalTab,
    selectPreviousTerminalPane,
    selectNextTerminalPane,
    selectTerminalPaneUp,
    selectTerminalPaneDown,
    selectTerminalPaneLeft,
    selectTerminalPaneRight,
    toggleSplitZoom,
  ]
}

extension UserCustomShortcut {
  fileprivate var normalizedConflictKey: String? {
    let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized.count == 1 else { return nil }
    return normalized
  }
}
