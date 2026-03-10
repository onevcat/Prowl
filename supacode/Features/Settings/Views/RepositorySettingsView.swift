import ComposableArchitecture
import SwiftUI

struct RepositorySettingsView: View {
  @Bindable var store: StoreOf<RepositorySettingsFeature>
  @State private var isBranchPickerPresented = false
  @State private var branchSearchText = ""

  var body: some View {
    let baseRefOptions =
      store.branchOptions.isEmpty ? [store.defaultWorktreeBaseRef] : store.branchOptions
    let settings = $store.settings
    let onevcatSettings = $store.onevcatSettings
    let worktreeBaseDirectoryPath = Binding(
      get: { settings.worktreeBaseDirectoryPath.wrappedValue ?? "" },
      set: { settings.worktreeBaseDirectoryPath.wrappedValue = $0 },
    )
    let exampleWorktreePath = store.exampleWorktreePath
    Form {
      Section {
        if store.isBranchDataLoaded {
          Button {
            branchSearchText = ""
            isBranchPickerPresented = true
          } label: {
            HStack {
              Text(store.settings.worktreeBaseRef ?? "Automatic (\(store.defaultWorktreeBaseRef))")
                .foregroundStyle(.primary)
              Spacer()
              Image(systemName: "chevron.up.chevron.down")
                .foregroundStyle(.secondary)
                .font(.caption)
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .popover(isPresented: $isBranchPickerPresented) {
            BranchPickerPopover(
              searchText: $branchSearchText,
              options: baseRefOptions,
              automaticLabel: "Automatic (\(store.defaultWorktreeBaseRef))",
              selection: store.settings.worktreeBaseRef,
              onSelect: { ref in
                store.settings.worktreeBaseRef = ref
                isBranchPickerPresented = false
              }
            )
          }
        } else {
          ProgressView()
            .controlSize(.small)
        }
      } header: {
        VStack(alignment: .leading, spacing: 4) {
          Text("Branch new workspaces from")
          Text("Each workspace is an isolated copy of your codebase.")
            .foregroundStyle(.secondary)
        }
      }
      Section {
        VStack(alignment: .leading) {
          TextField(
            "Inherit global default",
            text: worktreeBaseDirectoryPath
          )
          .textFieldStyle(.roundedBorder)
          Text("Set a repository-specific worktree base directory. Leave empty to inherit the global setting.")
            .foregroundStyle(.secondary)
          Text("Example new worktree path: \(exampleWorktreePath)")
            .foregroundStyle(.secondary)
            .monospaced()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Toggle(
          "Copy ignored files to new worktrees",
          isOn: settings.copyIgnoredOnWorktreeCreate
        )
        .disabled(store.isBareRepository)
        Toggle(
          "Copy untracked files to new worktrees",
          isOn: settings.copyUntrackedOnWorktreeCreate
        )
        .disabled(store.isBareRepository)
        if store.isBareRepository {
          Text("Copy flags are ignored for bare repositories.")
            .foregroundStyle(.secondary)
        }
      } header: {
        VStack(alignment: .leading, spacing: 4) {
          Text("Worktree")
          Text("Applies when creating a new worktree")
            .foregroundStyle(.secondary)
        }
      }
      Section {
        Picker(
          "Merge strategy",
          selection: settings.pullRequestMergeStrategy
        ) {
          ForEach(PullRequestMergeStrategy.allCases) { strategy in
            Text(strategy.title)
              .tag(strategy)
          }
        }
        .labelsHidden()
      } header: {
        VStack(alignment: .leading, spacing: 4) {
          Text("Pull Requests")
          Text("Used when merging PRs from the command palette")
            .foregroundStyle(.secondary)
        }
      }
      Section {
        ZStack(alignment: .topLeading) {
          PlainTextEditor(
            text: settings.setupScript
          )
          .frame(minHeight: 120)
          if store.settings.setupScript.isEmpty {
            Text("claude --dangerously-skip-permissions")
              .foregroundStyle(.secondary)
              .padding(.leading, 6)
              .font(.body)
              .allowsHitTesting(false)
          }
        }
      } header: {
        VStack(alignment: .leading, spacing: 4) {
          Text("Setup Script")
          Text("Initial setup script that will be launched once after worktree creation")
            .foregroundStyle(.secondary)
        }
      }
      Section {
        ZStack(alignment: .topLeading) {
          PlainTextEditor(
            text: settings.archiveScript
          )
          .frame(minHeight: 120)
          if store.settings.archiveScript.isEmpty {
            Text("docker compose down")
              .foregroundStyle(.secondary)
              .padding(.leading, 6)
              .font(.body)
              .allowsHitTesting(false)
          }
        }
      } header: {
        VStack(alignment: .leading, spacing: 4) {
          Text("Archive Script")
          Text("Archive script that runs before a worktree is archived")
            .foregroundStyle(.secondary)
        }
      }
      Section {
        ZStack(alignment: .topLeading) {
          PlainTextEditor(
            text: settings.runScript
          )
          .frame(minHeight: 120)
          if store.settings.runScript.isEmpty {
            Text("npm run dev")
              .foregroundStyle(.secondary)
              .padding(.leading, 6)
              .font(.body)
              .allowsHitTesting(false)
          }
        }
      } header: {
        VStack(alignment: .leading, spacing: 4) {
          Text("Run Script")
          Text("Run script launched on demand from the toolbar")
            .foregroundStyle(.secondary)
        }
      }
      Section {
        ForEach(onevcatSettings.customCommands) { $command in
          OnevcatCustomCommandCard(
            command: $command,
            onRemove: {
              removeCustomCommand(id: command.id)
            }
          )
        }
        if store.onevcatSettings.customCommands.count < OnevcatRepositorySettings.maxCustomCommands {
          Button {
            addCustomCommand()
          } label: {
            Label("Add Command", systemImage: "plus")
          }
          .help("Add a custom command")
        }
      } header: {
        VStack(alignment: .leading, spacing: 4) {
          Text("Custom Commands")
          Text("Onevcat-only commands shown after Run in the toolbar (up to 3)")
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task {
      store.send(.task)
    }
  }

  private func addCustomCommand() {
    let current = store.onevcatSettings.customCommands
    let next = current + [.default(index: current.count)]
    store.onevcatSettings.customCommands = OnevcatRepositorySettings.normalizedCommands(next)
  }

  private func removeCustomCommand(id: OnevcatCustomCommand.ID) {
    store.onevcatSettings.customCommands.removeAll { $0.id == id }
  }
}

private struct BranchPickerPopover: View {
  @Binding var searchText: String
  let options: [String]
  let automaticLabel: String
  let selection: String?
  let onSelect: (String?) -> Void
  @FocusState private var isSearchFocused: Bool

  var filteredOptions: [String] {
    if searchText.isEmpty { return options }
    return options.filter { $0.localizedCaseInsensitiveContains(searchText) }
  }

  var body: some View {
    VStack(spacing: 0) {
      TextField("Filter branches...", text: $searchText)
        .textFieldStyle(.roundedBorder)
        .focused($isSearchFocused)
        .padding(8)
      Divider()
      List {
        Button {
          onSelect(nil)
        } label: {
          HStack {
            Text(automaticLabel)
            Spacer()
            if selection == nil {
              Image(systemName: "checkmark")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            }
          }
          .padding(.vertical, 6)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        ForEach(filteredOptions, id: \.self) { ref in
          Button {
            onSelect(ref)
          } label: {
            HStack {
              Text(ref)
              Spacer()
              if selection == ref {
                Image(systemName: "checkmark")
                  .foregroundStyle(.tint)
                  .accessibilityHidden(true)
              }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .listStyle(.plain)
    }
    .frame(width: 300, height: 350)
    .onAppear { isSearchFocused = true }
  }
}

private struct OnevcatCustomCommandCard: View {
  @Binding var command: OnevcatCustomCommand
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline, spacing: 12) {
        TextField("Name", text: $command.title)
          .textFieldStyle(.roundedBorder)
        TextField("SF Symbol", text: $command.systemImage)
          .textFieldStyle(.roundedBorder)
        Picker("Type", selection: $command.execution) {
          ForEach(OnevcatCustomCommandExecution.allCases) { execution in
            Text(execution.title)
              .tag(execution)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 180)
        Button(role: .destructive) {
          onRemove()
        } label: {
          Image(systemName: "trash")
            .accessibilityLabel("Remove command")
        }
        .help("Remove this custom command")
      }
      .font(.caption)

      shortcutEditor

      ZStack(alignment: .topLeading) {
        PlainTextEditor(
          text: $command.command,
          isMonospaced: true
        )
        .frame(minHeight: 100)
        if command.command.isEmpty {
          Text(placeholder)
            .foregroundStyle(.secondary)
            .padding(.leading, 6)
            .font(.body.monospaced())
            .allowsHitTesting(false)
        }
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var shortcutEditor: some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle("Enable Shortcut", isOn: shortcutEnabled)
      if let shortcut = Binding($command.shortcut) {
        HStack(spacing: 12) {
          TextField("Key", text: shortcutKeyBinding(shortcut))
            .textFieldStyle(.roundedBorder)
            .frame(width: 70)
          modifierToggle("⌘", isOn: shortcut.modifiers.command)
          modifierToggle("⇧", isOn: shortcut.modifiers.shift)
          modifierToggle("⌥", isOn: shortcut.modifiers.option)
          modifierToggle("⌃", isOn: shortcut.modifiers.control)
          Spacer(minLength: 0)
          Text(shortcut.wrappedValue.display)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        .font(.caption)
      }
    }
  }

  private var shortcutEnabled: Binding<Bool> {
    Binding(
      get: { command.shortcut != nil },
      set: { enabled in
        if enabled {
          command.shortcut =
            command.shortcut
            ?? OnevcatCustomShortcut(
              key: "",
              modifiers: OnevcatCustomShortcutModifiers()
            )
        } else {
          command.shortcut = nil
        }
      }
    )
  }

  private func shortcutKeyBinding(_ shortcut: Binding<OnevcatCustomShortcut>) -> Binding<String> {
    Binding(
      get: { shortcut.wrappedValue.key },
      set: { value in
        let scalar = value.trimmingCharacters(in: .whitespacesAndNewlines).first
        shortcut.wrappedValue.key = scalar.map { String($0).lowercased() } ?? ""
      }
    )
  }

  private func modifierToggle(_ symbol: String, isOn: Binding<Bool>) -> some View {
    HStack(spacing: 4) {
      Text(symbol)
      Toggle("", isOn: isOn)
        .labelsHidden()
    }
    .fixedSize()
  }

  private var placeholder: String {
    switch command.execution {
    case .shellScript:
      return "npm test && swift test"
    case .terminalInput:
      return "pnpm test --watch"
    }
  }
}
