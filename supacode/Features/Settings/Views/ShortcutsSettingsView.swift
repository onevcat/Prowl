import AppKit
import ComposableArchitecture
import SwiftUI

struct ShortcutsSettingsView: View {
  private enum ShortcutTableLayout {
    static let commandColumnMinWidth: CGFloat = 180
    static let statusChipWidth: CGFloat = 108
    static let statusChipHeight: CGFloat = 24
    static let statusColumnWidth: CGFloat = statusChipWidth
    static let shortcutColumnMinWidth: CGFloat = 120
    static let shortcutColumnIdealWidth: CGFloat = 220
    static let actionColumnWidth: CGFloat = 16
  }

  @Bindable var store: StoreOf<SettingsFeature>
  let effectiveKeybindings: ResolvedKeybindingMap
  let customCommands: [EffectiveCustomCommand]
  let islandHotKeyRegistrationFailure: Keybinding?

  @State private var searchText = ""
  @State private var recordingCommandID: String?
  @State private var recorderMonitor: Any?
  @State private var invalidMessageByCommandID: [String: String] = [:]
  @State private var pendingConflict: ShortcutConflict?
  @State private var pendingResetConflict: ResetConflict?
  @State private var pendingOverride: PendingOverride?
  @State private var focusedCommandID: String?
  @State private var hoveredRecorderCommandID: String?
  private let keyTokenResolver = ShortcutKeyTokenResolver()

  private var schema: KeybindingSchemaDocument {
    .appDefaultsV1
  }

  private var editableCommands: [KeybindingCommandSchema] {
    schema.commands.filter(\.allowUserOverride)
  }

  private var resolvedBindings: ResolvedKeybindingMap {
    KeybindingResolver.resolve(
      schema: .appResolverSchema(),
      userOverrides: store.keybindingUserOverrides
    )
  }

  private var visibleGroups: [ShortcutGroup] {
    ShortcutGroup.allCases.filter { !commands(for: $0).isEmpty }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        TextField("Search actions or shortcuts", text: $searchText)
          .textFieldStyle(.roundedBorder)

        Button("Reset All") {
          resetAllOverrides()
        }
        .disabled(store.keybindingUserOverrides.overrides.isEmpty)
      }
      .padding(.horizontal, 16)

      HStack(spacing: 12) {
        Text("Command")
          .frame(minWidth: ShortcutTableLayout.commandColumnMinWidth, maxWidth: .infinity, alignment: .leading)
          .layoutPriority(1)
        Text("Status")
          .frame(width: ShortcutTableLayout.statusColumnWidth, alignment: .leading)
        Text("Shortcut")
          .frame(
            minWidth: ShortcutTableLayout.shortcutColumnMinWidth,
            idealWidth: ShortcutTableLayout.shortcutColumnIdealWidth,
            maxWidth: ShortcutTableLayout.shortcutColumnIdealWidth,
            alignment: .leading
          )
        Color.clear
          .frame(width: ShortcutTableLayout.actionColumnWidth, height: 1)
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 16)

