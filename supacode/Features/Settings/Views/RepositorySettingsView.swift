import AppKit
import ComposableArchitecture
import SwiftUI

struct RepositorySettingsView: View {
  @Bindable var store: StoreOf<RepositorySettingsFeature>
  @State private var isBranchPickerPresented = false
  @State private var branchSearchText = ""

  @State private var selectedCustomCommandID: UserCustomCommand.ID?
  @State private var recordingCustomCommandID: UserCustomCommand.ID?
  @State private var recorderMonitor: Any?
  @State private var invalidMessageByCommandID: [UserCustomCommand.ID: String] = [:]
  @State private var pendingShortcutConflict: CustomCommandShortcutConflict?
  @State private var pendingShortcut: PendingCustomShortcut?
  @State private var iconPickerCommandID: UserCustomCommand.ID?
  @State private var customCommandsFocusAnchor: NSView?
  @State private var popoverRefocusTask: Task<Void, Never>?
  @State private var commandEditorCommandID: UserCustomCommand.ID?
  @State private var editingNameCommandID: UserCustomCommand.ID?
  @FocusState private var focusedNameEditorCommandID: UserCustomCommand.ID?

  private let keyTokenResolver = ShortcutKeyTokenResolver()

  private static let symbolPresets = [
    "terminal",
    "terminal.fill",
    "play.fill",
    "stop.fill",
    "hammer.fill",
    "shippingbox.fill",
    "doc.text.fill",
    "sparkles",
    "bolt.fill",
    "flame.fill",
    "wand.and.stars",
    "wrench.and.screwdriver.fill",
    "checkmark.circle.fill",
    "xmark.circle.fill",
    "exclamationmark.triangle.fill",
    "ladybug.fill",
    "clock.fill",
    "repeat",
    "arrow.clockwise",
    "folder.fill",
    "archivebox.fill",
    "paperplane.fill",
    "cloud.fill",
    "tray.and.arrow.down.fill",
    "tray.and.arrow.up.fill",
    "icloud.and.arrow.up.fill",
    "square.and.arrow.up.fill",
    "arrow.triangle.2.circlepath",
    "folder.badge.plus",
    "doc.badge.plus",
  ]

