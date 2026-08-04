import SwiftUI

struct MultiSelectedWorktreeSummary: Identifiable {
  let id: Worktree.ID
  let name: String
  let repositoryName: String?
}

struct MultiSelectedWorktreesDetailView: View {
  let rows: [MultiSelectedWorktreeSummary]

  private let visibleRowsLimit = 8

  var body: some View {
    let deleteShortcut = KeyboardShortcut(.delete, modifiers: [.command, .shift]).display
    VStack(alignment: .leading, spacing: 16) {
      Text("\(rows.count) worktrees selected")
        .interfaceFont(.title3)
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array(rows.prefix(visibleRowsLimit))) { row in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.name)
              .lineLimit(1)
            if let repositoryName = row.repositoryName {
              Text(repositoryName)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
          .interfaceFont(.body)
        }
        if rows.count > visibleRowsLimit {
          Text("+\(rows.count - visibleRowsLimit) more")
            .interfaceFont(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Divider()
      VStack(alignment: .leading, spacing: 6) {
        Text("Available actions")
          .interfaceFont(.headline)
        Text("Archive selected")
        Text("Delete selected (\(deleteShortcut))")
        Text("Right-click any selected worktree to apply actions to all selected worktrees.")
      }
      .interfaceFont(.caption)
      .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

struct RunScriptToolbarButton: View {
  let isRunning: Bool
  let isEnabled: Bool
  let runHelpText: String
  let stopHelpText: String
  let runShortcut: String?
  let stopShortcut: String?
  let runAction: () -> Void
  let stopAction: () -> Void
  @Environment(CommandKeyObserver.self) private var commandKeyObserver

  var body: some View {
    if isRunning {
      button(
        config: RunScriptButtonConfig(
          title: "Stop",
          systemImage: "stop.fill",
          helpText: stopHelpText,
          shortcut: stopShortcut,
          isEnabled: true,
          action: stopAction
        ))
    } else {
      button(
        config: RunScriptButtonConfig(
          title: "Run",
          systemImage: "play.fill",
          helpText: runHelpText,
          shortcut: runShortcut,
          isEnabled: isEnabled,
          action: runAction
        ))
    }
  }

  @ViewBuilder
  private func button(config: RunScriptButtonConfig) -> some View {
    Button {
      config.action()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: config.systemImage)
          .accessibilityHidden(true)
        Text(config.title)

        if commandKeyObserver.isPressed, let shortcut = config.shortcut {
          Text(shortcut)
            .interfaceFont(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .interfaceFont(.caption)
    .help(config.helpText)
    .disabled(!config.isEnabled)
  }

  private struct RunScriptButtonConfig {
    let title: String
    let systemImage: String
    let helpText: String
    let shortcut: String?
    let isEnabled: Bool
    let action: () -> Void
  }
}

struct UserCustomCommandToolbarButton: View {
  let title: String
  let systemImage: String
  let source: CustomCommandSource
  let shortcut: String?
  let isEnabled: Bool
  let action: () -> Void
  @Environment(CommandKeyObserver.self) private var commandKeyObserver

  var body: some View {
    Button {
      action()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: systemImage)
          .accessibilityHidden(true)
        Text(title)
        if commandKeyObserver.isPressed, let shortcut {
          Text(shortcut)
            .interfaceFont(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .interfaceFont(.caption)
    .help(helpText)
    .disabled(!isEnabled)
  }

  private var helpText: String {
    guard isEnabled else {
      switch source {
      case .repository:
        return "\(title) (Set command script in Repository Settings)"
      case .global:
        return "\(title) (Set command script in Settings → Commands)"
      }
    }
    var text = title
    if let shortcut {
      text = "\(title) (\(shortcut))"
    }
    if let note = source.tooltipNote {
      text += " — \(note)"
    }
    return text
  }
}

struct CustomCommandOverflowButton: View {
  let entries: [EffectiveCustomCommand]
  let shortcutDisplay: (EffectiveCustomCommand) -> String?
  let onRunCustomCommand: (EffectiveCustomCommand.Identifier) -> Void

  @State private var isPresented = false
  @Environment(\.interfaceTextScale) private var interfaceTextScale
  private let maxVisibleRows = 10

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      Image(systemName: "chevron.down")
        .interfaceFont(.caption2)
        .accessibilityLabel("More custom commands")
    }
    .help("More custom commands")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(entries) { entry in
            Button {
              isPresented = false
              onRunCustomCommand(entry.id)
            } label: {
              HStack(spacing: 8) {
                Image(systemName: entry.command.resolvedSystemImage)
                  .foregroundStyle(.secondary)
                  .frame(width: 14 * interfaceTextScale)
                  .accessibilityHidden(true)
                Text(entry.command.resolvedTitle)
                  .interfaceFont(.body)
                  .lineLimit(1)
                Spacer(minLength: 0)
                if let shortcut = shortcutDisplay(entry) {
                  Text(shortcut)
                    .interfaceFont(.caption, design: .monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
              }
              .padding(.horizontal, 8)
              .padding(.vertical, 6)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!entry.command.hasRunnableCommand)
            .help(helpText(for: entry))
          }
        }
        .padding(8)
      }
      .frame(width: 320, height: popoverHeight)
    }
  }

  private var popoverHeight: CGFloat {
    let visibleRows = min(maxVisibleRows, max(entries.count, 1))
    return CGFloat(visibleRows) * 32 * interfaceTextScale + 16
  }

  private func helpText(for entry: EffectiveCustomCommand) -> String {
    var text = entry.command.resolvedTitle
    if let shortcut = shortcutDisplay(entry) {
      text = "\(text) (\(shortcut))"
    }
    if let note = entry.source.tooltipNote {
      text += " — \(note)"
    }
    return text
  }
}

@MainActor
private struct WorktreeToolbarPreview: View {
  private let toolbarState: WorktreeDetailView.WorktreeToolbarState
  private let commandKeyObserver: CommandKeyObserver

  init() {
    toolbarState = WorktreeDetailView.WorktreeToolbarState(
      title: DetailToolbarTitle(kind: .branch(name: "feature/toolbar-preview")),
      agentsCapsule: AgentsCapsuleState(
        displayName: "codex",
        iconSource: CommandIconMap.iconForFirstToken("codex"),
        infoLine: "Pass this task to another agent in a new tab. codex will summarize its progress first."
      ),
      statusToast: nil,
      pullRequest: nil,
      codeHost: .github,
      notificationGroups: [],
      unseenNotificationWorktreeCount: 0,
      openActionSelection: .finder,
      openActionIsAutomatic: true,
      showExtras: false,
      runScriptEnabled: true,
      runScriptIsRunning: false,
      customCommands: [
        EffectiveCustomCommand(
          source: .repository,
          command: UserCustomCommand(
            title: "Test",
            systemImage: "checkmark.circle.fill",
            command: "swift test",
            execution: .shellScript,
            shortcut: UserCustomShortcut(
              key: "u",
              modifiers: UserCustomShortcutModifiers()
            )
          ))
      ],
      isUpdateAvailable: true,
      isUpdateReadyToInstall: false,
      availableUpdateVersion: "2026.5.1",
      showRunButtonInToolbar: true,
      showDefaultEditorInToolbar: true
    )
    let observer = CommandKeyObserver()
    observer.isPressed = false
    commandKeyObserver = observer
  }

  var body: some View {
    NavigationStack {
      Text("Worktree Toolbar")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .toolbar {
      WorktreeDetailView.WorktreeToolbarContent(
        toolbarState: toolbarState,
        onRenameBranch: { _ in },
        externalRenamePrompt: nil,
        onConsumeExternalRenamePrompt: { _ in },
        onOpenWorktree: { _ in },
        onOpenActionSelectionChanged: { _ in },
        onResetOpenActionToAutomatic: {},
        onCopyPath: {},
        onSelectNotification: { _, _ in },
        onDismissAllNotifications: {},
        onRunScript: {},
        onStopRunScript: {},
        onRunCustomCommand: { _ in },
        onActivateUpdateButton: {},
        onHandOff: {},
        onLaunchProfile: { _ in },
        onManageProfiles: {}
      )
    }
    .environment(commandKeyObserver)
    .frame(width: 900, height: 160)
  }
}

#Preview("Worktree Toolbar") {
  WorktreeToolbarPreview()
}

@MainActor
private struct CanvasToolbarPreview: View {
  var body: some View {
    NavigationSplitView {
      List {
        Text("Sidebar Item 1")
        Text("Sidebar Item 2")
      }
      .navigationSplitViewColumnWidth(220)
    } detail: {
      Text("Canvas Content")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Canvas")
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            ToolbarNotificationsPopoverButton(
              groups: [],
              unseenWorktreeCount: 0,
              onSelectNotification: { _, _ in },
              onDismissAll: {}
            )
          }
        }
    }
    .frame(width: 900, height: 300)
  }
}

#Preview("Canvas Toolbar") {
  CanvasToolbarPreview()
}
