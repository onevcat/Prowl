import AppKit
import ComposableArchitecture
import SwiftUI

struct WorktreeCommands: Commands {
  @Bindable var store: StoreOf<AppFeature>
  @FocusedValue(\.openSelectedWorktreeAction) private var openSelectedWorktreeAction
  @FocusedValue(\.confirmWorktreeAction) private var confirmWorktreeAction
  @FocusedValue(\.archiveWorktreeAction) private var archiveWorktreeAction
  @FocusedValue(\.deleteWorktreeAction) private var deleteWorktreeAction
  @FocusedValue(\.runScriptAction) private var runScriptAction
  @FocusedValue(\.stopRunScriptAction) private var stopRunScriptAction
  @FocusedValue(\.visibleHotkeyWorktreeRows) private var visibleHotkeyWorktreeRows

  init(store: StoreOf<AppFeature>) {
    self.store = store
  }

  var body: some Commands {
    let repositories = store.repositories
    let hasActiveWorktree =
      repositories.selectedTerminalWorktree != nil
      || (repositories.isShowingCanvas && !store.selectedCustomCommands.isEmpty)
    let orderedRows = visibleHotkeyWorktreeRows ?? repositories.orderedWorktreeRows()
    let codeHostWorktreeID = selectedCodeHostWorktreeID
    let codeHostLabel = "Open on \(repositories.codeHost(forWorktreeID: codeHostWorktreeID).displayName)"
    let deleteShortcut = KeyboardShortcut(.delete, modifiers: [.command, .shift]).display
    let customCommands = store.selectedCustomCommands
    CommandMenu("Worktrees") {
      Button("Select Next Worktree") {
        store.send(.repositories(.selectNextWorktree))
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.selectNextWorktree))
      )
      .help(helpText(title: "Select Next Worktree", commandID: AppShortcuts.CommandID.selectNextWorktree))
      .disabled(orderedRows.isEmpty)
      Button("Select Previous Worktree") {
        store.send(.repositories(.selectPreviousWorktree))
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.selectPreviousWorktree))
      )
      .help(helpText(title: "Select Previous Worktree", commandID: AppShortcuts.CommandID.selectPreviousWorktree))
      .disabled(orderedRows.isEmpty)
      Button("Back in Worktree History") {
        store.send(.repositories(.worktreeHistoryBack))
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.worktreeHistoryBack))
      )
      .help(helpText(title: "Back in Worktree History", commandID: AppShortcuts.CommandID.worktreeHistoryBack))
      .disabled(!repositories.canNavigateWorktreeHistoryBackward)
      Button("Forward in Worktree History") {
        store.send(.repositories(.worktreeHistoryForward))
      }
      .modifier(
        KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.worktreeHistoryForward))
      )
      .help(helpText(title: "Forward in Worktree History", commandID: AppShortcuts.CommandID.worktreeHistoryForward))
      .disabled(!repositories.canNavigateWorktreeHistoryForward)
      Divider()
      ForEach(worktreeMenuEntries(orderedRows: orderedRows)) { entry in
        worktreeMenuButton(entry: entry)
      }
      Divider()
      Button("Archived Worktrees") {
        store.send(.repositories(.selectArchivedWorktrees))
      }
      .modifier(KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.archivedWorktrees)))
      .help(helpText(title: "Archived Worktrees", commandID: AppShortcuts.CommandID.archivedWorktrees))
    }
    CommandGroup(replacing: .newItem) {
      if !customCommands.isEmpty {
        ForEach(Array(customCommands.enumerated()), id: \.element.id) { index, command in
          customCommandButton(
            index: index,
            command: command,
            hasActiveWorktree: hasActiveWorktree
          )
        }
        Divider()
      }
      Button("Open Repository...", systemImage: "folder") {
        store.send(.repositories(.setOpenPanelPresented(true)))
      }
      .modifier(KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.openRepository)))
      .help(helpText(title: "Open Repository", commandID: AppShortcuts.CommandID.openRepository))
      Button("Open Worktree") {
        openSelectedWorktreeAction?()
      }
      .modifier(KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.openWorktree)))
      .help(helpText(title: "Open Worktree", commandID: AppShortcuts.CommandID.openWorktree))
      .disabled(openSelectedWorktreeAction == nil)
      Button(codeHostLabel) {
        if let codeHostWorktreeID {
          store.send(.repositories(.githubIntegration(.pullRequestAction(codeHostWorktreeID, .openOnCodeHost))))
        }
      }
      .modifier(KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.openPullRequest)))
      .help(helpText(title: codeHostLabel, commandID: AppShortcuts.CommandID.openPullRequest))
      .disabled(codeHostWorktreeID == nil)
      Button("New Worktree", systemImage: "plus") {
        store.send(.repositories(.worktreeCreation(.createRandomWorktree)))
      }
      .modifier(KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.newWorktree)))
      .help(helpText(title: "New Worktree", commandID: AppShortcuts.CommandID.newWorktree))
      .disabled(!repositories.canCreateWorktree)
      Button(repositories.isShowingCanvas ? "Exit Canvas" : "Canvas") {
        store.send(.repositories(.toggleCanvas))
      }
      .modifier(KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.toggleCanvas)))
      .help(helpText(title: "Toggle Canvas", commandID: AppShortcuts.CommandID.toggleCanvas))
      Button("Archive Worktree") {
        archiveWorktreeAction?()
      }
      .help("Archive Worktree")
      .disabled(archiveWorktreeAction == nil)
      Button("Delete Worktree") {
        deleteWorktreeAction?()
      }
      .keyboardShortcut(.delete, modifiers: [.command, .shift])
      .help("Delete Worktree (\(deleteShortcut))")
      .disabled(deleteWorktreeAction == nil)
      Button("Confirm Worktree Action") {
        confirmWorktreeAction?()
      }
      .keyboardShortcut(.return, modifiers: .command)
      .help("Confirm Worktree Action (⌘↩)")
      .disabled(confirmWorktreeAction == nil)
      Button("Refresh Worktrees") {
        store.send(.repositories(.refreshWorktrees))
      }
      .modifier(KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.refreshWorktrees)))
      .help(helpText(title: "Refresh Worktrees", commandID: AppShortcuts.CommandID.refreshWorktrees))
      Button("Jump to Latest Unread") {
        store.send(.jumpToLatestUnread)
      }
      .modifier(KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.jumpToLatestUnread)))
      .help(helpText(title: "Jump to Latest Unread", commandID: AppShortcuts.CommandID.jumpToLatestUnread))
      .disabled(store.notificationIndicatorCount == 0)
      Divider()
      Button("Run Script") {
        runScriptAction?()
      }
      .modifier(KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.runScript)))
      .help(helpText(title: "Run Script", commandID: AppShortcuts.CommandID.runScript))
      .disabled(runScriptAction == nil)
      Button("Stop Script") {
        stopRunScriptAction?()
      }
      .modifier(KeyboardShortcutModifier(shortcut: keyboardShortcut(for: AppShortcuts.CommandID.stopScript)))
      .help(helpText(title: "Stop Script", commandID: AppShortcuts.CommandID.stopScript))
      .disabled(stopRunScriptAction == nil)
    }
  }

  private var worktreeShortcutCommandIDs: [String] {
    AppShortcuts.worktreeSelectionCommandIDs
  }

  private var selectedCodeHostWorktreeID: Worktree.ID? {
    let repositories = store.repositories
    guard let selectedWorktreeID = repositories.selectedWorktreeID else { return nil }
    guard
      let repositoryID = repositories.repositoryID(containing: selectedWorktreeID),
      repositories.repositories[id: repositoryID]?.capabilities.supportsCodeHost == true
    else {
      return nil
    }
    return selectedWorktreeID
  }

  private func keyboardShortcut(for commandID: String) -> KeyboardShortcut? {
    store.resolvedKeybindings.keyboardShortcut(for: commandID)
  }

  private func shortcutDisplay(for commandID: String) -> String? {
    store.resolvedKeybindings.display(for: commandID)
  }

  private func helpText(title: String, commandID: String) -> String {
    if let shortcut = shortcutDisplay(for: commandID) {
      return "\(title) (\(shortcut))"
    }
    return title
  }

  private func customCommandID(for command: UserCustomCommand) -> String {
    LegacyCustomCommandShortcutMigration.customCommandBindingID(for: command.id)
  }

  private func customCommandShortcut(for command: UserCustomCommand) -> KeyboardShortcut? {
    store.resolvedKeybindings.keyboardShortcut(for: customCommandID(for: command))
  }

  private func customCommandShortcutDisplay(for command: UserCustomCommand) -> String? {
    store.resolvedKeybindings.display(for: customCommandID(for: command))
  }

  private func worktreeMenuEntries(orderedRows: [WorktreeRowModel]) -> [WorktreeMenuEntry] {
    let shortcutIDs = worktreeShortcutCommandIDs
    var shortcutByWorktreeID: [String: String] = [:]
    for (index, commandID) in shortcutIDs.enumerated() where orderedRows.indices.contains(index) {
      shortcutByWorktreeID[orderedRows[index].id] = commandID
    }

    let repositories = store.repositories
    let reposByID = Dictionary(uniqueKeysWithValues: repositories.repositories.map { ($0.id, $0) })

    var entries: [WorktreeMenuEntry] = []
    for repoID in repositories.orderedRepositoryIDs() {
      guard let repo = reposByID[repoID] else { continue }
      if repo.kind == .plain {
        entries.append(
          WorktreeMenuEntry(
            kind: .plainFolder(id: repo.id, name: repo.name),
            shortcutCommandID: nil
          ))
      } else {
        for row in repositories.worktreeRows(in: repo) {
          entries.append(
            WorktreeMenuEntry(
              kind: .worktree(row),
              shortcutCommandID: shortcutByWorktreeID[row.id]
            ))
        }
      }
    }
    return entries
  }

  @ViewBuilder
  private func worktreeMenuButton(entry: WorktreeMenuEntry) -> some View {
    switch entry.kind {
    case .worktree(let row):
      let repoName = store.repositories.repositoryName(for: row.repositoryID) ?? "Repository"
      let title = "\(repoName) — \(row.name)"
      Button(title) {
        store.send(.repositories(.selectWorktree(row.id)))
      }
      .modifier(
        KeyboardShortcutModifier(
          shortcut: entry.shortcutCommandID.flatMap { keyboardShortcut(for: $0) }
        )
      )
      .help(
        {
          if let commandID = entry.shortcutCommandID, let shortcut = shortcutDisplay(for: commandID) {
            return "Switch to \(title) (\(shortcut))"
          }
          return "Switch to \(title)"
        }())
    case .plainFolder(let repoID, let name):
      Button(name) {
        store.send(.repositories(.selectRepository(repoID)))
      }
      .help("Switch to \(name)")
    }
  }

  @ViewBuilder
  private func customCommandButton(
    index: Int,
    command: UserCustomCommand,
    hasActiveWorktree: Bool
  ) -> some View {
    let title = command.resolvedTitle
    let helpText: String =
      if let shortcut = customCommandShortcutDisplay(for: command) {
        "\(title) (\(shortcut))"
      } else {
        title
      }
    Button(title, systemImage: command.resolvedSystemImage) {
      store.send(.runCustomCommand(index))
    }
    .modifier(KeyboardShortcutModifier(shortcut: customCommandShortcut(for: command)))
    .help(helpText)
    .disabled(!hasActiveWorktree)
  }
}