  var body: some View {
    let baseRefOptions =
      store.branchOptions.isEmpty ? [store.defaultWorktreeBaseRef] : store.branchOptions
    let settings = $store.settings
    let worktreeBaseDirectoryPath = Binding(
      get: { settings.worktreeBaseDirectoryPath.wrappedValue ?? "" },
      set: { settings.worktreeBaseDirectoryPath.wrappedValue = $0 },
    )
    let customTitle = Binding(
      get: { settings.customTitle.wrappedValue ?? "" },
      set: { settings.customTitle.wrappedValue = $0 },
    )
    let exampleWorktreePath = store.exampleWorktreePath
    let folderName = Repository.name(for: store.rootURL)

    Form {
      Section("Display") {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text("Name")
            Spacer().frame(width: 20)
            TextField("", text: customTitle, prompt: Text(folderName))
              .frame(width: 300)
              .textFieldStyle(.roundedBorder)
              .labelsHidden()
          }
          Divider()
          RepositoryAppearancePickerView(store: store)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      if store.showsWorktreeSettings {
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

          Picker(selection: settings.copyIgnoredOnWorktreeCreate) {
            Text(
              "Global \(Text(store.globalCopyIgnoredOnWorktreeCreate ? "Yes" : "No").foregroundStyle(.secondary))"
            )
            .tag(Bool?.none)
            Text("Yes").tag(Bool?.some(true))
            Text("No").tag(Bool?.some(false))
          } label: {
            Text("Copy ignored files to new worktrees")
            Text("Copies gitignored files from the main worktree.")
          }
          .disabled(store.isBareRepository)

          Picker(selection: settings.copyUntrackedOnWorktreeCreate) {
            Text(
              "Global \(Text(store.globalCopyUntrackedOnWorktreeCreate ? "Yes" : "No").foregroundStyle(.secondary))"
            )
            .tag(Bool?.none)
            Text("Yes").tag(Bool?.some(true))
            Text("No").tag(Bool?.some(false))
          } label: {
            Text("Copy untracked files to new worktrees")
            Text("Copies untracked files from the main worktree.")
          }
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
      }

      if store.showsWorktreeSettings {
        Section {
          lineChangesIntervalRow(
            title: "Focused interval",
            value: settings.focusedLineChangesRefreshIntervalSeconds
          )
          lineChangesIntervalRow(
            title: "Unfocused interval",
            value: settings.unfocusedLineChangesRefreshIntervalSeconds
          )
          Text("Increase this for very large repositories to reduce background Git diff work.")
            .foregroundStyle(.secondary)
        } header: {
          VStack(alignment: .leading, spacing: 4) {
            Text("Performance")
            Text("Controls repository background checks")
              .foregroundStyle(.secondary)
          }
        }
      }

      if store.showsPullRequestSettings {
        Section {
          Picker(selection: settings.pullRequestMergeStrategy) {
            Text(
              "Global \(Text(store.globalPullRequestMergeStrategy.title).foregroundStyle(.secondary))"
            )
            .tag(PullRequestMergeStrategy?.none)
            ForEach(PullRequestMergeStrategy.allCases) { strategy in
              Text(strategy.title).tag(PullRequestMergeStrategy?.some(strategy))
            }
          } label: {
            Text("Merge strategy")
            Text("Used when merging PRs from the command palette.")
          }
        } header: {
          VStack(alignment: .leading, spacing: 4) {
            Text("Pull Requests")
            Text("Used when merging PRs from the command palette")
              .foregroundStyle(.secondary)
          }
        }
      }
      Section {
        ScriptEnvironmentRow(
          name: "PROWL_WORKTREE_PATH",
          description: "Path to the active worktree."
        )
        ScriptEnvironmentRow(
          name: "PROWL_ROOT_PATH",
          value: store.rootURL.path(percentEncoded: false),
          description: "Path to the repository root."
        )
      } header: {
        VStack(alignment: .leading, spacing: 4) {
          Text("Environment Variables")
          Text("Exported in all scripts below")
            .foregroundStyle(.secondary)
        }
      }

      if store.showsSetupScriptSettings {
        Section {
          PlainTextEditor(
            text: settings.setupScript,
            placeholder: "claude --dangerously-skip-permissions"
          )
          .frame(minHeight: 120)
        } header: {
          VStack(alignment: .leading, spacing: 4) {
            Text("Setup Script")
            Text("Initial setup script that will be launched once after worktree creation")
              .foregroundStyle(.secondary)
          }
        }
      }

      if store.showsArchiveScriptSettings {
        Section {
          PlainTextEditor(
            text: settings.archiveScript,
            placeholder: "docker compose down"
          )
          .frame(minHeight: 120)
        } header: {
          VStack(alignment: .leading, spacing: 4) {
            Text("Archive Script")
            Text("Archive script that runs before a worktree is archived")
              .foregroundStyle(.secondary)
          }
        }
      }

      if store.showsRunScriptSettings {
        Section {
          PlainTextEditor(
            text: settings.runScript,
            placeholder: "npm run dev"
          )
          .frame(minHeight: 120)
        } header: {
          VStack(alignment: .leading, spacing: 4) {
            Text("Run Script")
            Text("Run script launched on demand from the toolbar")
              .foregroundStyle(.secondary)
          }
        }
      }

      if store.showsCustomCommandsSettings {
        Section {
          customCommandsEditor
        } header: {
          VStack(alignment: .leading, spacing: 4) {
            Text("Custom Commands")
            Text("Repository-local terminal actions. Custom command shortcuts take precedence in this repository.")
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task {
      store.send(.task)
      syncSelectedCommandID(with: store.userSettings.customCommands)
    }
    .onChange(of: store.userSettings.customCommands) { _, commands in
      syncSelectedCommandID(with: commands)
      clearRemovedCommandState(using: commands)
    }
    .onChange(of: selectedCustomCommandID) { _, selectedID in
      if editingNameCommandID != selectedID {
        editingNameCommandID = nil
      }
      focusedNameEditorCommandID = nil
      if let iconPickerCommandID, iconPickerCommandID != selectedID {
        self.iconPickerCommandID = nil
      }
      if let commandEditorCommandID, commandEditorCommandID != selectedID {
        self.commandEditorCommandID = nil
      }
      if let recordingCustomCommandID, recordingCustomCommandID != selectedID {
        self.recordingCustomCommandID = nil
      }
    }
    .onChange(of: recordingCustomCommandID) { _, commandID in
      if commandID == nil {
        stopRecorderMonitor()
      } else {
        startRecorderMonitor()
      }
    }
    .onDisappear {
      stopRecorderMonitor()
      popoverRefocusTask?.cancel()
      popoverRefocusTask = nil
      focusedNameEditorCommandID = nil
    }
    .alert(
      "Shortcut Conflict",
      isPresented: isShortcutConflictAlertPresented,
      presenting: pendingShortcutConflict
    ) { _ in
      Button("Replace", role: .destructive) {
        applyPendingShortcut(replacingConflict: true)
      }
      Button("Cancel", role: .cancel) {
        clearPendingShortcutConflict()
      }
    } message: { conflict in
      Text(
        "“\(conflict.newCommandTitle)” and “\(conflict.existingCommandTitle)” both use \(conflict.shortcutDisplay)."
          + "\n\nChoose Replace to keep the new shortcut and clear the conflicting command."
      )
    }
  }

  @ViewBuilder
  private var customCommandsEditor: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(spacing: 0) {
        customCommandsHeaderRow
        Divider()
        ScrollView {
          LazyVStack(spacing: 4) {
            ForEach(store.userSettings.customCommands) { command in
              customCommandRow(command)
                .id(command.id)
            }
          }
          .padding(.horizontal, 6)
          .padding(.vertical, 6)
        }
        .frame(height: customCommandsListHeight)
      }
      .clipShape(RoundedRectangle(cornerRadius: 8))

      HStack(spacing: 8) {
        Button {
          addCustomCommand()
        } label: {
          ZStack {
            Image(systemName: "plus")
              .frame(width: 16, height: 16)
          }
          .frame(width: 28, height: 28)
          .contentShape(Rectangle())
          .accessibilityLabel("Add command")
        }
        .buttonStyle(.plain)
        .help("Add command")

        Button {
          removeSelectedCustomCommand()
        } label: {
          ZStack {
            Image(systemName: "minus")
              .frame(width: 16, height: 16)
          }
          .frame(width: 28, height: 28)
          .contentShape(Rectangle())
          .accessibilityLabel("Remove selected command")
        }
        .buttonStyle(.plain)
        .disabled(store.userSettings.customCommands.isEmpty)
        .help("Remove selected command")

        Spacer(minLength: 0)

        Text("\(store.userSettings.customCommands.count) commands")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let invalidMessage = selectedCommandInvalidMessage {
        Text(invalidMessage)
          .font(.caption)
          .foregroundStyle(.red)
      } else {
        Text("Click cells to edit icon, name, command, and shortcut inline.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .background {
      FirstResponderAnchorView { anchor in
        if customCommandsFocusAnchor !== anchor {
          customCommandsFocusAnchor = anchor
        }
      }
      .frame(width: 0, height: 0)
    }
  }

  @ViewBuilder
  private func customCommandIconCell(_ command: UserCustomCommand) -> some View {
    if let binding = bindingForCustomCommand(id: command.id) {
      InlineEditableCellButton(
        isActive: iconPickerCommandID == command.id,
        contentAlignment: .center
      ) {
        selectCustomCommand(command.id)
        toggleIconEditor(for: command.id)
      } label: {
        Image(systemName: binding.wrappedValue.resolvedSystemImage)
          .foregroundStyle(.secondary)
          .frame(width: 16, alignment: .center)
          .accessibilityHidden(true)
      }
      .popover(
        isPresented: Binding(
          get: { iconPickerCommandID == command.id },
          set: { isPresented in
            if !isPresented {
              closePopoverAndRestoreCommandFocus(for: command.id)
            }
          }
        ),
        arrowEdge: .bottom
      ) {
        iconEditorPopover(for: binding, commandID: command.id)
      }
    } else {
      InlineEditableCellButton(
        contentAlignment: .center
      ) {
        selectCustomCommand(command.id)
      } label: {
        Image(systemName: command.resolvedSystemImage)
          .foregroundStyle(.secondary)
          .frame(width: 16, alignment: .center)
          .accessibilityHidden(true)
      }
    }
  }

  @ViewBuilder
  private func customCommandNameCell(_ command: UserCustomCommand) -> some View {
    let isSelected = selectedCustomCommandID == command.id
    if isSelected,
      editingNameCommandID == command.id,
      let binding = bindingForCustomCommand(id: command.id)
    {
      InlineEditableFieldContainer(isActive: true) {
        TextField("", text: binding.title)
          .textFieldStyle(.plain)
          .padding(.leading, -4)
          .focused($focusedNameEditorCommandID, equals: command.id)
          .onSubmit {
            endNameEditing()
          }
      }
      .onAppear {
        focusedNameEditorCommandID = command.id
      }
    } else {
      InlineEditableCellButton {
        selectCustomCommand(command.id)
        beginNameEditing(for: command.id)
      } label: {
        Text(bindingForCustomCommand(id: command.id)?.wrappedValue.resolvedTitle ?? command.resolvedTitle)
          .lineLimit(1)
      }
    }
  }

  @ViewBuilder
  private func customCommandCell(_ command: UserCustomCommand) -> some View {
    if let binding = bindingForCustomCommand(id: command.id) {
      InlineEditableCellButton(
        isActive: commandEditorCommandID == command.id
      ) {
        selectCustomCommand(command.id)
        toggleCommandEditor(for: command.id)
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text(inlineCommandTitle(for: binding.wrappedValue.execution))
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(inlineCommandScriptPreview(for: binding.wrappedValue.command))
            .lineLimit(1)
        }
      }
      .popover(
        isPresented: Binding(
          get: { commandEditorCommandID == command.id },
          set: { isPresented in
            if !isPresented {
              closePopoverAndRestoreCommandFocus(for: command.id)
            }
          }
        ),
        arrowEdge: .bottom
      ) {
        commandEditorPopover(for: binding)
      }
      .help("New Tab runs in a new tab. In Place sends input to the focused terminal.")
    } else {
      InlineEditableCellButton {
        selectCustomCommand(command.id)
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Text(inlineCommandTitle(for: command.execution))
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(inlineCommandScriptPreview(for: command.command))
            .lineLimit(1)
        }
      }
    }
  }

  @ViewBuilder
  private func customCommandShortcutCell(_ command: UserCustomCommand) -> some View {
    let resolvedBinding = resolvedCustomCommandBindings.keybinding(for: customCommandBindingID(for: command.id))
    let shortcutDisplay = resolvedBinding?.display ?? "Unassigned"
    let isRecording = recordingCustomCommandID == command.id

    InlineEditableCellButton(
      isActive: isRecording,
      activeColor: .orange
    ) {
      selectCustomCommand(command.id)
      toggleRecording(for: command.id)
    } label: {
      Text(isRecording ? "Recording…" : shortcutDisplay)
        .font(.body.monospaced())
        .foregroundStyle(isRecording ? Color.orange : (resolvedBinding == nil ? .secondary : .primary))
        .lineLimit(1)
    }
    .contextMenu {
      if command.shortcut != nil {
        Button("Clear Shortcut") {
          clearShortcut(for: command.id)
        }
      }
    }
    .help(isRecording ? "Recording shortcut. Press Esc to cancel." : "Click to record a shortcut.")
  }

  private var effectiveSelectedCommandID: UserCustomCommand.ID? {
    selectedCustomCommandID ?? editingNameCommandID ?? commandEditorCommandID ?? iconPickerCommandID
      ?? recordingCustomCommandID
  }

  private var removableCommandID: UserCustomCommand.ID? {
    let commands = store.userSettings.customCommands
    if let selectedCustomCommandID,
      commands.contains(where: { $0.id == selectedCustomCommandID })
    {
      return selectedCustomCommandID
    }
    if let effectiveSelectedCommandID,
      commands.contains(where: { $0.id == effectiveSelectedCommandID })
    {
      return effectiveSelectedCommandID
    }
    return commands.last?.id
  }

  private var customCommandsHeaderRow: some View {
    HStack(spacing: 8) {
      customCommandHeaderCell("", width: customCommandsIconColumnWidth, alignment: .center)
      customCommandHeaderCell("Name", width: customCommandsNameColumnWidth)
      customCommandHeaderCell("Command")
      customCommandHeaderCell("Shortcut", width: customCommandsShortcutColumnWidth)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .font(.headline)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private func customCommandRow(_ command: UserCustomCommand) -> some View {
    let isSelected = selectedCustomCommandID == command.id
    HStack(spacing: 8) {
      customCommandRowCell(width: customCommandsIconColumnWidth, alignment: .center) {
        customCommandIconCell(command)
      }
      customCommandRowCell(width: customCommandsNameColumnWidth) {
        customCommandNameCell(command)
      }
      customCommandRowCell {
        customCommandCell(command)
      }
      customCommandRowCell(width: customCommandsShortcutColumnWidth) {
        customCommandShortcutCell(command)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 2)
    .background {
      RoundedRectangle(cornerRadius: 8)
        .fill(isSelected ? Color.accentColor.opacity(0.35) : .clear)
    }
    .contentShape(RoundedRectangle(cornerRadius: 8))
    .accessibilityAddTraits(.isButton)
    .onTapGesture {
      selectCustomCommand(command.id)
    }
  }

  @ViewBuilder
  private func customCommandHeaderCell(
    _ title: String,
    width: CGFloat? = nil,
    alignment: Alignment = .leading
  ) -> some View {
    if let width {
      Text(title)
        .frame(width: width, alignment: alignment)
    } else {
      Text(title)
        .frame(maxWidth: .infinity, alignment: alignment)
    }
  }

  @ViewBuilder
  private func customCommandRowCell<Content: View>(
    width: CGFloat? = nil,
    alignment: Alignment = .leading,
    @ViewBuilder content: () -> Content
  ) -> some View {
    if let width {
      content()
        .frame(width: width, alignment: alignment)
        .frame(maxHeight: .infinity, alignment: alignment)
    } else {
      content()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
  }

  private func selectCustomCommand(_ commandID: UserCustomCommand.ID) {
    if selectedCustomCommandID != commandID {
      selectedCustomCommandID = commandID
    }
  }

  private func inlineCommandTitle(for execution: UserCustomCommandExecution) -> String {
    switch execution {
    case .shellScript:
      return "New Tab"
    case .terminalInput:
      return "In Place"
    case .split:
      return "New Split"
    }
  }

  private func inlineCommandScriptPreview(for script: String) -> String {
    let firstLine =
      script
      .split(separator: "\n", omittingEmptySubsequences: false)
      .first
      .map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return firstLine.isEmpty ? "Click to set command script" : firstLine
  }

  private func iconEditorPopover(
    for command: Binding<UserCustomCommand>,
    commandID: UserCustomCommand.ID
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Icon")
        .font(.headline)
      Text("Pick from common symbols or enter any SF Symbol name available in your system.")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        TextField("SF Symbol name", text: command.systemImage)
          .textFieldStyle(.roundedBorder)
        Button("Open SF Symbols") {
          openSFSymbolsReference()
        }
      }

      ScrollView {
        LazyVGrid(
          columns: Array(repeating: GridItem(.fixed(24), spacing: 8), count: 10),
          spacing: 8
        ) {
          ForEach(Self.symbolPresets, id: \.self) { symbol in
            Button {
              command.wrappedValue.systemImage = symbol
              closePopoverAndRestoreCommandFocus(for: commandID)
            } label: {
              Image(systemName: symbol)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .help(symbol)
          }
        }
        .padding(12)
      }
      .frame(maxHeight: 124)
    }
    .padding(12)
    .frame(width: 360)
  }

  private func commandEditorPopover(for command: Binding<UserCustomCommand>) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Command")
        .font(.headline)
      Text("Choose where this command runs and edit the script used by this repository custom command.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Picker("Execution", selection: command.execution) {
        Text("New Tab")
          .tag(UserCustomCommandExecution.shellScript)
        Text("In Place")
          .tag(UserCustomCommandExecution.terminalInput)
        Text("New Split")
          .tag(UserCustomCommandExecution.split)
      }
      .pickerStyle(.segmented)

      if command.wrappedValue.execution == .split {
        Picker("Split Direction", selection: command.splitDirection) {
          ForEach(UserCustomSplitDirection.allCases) { direction in
            Text(direction.title).tag(direction)
          }
        }
        .pickerStyle(.menu)
        .help("Direction to split the focused terminal pane.")
      }

      PlainTextEditor(
        text: command.command,
        isMonospaced: true,
        shouldFocus: true,
        placeholder: scriptPlaceholder(for: command.wrappedValue.execution)
      )
      .frame(height: 140)

      Text(scriptDescription(for: command.wrappedValue.execution))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if command.wrappedValue.execution.supportsCloseOnSuccess {
        Toggle("Close on success", isOn: command.closeOnSuccess)
          .help("Automatically closes the tab or split when the command exits with code 0.")
          .toggleStyle(.checkbox)
      }
    }
    .padding(12)
    .frame(width: 420)
  }

  private var selectedCommandInvalidMessage: String? {
    guard let selectedCustomCommandID else {
      return nil
    }
    return invalidMessageByCommandID[selectedCustomCommandID]
  }

  private func openSFSymbolsReference() {
    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.SFSymbols") {
      let configuration = NSWorkspace.OpenConfiguration()
      NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }
      return
    }
    guard let url = URL(string: "https://developer.apple.com/sf-symbols/") else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  private func toggleIconEditor(for commandID: UserCustomCommand.ID) {
    if iconPickerCommandID == commandID {
      closePopoverAndRestoreCommandFocus(for: commandID)
      return
    }
    iconPickerCommandID = commandID
    commandEditorCommandID = nil
    endNameEditing()
    if recordingCustomCommandID == commandID {
      recordingCustomCommandID = nil
    }
  }

  private func toggleCommandEditor(for commandID: UserCustomCommand.ID) {
    if commandEditorCommandID == commandID {
      closePopoverAndRestoreCommandFocus(for: commandID)
      return
    }
    commandEditorCommandID = commandID
    iconPickerCommandID = nil
    endNameEditing()
    if recordingCustomCommandID == commandID {
      recordingCustomCommandID = nil
    }
  }

  private func beginNameEditing(for commandID: UserCustomCommand.ID) {
    editingNameCommandID = commandID
    iconPickerCommandID = nil
    commandEditorCommandID = nil
    if recordingCustomCommandID == commandID {
      recordingCustomCommandID = nil
    }
    focusedNameEditorCommandID = commandID
  }

  private func endNameEditing() {
    editingNameCommandID = nil
    focusedNameEditorCommandID = nil
  }

  private func closePopoverAndRestoreCommandFocus(for commandID: UserCustomCommand.ID) {
    popoverRefocusTask?.cancel()

    var transaction = Transaction()
    transaction.animation = nil
    withTransaction(transaction) {
      iconPickerCommandID = nil
      commandEditorCommandID = nil
    }
    focusCustomCommandsArea()
    scheduleCommandFocusRestore(for: commandID)
  }

  private func focusCustomCommandsArea() {
    guard let window = NSApp.keyWindow else {
      return
    }
    if let customCommandsFocusAnchor,
      customCommandsFocusAnchor.window === window
    {
      _ = window.makeFirstResponder(customCommandsFocusAnchor)
      return
    }
    _ = window.makeFirstResponder(nil)
  }

  private func scheduleCommandFocusRestore(for commandID: UserCustomCommand.ID) {
    popoverRefocusTask = Task { @MainActor in
      await Task.yield()
      guard !Task.isCancelled else {
        return
      }
      guard iconPickerCommandID == nil, commandEditorCommandID == nil else {
        return
      }
      guard store.userSettings.customCommands.contains(where: { $0.id == commandID }) else {
        return
      }

      var transaction = Transaction()
      transaction.animation = nil
      withTransaction(transaction) {
        selectCustomCommand(commandID)
        endNameEditing()
      }
    }
  }

  private func scriptPlaceholder(for execution: UserCustomCommandExecution) -> String {
    switch execution {
    case .shellScript:
      return "npm test && swift test"
    case .terminalInput:
      return "pnpm test --watch"
    case .split:
      return "tail -f logs/app.log"
    }
  }

  private func scriptDescription(for execution: UserCustomCommandExecution) -> String {
    switch execution {
    case .shellScript:
      return "Runs in a new terminal tab."
    case .terminalInput:
      return "Sends input to the currently focused terminal."
    case .split:
      return "Runs in a new split of the focused terminal."
    }
  }

  private var resolvedCustomCommandBindings: ResolvedKeybindingMap {
    let commands = store.userSettings.customCommands
    let migration = LegacyCustomCommandShortcutMigration.migrate(commands: commands)
    return KeybindingResolver.resolve(
      schema: .appResolverSchema(customCommands: commands),
      userOverrides: store.keybindingUserOverrides,
      migratedOverrides: migration.overrides
    )
  }

  private func customCommandBindingID(for commandID: String) -> String {
    LegacyCustomCommandShortcutMigration.customCommandBindingID(for: commandID)
  }

  private func bindingForCustomCommand(id commandID: UserCustomCommand.ID) -> Binding<UserCustomCommand>? {
    guard store.userSettings.customCommands.contains(where: { $0.id == commandID }) else {
      return nil
    }

    return Binding(
      get: {
        store.userSettings.customCommands.first(where: { $0.id == commandID })
          ?? UserCustomCommand(
            id: commandID,
            title: "",
            systemImage: "terminal",
            command: "",
            execution: .shellScript,
            shortcut: nil
          )
      },
      set: { updatedCommand in
        updateCustomCommand(id: commandID) { command in
          command.title = updatedCommand.title
          command.systemImage = updatedCommand.systemImage
          command.command = updatedCommand.command
          command.execution = updatedCommand.execution
          command.splitDirection = updatedCommand.splitDirection
          command.closeOnSuccess = updatedCommand.closeOnSuccess
          command.shortcut = updatedCommand.shortcut
        }
      }
    )
  }

  private func lineChangesIntervalRow(title: String, value: Binding<Int>) -> some View {
    LabeledContent {
      HStack(spacing: 8) {
        TextField("", value: value, format: .number)
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.trailing)
          .frame(width: 72)
        Text("seconds")
          .foregroundStyle(.secondary)
        Stepper(
          title,
          value: value,
          in: RepositorySettings.minimumLineChangesRefreshIntervalSeconds...3_600,
          step: 5
        )
        .labelsHidden()
      }
    } label: {
      Text(title)
    }
  }

  private func syncSelectedCommandID(with commands: [UserCustomCommand]) {
    guard !commands.isEmpty else {
      selectedCustomCommandID = nil
      recordingCustomCommandID = nil
      iconPickerCommandID = nil
      commandEditorCommandID = nil
      editingNameCommandID = nil
      focusedNameEditorCommandID = nil
      return
    }

    if let selectedCustomCommandID,
      commands.contains(where: { $0.id == selectedCustomCommandID })
    {
      return
    }

    selectedCustomCommandID = commands[0].id
  }

  private func clearRemovedCommandState(using commands: [UserCustomCommand]) {
    let validIDs = Set(commands.map(\.id))

    invalidMessageByCommandID = invalidMessageByCommandID.filter { validIDs.contains($0.key) }

    if let recordingCustomCommandID,
      !validIDs.contains(recordingCustomCommandID)
    {
      self.recordingCustomCommandID = nil
    }

    if let iconPickerCommandID,
      !validIDs.contains(iconPickerCommandID)
    {
      self.iconPickerCommandID = nil
    }

    if let commandEditorCommandID,
      !validIDs.contains(commandEditorCommandID)
    {
      self.commandEditorCommandID = nil
    }

    if let editingNameCommandID,
      !validIDs.contains(editingNameCommandID)
    {
      self.editingNameCommandID = nil
      focusedNameEditorCommandID = nil
    }
  }

  private func addCustomCommand() {
    let commandsBinding = $store.userSettings.customCommands
    let current = commandsBinding.wrappedValue
    let next = UserRepositorySettings.normalizedCommands(current + [.default(index: current.count)])
    commandsBinding.wrappedValue = next
    guard let commandID = next.last?.id else {
      selectedCustomCommandID = nil
      editingNameCommandID = nil
      focusedNameEditorCommandID = nil
      return
    }
    selectedCustomCommandID = commandID
    editingNameCommandID = commandID
    focusedNameEditorCommandID = commandID
    iconPickerCommandID = nil
    commandEditorCommandID = nil
    recordingCustomCommandID = nil
  }

  private func removeSelectedCustomCommand() {
    guard let selectedCommandID = removableCommandID else {
      return
    }

    let commandsBinding = $store.userSettings.customCommands
    var commands = commandsBinding.wrappedValue
    let removalIndex: Int?
    if let index = commands.firstIndex(where: { $0.id == selectedCommandID }) {
      removalIndex = index
      commands.remove(at: index)
    } else if !commands.isEmpty {
      removalIndex = commands.count - 1
      commands.removeLast()
    } else {
      removalIndex = nil
    }

    guard let removalIndex else {
      return
    }

    let normalizedCommands = UserRepositorySettings.normalizedCommands(commands)
    commandsBinding.wrappedValue = normalizedCommands

    if normalizedCommands.isEmpty {
      selectedCustomCommandID = nil
    } else if removalIndex < normalizedCommands.count {
      selectedCustomCommandID = normalizedCommands[removalIndex].id
    } else {
      selectedCustomCommandID = normalizedCommands[normalizedCommands.count - 1].id
    }
    clearRemovedCommandState(using: normalizedCommands)
  }

  private func clearShortcut(for commandID: UserCustomCommand.ID) {
    invalidMessageByCommandID[commandID] = nil
    updateCustomCommand(id: commandID) { command in
      command.shortcut = nil
    }
    if recordingCustomCommandID == commandID {
      recordingCustomCommandID = nil
    }
  }

  private func updateCustomCommand(
    id: UserCustomCommand.ID,
    update: (inout UserCustomCommand) -> Void
  ) {
    let commandsBinding = $store.userSettings.customCommands
    var commands = commandsBinding.wrappedValue
    guard let index = commands.firstIndex(where: { $0.id == id }) else {
      return
    }

    update(&commands[index])
    commandsBinding.wrappedValue = UserRepositorySettings.normalizedCommands(commands)
  }

  private func toggleRecording(for commandID: UserCustomCommand.ID) {
    invalidMessageByCommandID[commandID] = nil
    iconPickerCommandID = nil
    commandEditorCommandID = nil
    endNameEditing()

    if recordingCustomCommandID == commandID {
      recordingCustomCommandID = nil
      return
    }

    recordingCustomCommandID = commandID
  }

  private func startRecorderMonitor() {
    stopRecorderMonitor()
    recorderMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
      guard let commandID = recordingCustomCommandID else {
        return event
      }
      handleRecorderEvent(event, commandID: commandID)
      return nil
    }
  }

  private func stopRecorderMonitor() {
    if let recorderMonitor {
      NSEvent.removeMonitor(recorderMonitor)
      self.recorderMonitor = nil
    }
  }

  private func handleRecorderEvent(_ event: NSEvent, commandID: UserCustomCommand.ID) {
    if event.keyCode == 53 {  // Escape
      recordingCustomCommandID = nil
      return
    }

    guard
      let keyToken = keyTokenResolver.resolveKeyToken(
        keyCode: event.keyCode,
        charactersIgnoringModifiers: event.charactersIgnoringModifiers
      )
    else {
      invalidMessageByCommandID[commandID] = "Unsupported key. Use letters, numbers, or punctuation."
      return
    }

    let modifiers = KeybindingModifiers(
      command: event.modifierFlags.contains(.command),
      shift: event.modifierFlags.contains(.shift),
      option: event.modifierFlags.contains(.option),
      control: event.modifierFlags.contains(.control)
    )

    guard !modifiers.isEmpty else {
      invalidMessageByCommandID[commandID] = "Shortcut must include at least one modifier key."
      return
    }

    let binding = Keybinding(key: keyToken, modifiers: modifiers)
    guard let shortcut = binding.userCustomShortcut else {
      invalidMessageByCommandID[commandID] =
        "Custom command shortcuts support letters, numbers, and punctuation only."
      return
    }

    applyRecordedShortcut(shortcut.normalized(), to: commandID)
  }

  private func applyRecordedShortcut(
    _ shortcut: UserCustomShortcut,
    to commandID: UserCustomCommand.ID
  ) {
    invalidMessageByCommandID[commandID] = nil

    guard let existingCommand = firstConflictingCommand(for: commandID, shortcut: shortcut) else {
      updateCustomCommand(id: commandID) { command in
        command.shortcut = shortcut
      }
      recordingCustomCommandID = nil
      return
    }

    let newTitle =
      store.userSettings.customCommands.first(where: { $0.id == commandID })?.resolvedTitle ?? "Command"

    pendingShortcutConflict = CustomCommandShortcutConflict(
      newCommandID: commandID,
      newCommandTitle: newTitle,
      existingCommandID: existingCommand.id,
      existingCommandTitle: existingCommand.resolvedTitle,
      shortcutDisplay: shortcut.display
    )
    pendingShortcut = PendingCustomShortcut(commandID: commandID, shortcut: shortcut)
    recordingCustomCommandID = nil
  }

  private func firstConflictingCommand(
    for commandID: UserCustomCommand.ID,
    shortcut: UserCustomShortcut
  ) -> UserCustomCommand? {
    store.userSettings.customCommands.first { command in
      guard command.id != commandID else { return false }
      guard let existingShortcut = command.shortcut?.normalized() else { return false }
      return existingShortcut == shortcut
    }
  }

  private func applyPendingShortcut(replacingConflict: Bool) {
    guard let pendingShortcut else {
      clearPendingShortcutConflict()
      return
    }

    if replacingConflict,
      let existingCommandID = pendingShortcutConflict?.existingCommandID
    {
      updateCustomCommand(id: existingCommandID) { command in
        command.shortcut = nil
      }
    }

    updateCustomCommand(id: pendingShortcut.commandID) { command in
      command.shortcut = pendingShortcut.shortcut
    }

    clearPendingShortcutConflict()
  }

  private func clearPendingShortcutConflict() {
    pendingShortcutConflict = nil
    pendingShortcut = nil
  }

  private var isShortcutConflictAlertPresented: Binding<Bool> {
    Binding(
      get: { pendingShortcutConflict != nil },
      set: { shouldPresent in
        if !shouldPresent {
          clearPendingShortcutConflict()
        }
      }
    )
  }

  private var customCommandsIconColumnWidth: CGFloat { 48 }

  private var customCommandsNameColumnWidth: CGFloat { 130 }

  private var customCommandsShortcutColumnWidth: CGFloat { 100 }

  private var customCommandsListHeight: CGFloat { 200 }
}

private struct InlineEditableCellButton<Label: View>: View {
  let isActive: Bool
  let activeColor: Color
  let contentAlignment: Alignment
  let action: () -> Void
  @ViewBuilder let label: () -> Label

