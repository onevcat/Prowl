import AppKit
import SwiftUI

/// Shared inline table editor for custom commands. Hosts pass the command
/// list binding plus the command source so shortcut resolution and copy
/// stay scope-aware; the editor owns all transient selection, popover, and
/// shortcut-recording state itself.
struct CustomCommandsEditor: View {
  @Binding var commands: [UserCustomCommand]
  let source: CustomCommandSource
  let keybindingUserOverrides: KeybindingUserOverrideStore
  let globalCommands: [UserCustomCommand]
  let globalCommandEnabled: ((UserCustomCommand.ID) -> Binding<Bool>)?

  init(
    commands: Binding<[UserCustomCommand]>,
    source: CustomCommandSource,
    keybindingUserOverrides: KeybindingUserOverrideStore,
    globalCommands: [UserCustomCommand] = [],
    globalCommandEnabled: ((UserCustomCommand.ID) -> Binding<Bool>)? = nil
  ) {
    _commands = commands
    self.source = source
    self.keybindingUserOverrides = keybindingUserOverrides
    self.globalCommands = globalCommands
    self.globalCommandEnabled = globalCommandEnabled
  }

  private enum ReorderDestination: Equatable {
    case before(UserCustomCommand.ID)
    case append
  }

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
  @State private var reorderDestination: ReorderDestination?

  private let keyTokenResolver = ShortcutKeyTokenResolver()