private struct WorktreeMenuEntry: Identifiable {
  enum Kind {
    case worktree(WorktreeRowModel)
    case plainFolder(id: Repository.ID, name: String)
  }

  let kind: Kind
  let shortcutCommandID: String?

  var id: String {
    switch kind {
    case .worktree(let row): row.id
    case .plainFolder(let repoID, _): "plain-\(repoID)"
    }
  }
}

private struct ArchiveWorktreeActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

private struct OpenSelectedWorktreeActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

private struct DeleteWorktreeActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

private struct ConfirmWorktreeActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

extension FocusedValues {
  var openSelectedWorktreeAction: FocusedAction<Void>? {
    get { self[OpenSelectedWorktreeActionKey.self] }
    set { self[OpenSelectedWorktreeActionKey.self] = newValue }
  }

  var confirmWorktreeAction: FocusedAction<Void>? {
    get { self[ConfirmWorktreeActionKey.self] }
    set { self[ConfirmWorktreeActionKey.self] = newValue }
  }

  var archiveWorktreeAction: FocusedAction<Void>? {
    get { self[ArchiveWorktreeActionKey.self] }
    set { self[ArchiveWorktreeActionKey.self] = newValue }
  }

  var deleteWorktreeAction: FocusedAction<Void>? {
    get { self[DeleteWorktreeActionKey.self] }
    set { self[DeleteWorktreeActionKey.self] = newValue }
  }

  var runScriptAction: FocusedAction<Void>? {
    get { self[RunScriptActionKey.self] }
    set { self[RunScriptActionKey.self] = newValue }
  }

  var stopRunScriptAction: FocusedAction<Void>? {
    get { self[StopRunScriptActionKey.self] }
    set { self[StopRunScriptActionKey.self] = newValue }
  }

  var visibleHotkeyWorktreeRows: [WorktreeRowModel]? {
    get { self[VisibleHotkeyWorktreeRowsKey.self] }
    set { self[VisibleHotkeyWorktreeRowsKey.self] = newValue }
  }
}

private struct RunScriptActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

private struct StopRunScriptActionKey: FocusedValueKey {
  typealias Value = FocusedAction<Void>
}

private struct VisibleHotkeyWorktreeRowsKey: FocusedValueKey {
  typealias Value = [WorktreeRowModel]
}