  @State private var isHovering = false

  init(
    isActive: Bool = false,
    activeColor: Color = .accentColor,
    contentAlignment: Alignment = .leading,
    action: @escaping () -> Void,
    @ViewBuilder label: @escaping () -> Label
  ) {
    self.isActive = isActive
    self.activeColor = activeColor
    self.contentAlignment = contentAlignment
    self.action = action
    self.label = label
  }

  var body: some View {
    Button(action: action) {
      label()
        .frame(maxWidth: .infinity, alignment: contentAlignment)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, alignment: contentAlignment)
    .onHover { hovering in
      isHovering = hovering
    }
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .strokeBorder(borderColor, lineWidth: borderWidth)
    }
  }

  private var borderColor: Color {
    if isActive {
      return activeColor
    }
    if isHovering {
      return Color(nsColor: .tertiaryLabelColor)
    }
    return .clear
  }

  private var borderWidth: CGFloat {
    (isActive || isHovering) ? 1 : 0
  }
}

private struct InlineEditableFieldContainer<Content: View>: View {
  let isActive: Bool
  let activeColor: Color
  @ViewBuilder let content: () -> Content
  @State private var isHovering = false

  init(
    isActive: Bool = false,
    activeColor: Color = .accentColor,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.isActive = isActive
    self.activeColor = activeColor
    self.content = content
  }