  static let symbolPresets = [
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
    VStack(alignment: .leading, spacing: 10) {
      VStack(spacing: 0) {
        customCommandsHeaderRow
        Divider()
        ScrollView {
          LazyVStack(spacing: 4) {
            ForEach(commands) { command in
              customCommandRow(command)
                .id(command.id)
            }
            localCommandDropTarget
            if showsGlobalCommands {
              ForEach(globalCommands) { command in
                globalCustomCommandRow(command)
                  .id("global-\(command.id)")
              }
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
        .disabled(commands.isEmpty)
        .help("Remove selected command")

        Spacer(minLength: 0)

        Text("\(displayedCommandCount) commands")
          .interfaceFont(.caption)
          .foregroundStyle(.secondary)
      }
      if let invalidMessage = selectedCommandInvalidMessage {
        Text(invalidMessage)
          .interfaceFont(.caption)
          .foregroundStyle(.red)
      } else {
        Text(
          showsGlobalCommands
            ? "Global commands are managed in Settings → Commands."
            : "Click cells to edit icon, name, command, and shortcut inline."
        )
        .interfaceFont(.caption)
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
    .task {
      syncSelectedCommandID(with: commands)
    }
    .onChange(of: commands) { _, commands in
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
            .interfaceFont(.caption)
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
            .interfaceFont(.caption)
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
        .interfaceFont(.body, design: .monospaced)
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
      customCommandHeaderCell("", width: customCommandsDragColumnWidth, alignment: .center)
      customCommandHeaderCell("", width: customCommandsEnabledColumnWidth, alignment: .center)
      customCommandHeaderCell("", width: customCommandsIconColumnWidth, alignment: .center)
      customCommandHeaderCell("Name", width: customCommandsNameColumnWidth)
      customCommandHeaderCell("Command")
      customCommandHeaderCell("Shortcut", width: customCommandsShortcutColumnWidth)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .interfaceFont(.headline)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private func customCommandRow(_ command: UserCustomCommand) -> some View {
    let isSelected = selectedCustomCommandID == command.id
    HStack(spacing: 8) {
      customCommandRowCell(width: customCommandsDragColumnWidth, alignment: .center) {
        customCommandReorderHandle(command)
      }
      customCommandRowCell(width: customCommandsEnabledColumnWidth, alignment: .center) {
        customCommandEnabledCell(command)
      }
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
    .overlay(alignment: .top) {
      if reorderDestination == .before(command.id) {
        reorderInsertionIndicator
      }
    }
    .contentShape(RoundedRectangle(cornerRadius: 8))
    .accessibilityAddTraits(.isButton)
    .onTapGesture {
      selectCustomCommand(command.id)
    }
    .dropDestination(
      for: String.self,
      action: { commandIDs, _ in
        guard
          let commandID = commandIDs.first,
          commands.contains(where: { $0.id == commandID })
        else {
          return false
        }
        moveCustomCommand(commandID, before: command.id)
        reorderDestination = nil
        return true
      },
      isTargeted: { isTargeted in
        updateReorderDestination(isTargeted, destination: .before(command.id))
      }
    )
  }

  @ViewBuilder
  private func globalCustomCommandRow(_ command: UserCustomCommand) -> some View {
    HStack(spacing: 8) {
      customCommandRowCell(width: customCommandsDragColumnWidth, alignment: .center) {
        Image(systemName: "lock.fill")
          .interfaceFont(.caption2)
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
      customCommandRowCell(width: customCommandsEnabledColumnWidth, alignment: .center) {
        globalCommandEnabledCell(command)
      }
      customCommandRowCell(width: customCommandsIconColumnWidth, alignment: .center) {
        Image(systemName: command.resolvedSystemImage)
          .foregroundStyle(.secondary)
          .frame(width: 16, alignment: .center)
          .accessibilityHidden(true)
      }
      customCommandRowCell(width: customCommandsNameColumnWidth) {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 4) {
            Text(command.resolvedTitle)
              .lineLimit(1)
            Text("Global")
              .interfaceFont(.caption2)
              .foregroundStyle(.secondary)
          }
          if !command.isEnabled {
            Text("Disabled globally")
              .interfaceFont(.caption2)
              .foregroundStyle(.secondary)
          }
        }
      }
      customCommandRowCell {
        VStack(alignment: .leading, spacing: 2) {
          Text(inlineCommandTitle(for: command.execution))
            .interfaceFont(.caption)
            .foregroundStyle(.secondary)
          Text(inlineCommandScriptPreview(for: command.command))
            .lineLimit(1)
        }
      }
      customCommandRowCell(width: customCommandsShortcutColumnWidth) {
        let binding = resolvedCustomCommandBindings.keybinding(
          for: customCommandBindingID(for: command.id, source: .global)
        )
        Text(binding?.display ?? "Unassigned")
          .interfaceFont(.body, design: .monospaced)
          .foregroundStyle(binding == nil ? .secondary : .primary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 2)
    .opacity(command.isEnabled ? 1 : 0.6)
    .help("Global command. Edit it in Settings → Commands.")
  }

  @ViewBuilder
  private func customCommandReorderHandle(_ command: UserCustomCommand) -> some View {
    Image(systemName: "line.3.horizontal")
      .foregroundStyle(.tertiary)
      .frame(width: 16, height: 16)
      .contentShape(Rectangle())
      .accessibilityLabel("Drag \(command.resolvedTitle) to reorder")
      .help("Drag to reorder command")
      .draggable(command.id)
  }

  @ViewBuilder
  private func customCommandEnabledCell(_ command: UserCustomCommand) -> some View {
    if let binding = bindingForCustomCommand(id: command.id) {
      Toggle("Enable \(command.resolvedTitle)", isOn: binding.isEnabled)
        .labelsHidden()
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .help("Enable \(command.resolvedTitle)")
    }
  }

  @ViewBuilder
  private func globalCommandEnabledCell(_ command: UserCustomCommand) -> some View {
    if let binding = globalCommandEnabled?(command.id) {
      Toggle("Enable \(command.resolvedTitle) in this repository", isOn: binding)
        .labelsHidden()
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .help("Enable \(command.resolvedTitle) in this repository")
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
        .interfaceFont(.headline)
      Text("Pick from common symbols or enter any SF Symbol name available in your system.")
        .interfaceFont(.caption)
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
        .interfaceFont(.headline)
      Text(commandEditorDescription)
        .interfaceFont(.caption)
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
        .interfaceFont(.caption)
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

  private var commandEditorDescription: String {
    switch source {
    case .repository:
      return "Choose where this command runs and edit the script used by this repository custom command."
    case .global:
      return "Choose where this command runs and edit the script used by this global custom command."
    }
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
      guard commands.contains(where: { $0.id == commandID }) else {
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
    let effectiveCommands =
      commands.map { EffectiveCustomCommand(source: source, command: $0) }
      + globalCommands.map { EffectiveCustomCommand(source: .global, command: $0) }
    let migration = LegacyCustomCommandShortcutMigration.migrate(commands: effectiveCommands)
    return KeybindingResolver.resolve(
      schema: .appResolverSchema(effectiveCustomCommands: effectiveCommands),
      userOverrides: keybindingUserOverrides,
      migratedOverrides: migration.overrides
    )
  }

  private func customCommandBindingID(
    for commandID: String,
    source: CustomCommandSource? = nil
  ) -> String {
    LegacyCustomCommandShortcutMigration.customCommandBindingID(for: commandID, source: source ?? self.source)
  }

  private func bindingForCustomCommand(id commandID: UserCustomCommand.ID) -> Binding<UserCustomCommand>? {
    guard commands.contains(where: { $0.id == commandID }) else {
      return nil
    }

    return Binding(
      get: {
        commands.first(where: { $0.id == commandID })
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
          command.isEnabled = updatedCommand.isEnabled
        }
      }
    )
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
    let next = UserCustomCommand.normalizedCommands(commands + [.default(index: commands.count)])
    commands = next
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

    var updatedCommands = commands
    let removalIndex: Int?
    if let index = updatedCommands.firstIndex(where: { $0.id == selectedCommandID }) {
      removalIndex = index
      updatedCommands.remove(at: index)
    } else if !updatedCommands.isEmpty {
      removalIndex = updatedCommands.count - 1
      updatedCommands.removeLast()
    } else {
      removalIndex = nil
    }

    guard let removalIndex else {
      return
    }

    let normalizedCommands = UserCustomCommand.normalizedCommands(updatedCommands)
    commands = normalizedCommands

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
    var updatedCommands = commands
    guard let index = updatedCommands.firstIndex(where: { $0.id == id }) else {
      return
    }

    update(&updatedCommands[index])
    commands = UserCustomCommand.normalizedCommands(updatedCommands)
  }

  private func moveCustomCommand(
    _ commandID: UserCustomCommand.ID,
    before destinationID: UserCustomCommand.ID? = nil
  ) {
    guard commandID != destinationID else {
      return
    }
    var updatedCommands = commands
    guard let sourceIndex = updatedCommands.firstIndex(where: { $0.id == commandID }) else {
      return
    }
    let command = updatedCommands.remove(at: sourceIndex)
    let destinationIndex =
      destinationID.flatMap { destinationID in
        updatedCommands.firstIndex(where: { $0.id == destinationID })
      } ?? updatedCommands.endIndex
    updatedCommands.insert(command, at: destinationIndex)
    commands = UserCustomCommand.normalizedCommands(updatedCommands)
    selectCustomCommand(commandID)
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
      commands.first(where: { $0.id == commandID })?.resolvedTitle ?? "Command"

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
    commands.first { command in
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

  private var showsGlobalCommands: Bool {
    source == .repository && !globalCommands.isEmpty
  }

  private var displayedCommandCount: Int {
    commands.count + (showsGlobalCommands ? globalCommands.count : 0)
  }

  private var localCommandDropTarget: some View {
    Color.clear
      .frame(height: 12)
      .overlay {
        if reorderDestination == .append {
          reorderInsertionIndicator
        }
      }
      .contentShape(Rectangle())
      .dropDestination(
        for: String.self,
        action: { commandIDs, _ in
          guard
            let commandID = commandIDs.first,
            commands.contains(where: { $0.id == commandID })
          else {
            return false
          }
          moveCustomCommand(commandID)
          reorderDestination = nil
          return true
        },
        isTargeted: { isTargeted in
          updateReorderDestination(isTargeted, destination: .append)
        }
      )
  }

  private var reorderInsertionIndicator: some View {
    Rectangle()
      .fill(Color.accentColor)
      .frame(height: 2)
      .padding(.horizontal, 4)
      .accessibilityHidden(true)
  }

  private func updateReorderDestination(_ isTargeted: Bool, destination: ReorderDestination) {
    if isTargeted {
      reorderDestination = destination
    } else if reorderDestination == destination {
      reorderDestination = nil
    }
  }

  private var customCommandsDragColumnWidth: CGFloat { 24 }

  private var customCommandsEnabledColumnWidth: CGFloat { 24 }

  private var customCommandsIconColumnWidth: CGFloat { 32 }

  private var customCommandsNameColumnWidth: CGFloat { 130 }

  private var customCommandsShortcutColumnWidth: CGFloat { 100 }

  private var customCommandsListHeight: CGFloat { 200 }
}