      List {
        ForEach(visibleGroups) { group in
          Section {
            ForEach(commands(for: group), id: \.id) { command in
              row(for: command)
                .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                .listRowBackground(rowBackground(for: command.id))
            }
          } header: {
            HStack(alignment: .center, spacing: 8) {
              Text(group.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
              Spacer(minLength: 0)
              if hasOverrides(in: group) {
                Button("Reset Section") {
                  resetOverrides(in: group)
                }
                .buttonStyle(.link)
                .font(.caption)
              }
            }
          }
        }

        if visibleGroups.isEmpty {
          Text("No shortcuts found.")
            .foregroundStyle(.secondary)
        }
      }
      .listStyle(.inset)
      .environment(\.defaultMinListRowHeight, 32)
    }
    .onChange(of: recordingCommandID) { _, commandID in
      if commandID == nil {
        stopRecorderMonitor()
      } else {
        startRecorderMonitor()
      }
    }
    .onDisappear {
      stopRecorderMonitor()
    }
    .task(id: store.shortcutNavigationTargetCommandID) {
      guard let commandID = store.shortcutNavigationTargetCommandID else { return }
      focusCommand(commandID)
      store.send(.shortcutNavigationTargetConsumed)
    }
    .alert(
      "Shortcut Conflict",
      isPresented: isConflictAlertPresented,
      presenting: pendingConflict
    ) { conflict in
      Button("Replace", role: .destructive) {
        applyPendingOverride(replacingConflict: true)
      }
      Button("Show Conflict") {
        focusConflictCommand(conflict)
      }
      Button("Cancel", role: .cancel) {
        clearPendingConflict()
      }
    } message: { conflict in
      Text(
        "“\(conflict.newCommandTitle)” and “\(conflict.existingCommandTitle)” both use \(conflict.binding.display)."
          + "\n\nChoose Replace to keep the new binding and disable the conflicting one."
      )
    }
    .alert(
      "Reset Conflict",
      isPresented: isResetConflictAlertPresented,
      presenting: pendingResetConflict
    ) { _ in
      Button("Reset Related", role: .destructive) {
        applyPendingResetConflict()
      }
      Button("Cancel", role: .cancel) {
        clearPendingResetConflict()
      }
    } message: { conflict in
      Text(resetConflictMessage(for: conflict))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private func row(for command: KeybindingCommandSchema) -> some View {
    let isRecording = recordingCommandID == command.id
    let resolvedBinding = resolvedBindings.binding(for: command.id)?.binding
    let source = resolvedBindings.binding(for: command.id)?.source ?? .appDefault
    let hasOverride = store.keybindingUserOverrides.overrides[command.id] != nil
    let isHoveringRecorder = hoveredRecorderCommandID == command.id
    let availabilityMessage = availabilityMessage(
      commandID: command.id,
      resolvedBinding: resolvedBinding
    )

    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .center, spacing: 12) {
        Text(command.title)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(minWidth: ShortcutTableLayout.commandColumnMinWidth, maxWidth: .infinity, alignment: .leading)
          .layoutPriority(1)

        sourceChip(
          source,
          resolvedBinding: resolvedBinding,
          isUnavailable: availabilityMessage != nil
        )
        .frame(width: ShortcutTableLayout.statusColumnWidth, alignment: .leading)

        shortcutRecorderField(
          commandID: command.id,
          commandTitle: command.title,
          resolvedBinding: resolvedBinding,
          isRecording: isRecording,
          isHovering: isHoveringRecorder
        )
        .frame(
          minWidth: ShortcutTableLayout.shortcutColumnMinWidth,
          idealWidth: ShortcutTableLayout.shortcutColumnIdealWidth,
          maxWidth: ShortcutTableLayout.shortcutColumnIdealWidth,
          alignment: .leading
        )

        if hasOverride {
          Button {
            requestResetOverride(for: command.id)
          } label: {
            Image(systemName: "arrow.counterclockwise")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
          }
          .buttonStyle(.plain)
          .help("Reset to default")
          .accessibilityLabel("Reset shortcut to default")
          .frame(width: ShortcutTableLayout.actionColumnWidth, height: ShortcutTableLayout.actionColumnWidth)
        } else {
          Color.clear
            .frame(width: ShortcutTableLayout.actionColumnWidth, height: ShortcutTableLayout.actionColumnWidth)
        }
      }

      if isRecording {
        HStack(spacing: 8) {
          Text("Press a key with modifiers (⌘ ⇧ ⌥ ⌃).")
          Spacer(minLength: 0)
          Button("Clear") {
            clearShortcut(for: command.id)
          }
          .buttonStyle(.link)
          .help("Clear shortcut")
          Button("Cancel") {
            stopRecording()
          }
          .buttonStyle(.link)
          .help("Cancel recording")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      if let invalid = invalidMessageByCommandID[command.id] {
        Text(invalid)
          .font(.caption)
          .foregroundStyle(.red)
      } else if let availabilityMessage {
        Text(availabilityMessage)
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .padding(.vertical, 2)
  }

  private func rowBackground(for commandID: String) -> some View {
    let isFocused = focusedCommandID == commandID
    return RoundedRectangle(cornerRadius: 6)
      .fill(isFocused ? Color.orange.opacity(0.15) : .clear)
  }

  private func shortcutRecorderField(
    commandID: String,
    commandTitle: String,
    resolvedBinding: Keybinding?,
    isRecording: Bool,
    isHovering: Bool
  ) -> some View {
    Button {
      toggleRecording(for: commandID)
    } label: {
      HStack(spacing: 6) {
        if isRecording {
          Image(systemName: "record.circle.fill")
            .font(.caption)
            .foregroundStyle(Color.accentColor)
            .accessibilityHidden(true)
        }

        Text(shortcutRecorderTitle(resolvedBinding: resolvedBinding, isRecording: isRecording))
          .font(.body.monospaced())
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
          .foregroundStyle(shortcutRecorderForegroundColor(resolvedBinding: resolvedBinding, isRecording: isRecording))
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(Color(nsColor: .textBackgroundColor))
      )
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .strokeBorder(shortcutRecorderBorderColor(isRecording: isRecording, isHovering: isHovering), lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Shortcut for \(commandTitle)")
    .accessibilityValue(isRecording ? "Recording" : (resolvedBinding?.display ?? "No shortcut assigned"))
    .onHover { hovering in
      if hovering {
        hoveredRecorderCommandID = commandID
      } else if hoveredRecorderCommandID == commandID {
        hoveredRecorderCommandID = nil
      }
    }
    .help(isRecording ? "Recording shortcut. Press Esc to cancel." : "Click to record a shortcut.")
  }

  private func shortcutRecorderTitle(resolvedBinding: Keybinding?, isRecording: Bool) -> String {
    if isRecording {
      return "Recording…"
    }
    return resolvedBinding?.display ?? ""
  }

  private func shortcutRecorderForegroundColor(resolvedBinding: Keybinding?, isRecording: Bool) -> Color {
    if isRecording {
      return .accentColor
    }
    return resolvedBinding == nil ? .secondary : .primary
  }

  private func shortcutRecorderBorderColor(isRecording: Bool, isHovering: Bool) -> Color {
    if isRecording {
      return .accentColor
    }
    if isHovering {
      return Color(nsColor: .tertiaryLabelColor)
    }
    return Color(nsColor: .separatorColor)
  }

  private func sourceChip(
    _ source: KeybindingSource,
    resolvedBinding: Keybinding?,
    isUnavailable: Bool
  ) -> some View {
    if isUnavailable {
      return AnyView(
        Text("Unavailable")
          .font(.caption2.monospaced())
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .frame(width: ShortcutTableLayout.statusChipWidth, height: ShortcutTableLayout.statusChipHeight)
          .foregroundStyle(AnyShapeStyle(Color.red))
          .background(
            Capsule()
              .fill(Color.red.opacity(0.2))
          )
          .overlay(
            Capsule()
              .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
          )
      )
    }

    let isDefault = source == .appDefault
    guard !isDefault else {
      return AnyView(
        Color.clear
          .frame(width: ShortcutTableLayout.statusChipWidth, height: ShortcutTableLayout.statusChipHeight)
          .accessibilityHidden(true)
      )
    }

    let title = resolvedBinding == nil ? "Disabled" : "Defined"
    return AnyView(
      Text(title)
        .font(.caption2.monospaced())
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(width: ShortcutTableLayout.statusChipWidth, height: ShortcutTableLayout.statusChipHeight)
        .foregroundStyle(AnyShapeStyle(Color.accentColor))
        .background(
          Capsule()
            .fill(Color.accentColor.opacity(0.2))
        )
        .overlay(
          Capsule()
            .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
    )
  }

  private func commands(for group: ShortcutGroup) -> [KeybindingCommandSchema] {
    editableCommands
      .filter { ShortcutGroup.resolve(for: $0.id) == group }
      .filter(matchesSearch)
      .sorted {
        commandSortKey(for: $0, in: group) < commandSortKey(for: $1, in: group)
      }
  }

  private func commandSortKey(
    for command: KeybindingCommandSchema,
    in group: ShortcutGroup
  ) -> CommandSortKey {
    guard group == .terminal else {
      return CommandSortKey(category: 0, order: 0, title: command.title)
    }

    if let order = terminalTabOrder(for: command.id) {
      return CommandSortKey(category: 0, order: order, title: command.title)
    }

    if let order = terminalPaneOrder(for: command.id) {
      return CommandSortKey(category: 1, order: order, title: command.title)
    }

    return CommandSortKey(category: 2, order: Int.max, title: command.title)
  }

  private func terminalTabOrder(for commandID: String) -> Int? {
    switch commandID {
    case AppShortcuts.CommandID.selectPreviousTerminalTab:
      return 0
    case AppShortcuts.CommandID.selectNextTerminalTab:
      return 1
    case AppShortcuts.CommandID.selectTerminalTab1:
      return 2
    case AppShortcuts.CommandID.selectTerminalTab2:
      return 3
    case AppShortcuts.CommandID.selectTerminalTab3:
      return 4
    case AppShortcuts.CommandID.selectTerminalTab4:
      return 5
    case AppShortcuts.CommandID.selectTerminalTab5:
      return 6
    case AppShortcuts.CommandID.selectTerminalTab6:
      return 7
    case AppShortcuts.CommandID.selectTerminalTab7:
      return 8
    case AppShortcuts.CommandID.selectTerminalTab8:
      return 9
    case AppShortcuts.CommandID.selectTerminalTab9:
      return 10
    default:
      return nil
    }
  }

  private func terminalPaneOrder(for commandID: String) -> Int? {
    switch commandID {
    case AppShortcuts.CommandID.selectPreviousTerminalPane:
      return 0
    case AppShortcuts.CommandID.selectNextTerminalPane:
      return 1
    case AppShortcuts.CommandID.selectTerminalPaneUp:
      return 2
    case AppShortcuts.CommandID.selectTerminalPaneDown:
      return 3
    case AppShortcuts.CommandID.selectTerminalPaneLeft:
      return 4
    case AppShortcuts.CommandID.selectTerminalPaneRight:
      return 5
    case AppShortcuts.CommandID.toggleSplitZoom:
      return 6
    default:
      return nil
    }
  }

  private func matchesSearch(_ command: KeybindingCommandSchema) -> Bool {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return true }

    if command.title.localizedCaseInsensitiveContains(query) {
      return true
    }
    if command.id.localizedCaseInsensitiveContains(query) {
      return true
    }
    if let display = resolvedBindings.binding(for: command.id)?.binding?.display,
      display.localizedCaseInsensitiveContains(query)
    {
      return true
    }
    return false
  }

  private func hasOverrides(in group: ShortcutGroup) -> Bool {
    let commandIDs = Set(commands(for: group).map(\.id))
    return store.keybindingUserOverrides.overrides.keys.contains { commandIDs.contains($0) }
  }

  private func toggleRecording(for commandID: String) {
    invalidMessageByCommandID[commandID] = nil
    focusedCommandID = nil
    if recordingCommandID == commandID {
      recordingCommandID = nil
      return
    }
    recordingCommandID = commandID
  }

  private func clearShortcut(for commandID: String) {
    store.send(.clearShortcutButtonTapped(commandID: commandID))
    invalidMessageByCommandID[commandID] = nil
    focusedCommandID = nil
    stopRecording()
  }

  private func stopRecording() {
    recordingCommandID = nil
  }

  private func startRecorderMonitor() {
    stopRecorderMonitor()
    recorderMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
      guard let commandID = recordingCommandID else {
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

  private func handleRecorderEvent(_ event: NSEvent, commandID: String) {
    if event.keyCode == 53 {  // Escape
      stopRecording()
      return
    }

    guard let keyToken = keyToken(for: event) else {
      invalidMessageByCommandID[commandID] = "Unsupported key. Use letters, numbers, punctuation, Return, or arrows."
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
    applyRecordedBinding(binding, to: commandID)
  }

  private func keyToken(for event: NSEvent) -> String? {
    keyTokenResolver.resolveKeyToken(
      keyCode: event.keyCode,
      charactersIgnoringModifiers: event.charactersIgnoringModifiers
    )
  }

  private func applyRecordedBinding(_ binding: Keybinding, to commandID: String) {
    invalidMessageByCommandID[commandID] = nil
    focusedCommandID = nil

    guard let command = editableCommands.first(where: { $0.id == commandID }) else {
      stopRecording()
      return
    }

    if let conflictingCommand = activeCustomCommandConflict(for: binding) {
      invalidMessageByCommandID[commandID] =
        "“\(binding.display)” is used by the \(conflictingCommand.source.displayTitle.lowercased()) "
        + "custom command “\(conflictingCommand.command.resolvedTitle)”. Choose another shortcut."
      stopRecording()
      return
    }

    let conflict = firstConflict(
      commandID: commandID,
      binding: binding,
      policy: command.conflictPolicy
    )

    if let conflict {
      pendingConflict = conflict
      pendingOverride = PendingOverride(commandID: commandID, binding: binding)
      stopRecording()
      return
    }

    saveOverride(
      commandID: commandID,
      binding: binding,
      replaceConflictCommandID: nil
    )
    stopRecording()
  }

  private func availabilityMessage(
    commandID: String,
    resolvedBinding: Keybinding?
  ) -> String? {
    guard let resolvedBinding else { return nil }
    if let command = activeCustomCommandConflict(for: resolvedBinding) {
      return
        "Unavailable while the \(command.source.displayTitle.lowercased()) custom command "
        + "“\(command.command.resolvedTitle)” uses \(resolvedBinding.display). Custom Commands take precedence."
    }
    if commandID == AppShortcuts.CommandID.toggleAgentIsland,
      islandHotKeyRegistrationFailure == resolvedBinding
    {
      return "macOS could not register this shortcut globally. Choose another shortcut."
    }
    return nil
  }

  private func activeCustomCommandConflict(
    for binding: Keybinding
  ) -> EffectiveCustomCommand? {
    ShortcutConflictDetector.firstActiveCustomCommandConflict(
      binding: binding,
      customCommands: customCommands,
      resolvedKeybindings: effectiveKeybindings
    )
  }

  private func firstConflict(
    commandID: String,
    binding: Keybinding,
    policy: KeybindingConflictPolicy
  ) -> ShortcutConflict? {
    guard
      let existingCommandID = ShortcutConflictDetector.firstConflictCommandID(
        commandID: commandID,
        binding: binding,
        policy: policy,
        schema: .appResolverSchema(),
        userOverrides: store.keybindingUserOverrides
      )
    else {
      return nil
    }

    guard let existingCommand = editableCommands.first(where: { $0.id == existingCommandID }) else {
      return nil
    }

    let newTitle = editableCommands.first(where: { $0.id == commandID })?.title ?? commandID
    return ShortcutConflict(
      newCommandID: commandID,
      newCommandTitle: newTitle,
      existingCommandID: existingCommand.id,
      existingCommandTitle: existingCommand.title,
      binding: binding
    )
  }

  private func applyPendingOverride(replacingConflict: Bool) {
    guard let pendingOverride else {
      clearPendingConflict()
      return
    }

    let conflictCommandID = replacingConflict ? pendingConflict?.existingCommandID : nil
    saveOverride(
      commandID: pendingOverride.commandID,
      binding: pendingOverride.binding,
      replaceConflictCommandID: conflictCommandID
    )
    clearPendingConflict()
  }

  private func clearPendingConflict() {
    pendingConflict = nil
    pendingOverride = nil
  }

  private func focusConflictCommand(_ conflict: ShortcutConflict) {
    clearPendingConflict()
    store.send(.showShortcutButtonTapped(commandID: conflict.existingCommandID))
  }

  private func focusCommand(_ commandID: String) {
    guard let command = editableCommands.first(where: { $0.id == commandID }) else { return }
    focusedCommandID = commandID
    searchText = command.title
  }

  private func saveOverride(
    commandID: String,
    binding: Keybinding,
    replaceConflictCommandID: String?
  ) {
    var overrides = store.keybindingUserOverrides
    overrides.overrides[commandID] = KeybindingUserOverride(binding: binding)

    if let replaceConflictCommandID {
      overrides.overrides[replaceConflictCommandID] = KeybindingUserOverride(binding: nil, isEnabled: false)
    }

    $store.keybindingUserOverrides.wrappedValue = overrides
  }

  private func requestResetOverride(for commandID: String) {
    let plan = ShortcutResetPlanner.makePlan(
      commandID: commandID,
      schema: .appResolverSchema(),
      userOverrides: store.keybindingUserOverrides
    )

    guard !plan.conflictingCommandIDs.isEmpty, let restoredBinding = plan.restoredBinding else {
      applyResetOverrides(for: plan.commandIDsToReset)
      return
    }

    let occupiedCommandTitle = commandTitle(for: plan.conflictingCommandIDs[0])
    let cascadingTitles = plan.commandIDsToReset.dropFirst().map(commandTitle(for:))
    pendingResetConflict = ResetConflict(
      commandID: commandID,
      commandTitle: commandTitle(for: commandID),
      restoredBinding: restoredBinding,
      occupiedCommandTitle: occupiedCommandTitle,
      cascadingTitles: cascadingTitles,
      commandIDsToReset: plan.commandIDsToReset
    )
  }

  private func applyResetOverrides(for commandIDs: [String]) {
    var overrides = store.keybindingUserOverrides
    for commandID in commandIDs {
      overrides.overrides.removeValue(forKey: commandID)
      invalidMessageByCommandID.removeValue(forKey: commandID)
    }
    $store.keybindingUserOverrides.wrappedValue = overrides

    if let recordingCommandID, commandIDs.contains(recordingCommandID) {
      stopRecording()
    }
    if let focusedCommandID, commandIDs.contains(focusedCommandID) {
      self.focusedCommandID = nil
    }
    clearPendingResetConflict()
  }

  private func applyPendingResetConflict() {
    guard let pendingResetConflict else {
      return
    }
    applyResetOverrides(for: pendingResetConflict.commandIDsToReset)
  }

  private func clearPendingResetConflict() {
    pendingResetConflict = nil
  }

  private func resetConflictMessage(for conflict: ResetConflict) -> String {
    var message =
      "Resetting “\(conflict.commandTitle)” restores \(conflict.restoredBinding.display), "
      + "which is currently used by “\(conflict.occupiedCommandTitle)”."

    if !conflict.cascadingTitles.isEmpty {
      let cascadingList = conflict.cascadingTitles.joined(separator: " → ")
      message += "\n\nReset Related will cascade reset: \(cascadingList)."
    }

    return message + "\n\nChoose Reset Related to continue, or Cancel."
  }

  private func commandTitle(for commandID: String) -> String {
    editableCommands.first(where: { $0.id == commandID })?.title ?? commandID
  }

  private func resetOverrides(in group: ShortcutGroup) {
    let overriddenCommandIDs = commands(for: group)
      .map(\.id)
      .filter { store.keybindingUserOverrides.overrides[$0] != nil }
    guard !overriddenCommandIDs.isEmpty else { return }

    let plan = ShortcutResetPlanner.makePlan(
      commandIDs: overriddenCommandIDs,
      schema: .appResolverSchema(),
      userOverrides: store.keybindingUserOverrides
    )
    applyResetOverrides(for: plan.commandIDsToReset)
  }

  private func resetAllOverrides() {
    $store.keybindingUserOverrides.wrappedValue = .empty
    invalidMessageByCommandID.removeAll()
    stopRecording()
  }

  private var isConflictAlertPresented: Binding<Bool> {
    Binding(
      get: { pendingConflict != nil },
      set: { shouldPresent in
        if !shouldPresent {
          clearPendingConflict()
        }
      }
    )
  }

  private var isResetConflictAlertPresented: Binding<Bool> {
    Binding(
      get: { pendingResetConflict != nil },
      set: { shouldPresent in
        if !shouldPresent {
          clearPendingResetConflict()
        }
      }
    )
  }
}

private struct CommandSortKey: Comparable {
  let category: Int
  let order: Int
  let title: String

  static func < (lhs: CommandSortKey, rhs: CommandSortKey) -> Bool {
    if lhs.category != rhs.category {
      return lhs.category < rhs.category
    }
    if lhs.order != rhs.order {
      return lhs.order < rhs.order
    }
    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
  }
}

struct ShortcutResetPlan: Equatable {
  let commandIDsToReset: [String]
  let restoredBinding: Keybinding?
  let conflictingCommandIDs: [String]
}

enum ShortcutResetPlanner {
  static func makePlan(
    commandID: String,
    schema: KeybindingSchemaDocument,
    userOverrides: KeybindingUserOverrideStore
  ) -> ShortcutResetPlan {
    let restoredResolved = resolvedMap(
      byResetting: commandID,
      in: schema,
      userOverrides: userOverrides
    )
    let restoredBinding = restoredResolved.binding(for: commandID)?.binding

    let cascadePlan = makePlan(
      commandIDs: [commandID],
      schema: schema,
      userOverrides: userOverrides
    )

    return ShortcutResetPlan(
      commandIDsToReset: cascadePlan.commandIDsToReset,
      restoredBinding: restoredBinding,
      conflictingCommandIDs: cascadePlan.conflictingCommandIDs
    )
  }

  static func makePlan(
    commandIDs: [String],
    schema: KeybindingSchemaDocument,
    userOverrides: KeybindingUserOverrideStore
  ) -> ShortcutResetPlan {
    let editableCommandIDs = Set(schema.commands.filter(\.allowUserOverride).map(\.id))
    let seedCommandIDs = commandIDs.filter { editableCommandIDs.contains($0) }
    guard !seedCommandIDs.isEmpty else {
      return ShortcutResetPlan(
        commandIDsToReset: commandIDs,
        restoredBinding: nil,
        conflictingCommandIDs: []
      )
    }

    let seedCommandIDSet = Set(seedCommandIDs)
    var tentative = userOverrides
    var pending = seedCommandIDs
    var processed: Set<String> = []
    var commandIDsToReset: [String] = []
    var initialConflicts: Set<String> = []
    var index = 0

    while index < pending.count {
      let currentCommandID = pending[index]
      index += 1
      guard editableCommandIDs.contains(currentCommandID) else { continue }
      guard processed.insert(currentCommandID).inserted else { continue }

      tentative.overrides.removeValue(forKey: currentCommandID)
      commandIDsToReset.append(currentCommandID)

      let resolved = KeybindingResolver.resolve(
        schema: schema,
        userOverrides: tentative
      )

      let conflicts = conflictingCommandIDs(
        for: currentCommandID,
        in: resolved,
        editableCommandIDs: editableCommandIDs,
        excluding: processed
      )
      if seedCommandIDSet.contains(currentCommandID) {
        initialConflicts.formUnion(conflicts)
      }
      pending.append(contentsOf: conflicts)
    }

    if commandIDsToReset.isEmpty {
      commandIDsToReset = seedCommandIDs
    }

    return ShortcutResetPlan(
      commandIDsToReset: commandIDsToReset,
      restoredBinding: nil,
      conflictingCommandIDs: initialConflicts.sorted()
    )
  }

  private static func resolvedMap(
    byResetting commandID: String,
    in schema: KeybindingSchemaDocument,
    userOverrides: KeybindingUserOverrideStore
  ) -> ResolvedKeybindingMap {
    var tentative = userOverrides
    tentative.overrides.removeValue(forKey: commandID)
    return KeybindingResolver.resolve(
      schema: schema,
      userOverrides: tentative
    )
  }

  private static func conflictingCommandIDs(
    for commandID: String,
    in resolved: ResolvedKeybindingMap,
    editableCommandIDs: Set<String>,
    excluding excludedCommandIDs: Set<String>
  ) -> [String] {
    guard let currentBinding = resolved.binding(for: commandID)?.binding else {
      return []
    }

    return
      editableCommandIDs
      .filter {
        $0 != commandID
          && !excludedCommandIDs.contains($0)
          && resolved.binding(for: $0)?.binding == currentBinding
      }
      .sorted()
  }
}

private struct ShortcutConflict: Equatable {
  let newCommandID: String
  let newCommandTitle: String
  let existingCommandID: String
  let existingCommandTitle: String
  let binding: Keybinding
}

private struct ResetConflict: Equatable {
  let commandID: String
  let commandTitle: String
  let restoredBinding: Keybinding
  let occupiedCommandTitle: String
  let cascadingTitles: [String]
  let commandIDsToReset: [String]
}

private struct PendingOverride: Equatable {
  let commandID: String
  let binding: Keybinding
}

private enum ShortcutGroup: String, CaseIterable, Identifiable {
  case general
  case navigation
  case terminal
  case scripts

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
    case .general:
      "General"
    case .navigation:
      "Navigation"
    case .terminal:
      "Terminal Tabs & Panes"
    case .scripts:
      "Scripts & Panels"
    }
  }

  static func resolve(for commandID: String) -> ShortcutGroup {
    switch commandID {
    case AppShortcuts.CommandID.selectNextWorktree,
      AppShortcuts.CommandID.selectPreviousWorktree,
      AppShortcuts.CommandID.worktreeHistoryBack,
      AppShortcuts.CommandID.worktreeHistoryForward,
      AppShortcuts.CommandID.renameBranch,
      AppShortcuts.CommandID.selectWorktree1,
      AppShortcuts.CommandID.selectWorktree2,
      AppShortcuts.CommandID.selectWorktree3,
      AppShortcuts.CommandID.selectWorktree4,
      AppShortcuts.CommandID.selectWorktree5,
      AppShortcuts.CommandID.selectWorktree6,
      AppShortcuts.CommandID.selectWorktree7,
      AppShortcuts.CommandID.selectWorktree8,
      AppShortcuts.CommandID.selectWorktree9:
      return .navigation

    case AppShortcuts.CommandID.runScript,
      AppShortcuts.CommandID.stopScript,
      AppShortcuts.CommandID.showDiff,
      AppShortcuts.CommandID.toggleCanvas,
      AppShortcuts.CommandID.toggleShelf,
      AppShortcuts.CommandID.selectNextShelfBook,
      AppShortcuts.CommandID.selectPreviousShelfBook,
      AppShortcuts.CommandID.selectShelfBook1,
      AppShortcuts.CommandID.selectShelfBook2,
      AppShortcuts.CommandID.selectShelfBook3,
      AppShortcuts.CommandID.selectShelfBook4,
      AppShortcuts.CommandID.selectShelfBook5,
      AppShortcuts.CommandID.selectShelfBook6,
      AppShortcuts.CommandID.selectShelfBook7,
      AppShortcuts.CommandID.selectShelfBook8,
      AppShortcuts.CommandID.selectShelfBook9,
      AppShortcuts.CommandID.selectAllCanvasCards,
      AppShortcuts.CommandID.arrangeCanvasCards,
      AppShortcuts.CommandID.organizeCanvasCards,
      AppShortcuts.CommandID.tileCanvasCards,
      AppShortcuts.CommandID.archivedWorktrees:
      return .scripts

    case AppShortcuts.CommandID.selectTerminalTab1,
      AppShortcuts.CommandID.selectTerminalTab2,
      AppShortcuts.CommandID.selectTerminalTab3,
      AppShortcuts.CommandID.selectTerminalTab4,
      AppShortcuts.CommandID.selectTerminalTab5,
      AppShortcuts.CommandID.selectTerminalTab6,
      AppShortcuts.CommandID.selectTerminalTab7,
      AppShortcuts.CommandID.selectTerminalTab8,
      AppShortcuts.CommandID.selectTerminalTab9,
      AppShortcuts.CommandID.selectPreviousTerminalTab,
      AppShortcuts.CommandID.selectNextTerminalTab,
      AppShortcuts.CommandID.selectPreviousTerminalPane,
      AppShortcuts.CommandID.selectNextTerminalPane,
      AppShortcuts.CommandID.selectTerminalPaneUp,
      AppShortcuts.CommandID.selectTerminalPaneDown,
      AppShortcuts.CommandID.selectTerminalPaneLeft,
      AppShortcuts.CommandID.selectTerminalPaneRight,
      AppShortcuts.CommandID.toggleSplitZoom:
      return .terminal

    default:
      return .general
    }
  }
}