  var body: some View {
    content()
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .onHover { hovering in
        isHovering = hovering
      }
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(borderColor, lineWidth: borderWidth)
      }
  }

  private var borderColor: Color {
    if isActive {
      return activeColor
    }
    if isHovering {
      return Color(nsColor: .tertiaryLabelColor)
    }
    return .clear
  }

  private var borderWidth: CGFloat {
    (isActive || isHovering) ? 1 : 0
  }
}

private struct FirstResponderAnchorView: NSViewRepresentable {
  let onResolve: (NSView) -> Void

  func makeNSView(context: Context) -> FirstResponderAnchorNSView {
    let view = FirstResponderAnchorNSView()
    onResolve(view)
    return view
  }

  func updateNSView(_ nsView: FirstResponderAnchorNSView, context: Context) {
    onResolve(nsView)
  }
}

private final class FirstResponderAnchorNSView: NSView {
  override var acceptsFirstResponder: Bool {
    true
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

private struct CustomCommandShortcutConflict: Equatable {
  let newCommandID: UserCustomCommand.ID
  let newCommandTitle: String
  let existingCommandID: UserCustomCommand.ID
  let existingCommandTitle: String
  let shortcutDisplay: String
}

private struct PendingCustomShortcut: Equatable {
  let commandID: UserCustomCommand.ID
  let shortcut: UserCustomShortcut
}

private struct ScriptEnvironmentRow: View {
  let name: String
  var value: String?
  let description: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(name)
        .monospaced()
      if let value {
        Text(value)
          .foregroundStyle(.secondary)
          .monospaced()
      }
      Text(description)
        .foregroundStyle(.tertiary)
    }
  }
}
