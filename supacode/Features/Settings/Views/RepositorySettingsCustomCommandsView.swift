import AppKit
import ComposableArchitecture
import SwiftUI

extension RepositorySettingsView {
  @ViewBuilder
  var customCommandsEditor: some View {
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
  func customCommandIconCell(_ command: UserCustomCommand) -> some View {
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
  func customCommandNameCell(_ command: UserCustomCommand) -> some View {
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
  func customCommandCell(_ command: UserCustomCommand) -> some View {
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
  func customCommandShortcutCell(_ command: UserCustomCommand) -> some View {
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

  var effectiveSelectedCommandID: UserCustomCommand.ID? {
    selectedCustomCommandID ?? editingNameCommandID ?? commandEditorCommandID ?? iconPickerCommandID
      ?? recordingCustomCommandID
  }

  var removableCommandID: UserCustomCommand.ID? {
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

  var customCommandsHeaderRow: some View {
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
  func customCommandRow(_ command: UserCustomCommand) -> some View {
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
  func customCommandHeaderCell(
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
  func customCommandRowCell<Content: View>(
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

  func selectCustomCommand(_ commandID: UserCustomCommand.ID) {
    if selectedCustomCommandID != commandID {
      selectedCustomCommandID = commandID
    }
  }

  func inlineCommandTitle(for execution: UserCustomCommandExecution) -> String {
    switch execution {
    case .shellScript:
      return "New Tab"
    case .terminalInput:
      return "In Place"
    case .split:
      return "New Split"
    }
  }

  func inlineCommandScriptPreview(for script: String) -> String {
    let firstLine =
      script
      .split(separator: "\n", omittingEmptySubsequences: false)
      .first
      .map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return firstLine.isEmpty ? "Click to set command script" : firstLine
  }

  func iconEditorPopover(
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

  func commandEditorPopover(for command: Binding<UserCustomCommand>) -> some View {
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

      customCommandSourceEditor(command: command)

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

  @ViewBuilder
  func customCommandSourceEditor(command: Binding<UserCustomCommand>) -> some View {
    let usesProfile = Binding<Bool>(
      get: { command.wrappedValue.scriptProfileID != nil },
      set: { useProfile in
        if useProfile {
          command.wrappedValue.scriptProfileID = command.wrappedValue.scriptProfileID ?? scriptProfiles.first?.id
        } else {
          command.wrappedValue.scriptProfileID = nil
        }
      }
    )

    VStack(alignment: .leading, spacing: 8) {
      Picker("Source", selection: usesProfile) {
        Text("Inline Command").tag(false)
        Text("Script Profile").tag(true)
      }
      .pickerStyle(.segmented)

      if usesProfile.wrappedValue {
        Picker(
          "Profile",
          selection: Binding<String?>(
            get: { command.wrappedValue.scriptProfileID },
            set: { command.wrappedValue.scriptProfileID = $0 }
          )
        ) {
          Text("Missing Profile").tag(String?.none)
          ForEach(scriptProfiles) { profile in
            Text(scriptProfileTitle(profile)).tag(String?.some(profile.id))
          }
        }
        .pickerStyle(.menu)

        if let profile = scriptProfiles.first(where: { $0.id == command.wrappedValue.scriptProfileID }) {
          scriptProfilePreview(profile)
        } else {
          ContentUnavailableView(
            "No Script Profile Selected",
            systemImage: "terminal",
            description: Text("Create or select a script profile in Settings → Scripts.")
          )
          .frame(height: 140)
        }
      } else {
        PlainTextEditor(
          text: command.command,
          isMonospaced: true,
          shouldFocus: true,
          placeholder: scriptPlaceholder(for: command.wrappedValue.execution)
        )
        .frame(height: 140)
      }
    }
  }

  var selectedCommandInvalidMessage: String? {
    guard let selectedCustomCommandID else {
      return nil
    }
    return invalidMessageByCommandID[selectedCustomCommandID]
  }

  func openSFSymbolsReference() {
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

  func toggleIconEditor(for commandID: UserCustomCommand.ID) {
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

  func toggleCommandEditor(for commandID: UserCustomCommand.ID) {
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

  func beginNameEditing(for commandID: UserCustomCommand.ID) {
    editingNameCommandID = commandID
    iconPickerCommandID = nil
    commandEditorCommandID = nil
    if recordingCustomCommandID == commandID {
      recordingCustomCommandID = nil
    }
    focusedNameEditorCommandID = commandID
  }

  func endNameEditing() {
    editingNameCommandID = nil
    focusedNameEditorCommandID = nil
  }

  func closePopoverAndRestoreCommandFocus(for commandID: UserCustomCommand.ID) {
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

  func focusCustomCommandsArea() {
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

  func scheduleCommandFocusRestore(for commandID: UserCustomCommand.ID) {
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

  func scriptPlaceholder(for execution: UserCustomCommandExecution) -> String {
    switch execution {
    case .shellScript:
      return "npm test && swift test"
    case .terminalInput:
      return "pnpm test --watch"
    case .split:
      return "tail -f logs/app.log"
    }
  }

  func scriptDescription(for execution: UserCustomCommandExecution) -> String {
    switch execution {
    case .shellScript:
      return "Runs in a new terminal tab."
    case .terminalInput:
      return "Sends input to the currently focused terminal."
    case .split:
      return "Runs in a new split of the focused terminal."
    }
  }

  var resolvedCustomCommandBindings: ResolvedKeybindingMap {
    let commands = store.userSettings.customCommands
    let migration = LegacyCustomCommandShortcutMigration.migrate(commands: commands)
    return KeybindingResolver.resolve(
      schema: .appResolverSchema(customCommands: commands),
      userOverrides: store.keybindingUserOverrides,
      migratedOverrides: migration.overrides
    )
  }

  func customCommandBindingID(for commandID: String) -> String {
    LegacyCustomCommandShortcutMigration.customCommandBindingID(for: commandID)
  }

  func bindingForCustomCommand(id commandID: UserCustomCommand.ID) -> Binding<UserCustomCommand>? {
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
          command.scriptProfileID = updatedCommand.scriptProfileID
          command.execution = updatedCommand.execution
          command.splitDirection = updatedCommand.splitDirection
          command.closeOnSuccess = updatedCommand.closeOnSuccess
          command.shortcut = updatedCommand.shortcut
        }
      }
    )
  }

  func syncSelectedCommandID(with commands: [UserCustomCommand]) {
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

  func clearRemovedCommandState(using commands: [UserCustomCommand]) {
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

  func addCustomCommand() {
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

  func removeSelectedCustomCommand() {
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

  func clearShortcut(for commandID: UserCustomCommand.ID) {
    invalidMessageByCommandID[commandID] = nil
    updateCustomCommand(id: commandID) { command in
      command.shortcut = nil
    }
    if recordingCustomCommandID == commandID {
      recordingCustomCommandID = nil
    }
  }

  func updateCustomCommand(
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

  func toggleRecording(for commandID: UserCustomCommand.ID) {
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

  func startRecorderMonitor() {
    stopRecorderMonitor()
    recorderMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
      guard let commandID = recordingCustomCommandID else {
        return event
      }
      handleRecorderEvent(event, commandID: commandID)
      return nil
    }
  }

  func stopRecorderMonitor() {
    if let recorderMonitor {
      NSEvent.removeMonitor(recorderMonitor)
      self.recorderMonitor = nil
    }
  }

  func handleRecorderEvent(_ event: NSEvent, commandID: UserCustomCommand.ID) {
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

  func applyRecordedShortcut(
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

  func firstConflictingCommand(
    for commandID: UserCustomCommand.ID,
    shortcut: UserCustomShortcut
  ) -> UserCustomCommand? {
    store.userSettings.customCommands.first { command in
      guard command.id != commandID else { return false }
      guard let existingShortcut = command.shortcut?.normalized() else { return false }
      return existingShortcut == shortcut
    }
  }

  func applyPendingShortcut(replacingConflict: Bool) {
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

  func clearPendingShortcutConflict() {
    pendingShortcutConflict = nil
    pendingShortcut = nil
  }

  var isShortcutConflictAlertPresented: Binding<Bool> {
    Binding(
      get: { pendingShortcutConflict != nil },
      set: { shouldPresent in
        if !shouldPresent {
          clearPendingShortcutConflict()
        }
      }
    )
  }

  var customCommandsIconColumnWidth: CGFloat { 48 }

  var customCommandsNameColumnWidth: CGFloat { 130 }

  var customCommandsShortcutColumnWidth: CGFloat { 100 }

  var customCommandsListHeight: CGFloat { 200 }
}
