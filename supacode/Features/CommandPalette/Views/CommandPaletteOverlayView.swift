import AppKit
import ComposableArchitecture
import Foundation
import ProwlCLIShared
import SwiftUI

struct CommandPaletteOverlayView: View {
  @Bindable var store: StoreOf<CommandPaletteFeature>
  let items: [CommandPaletteItem]
  let resolvedKeybindings: ResolvedKeybindingMap
  @State private var isQueryFocused = false
  @State private var queryFocusTask: Task<Void, Never>?
  @State private var hoveredID: CommandPaletteItem.ID?
  @State private var filteredItems: [CommandPaletteItem] = []
  @State private var sectionedSuggestions: CommandPaletteSuggestions?

  var body: some View {
    ZStack {
      if store.isPresented {
        ZStack {
          Color.clear
            .contentShape(.rect)
            .onTapGesture {
              store.send(.setPresented(false))
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Dismiss Command Palette")

          GeometryReader { geometry in
            let topOffset = max(
              0,
              geometry.size.height * 0.3
                - CommandPaletteQuery.fieldHeight / 2
                - CommandPaletteCard.padding
            )
            VStack {
              CommandPaletteCard(
                query: $store.query,
                selectedIndex: $store.selectedIndex,
                items: filteredItems,
                sections: sectionedSuggestions,
                resolvedKeybindings: resolvedKeybindings,
                hoveredID: $hoveredID,
                isQueryFocused: isQueryFocused,
                onEvent: { event in
                  switch event {
                  case .exit:
                    store.send(.setPresented(false))
                  case .submit:
                    submitSelected(rows: filteredItems)
                  case .move(let direction):
                    moveSelection(direction, rows: filteredItems)
                  }
                },
                activate: { id in
                  activate(id, rows: filteredItems)
                }
              )
              .zIndex(1)
              .task {
                focusQueryField()
              }

              Spacer(minLength: 0)
            }
            .frame(
              width: geometry.size.width,
              height: geometry.size.height,
              alignment: .top
            )
            .padding(.top, topOffset)
          }
        }
      }
    }
    .onChange(of: store.isPresented) { _, newValue in
      if newValue {
        let updatedItems = refreshFilteredItems(items: items)
        updateSelection(rows: updatedItems)
        focusQueryField()
      } else {
        queryFocusTask?.cancel()
        queryFocusTask = nil
        isQueryFocused = false
        hoveredID = nil
      }
    }
    .onChange(of: store.query) { _, _ in
      let updatedItems = refreshFilteredItems(items: items)
      resetSelection(rows: updatedItems)
    }
    .onChange(of: items) { _, _ in
      let updatedItems = refreshFilteredItems(items: items)
      updateSelection(rows: updatedItems)
    }
    .onChange(of: store.recencyByItemID) { _, _ in
      let updatedItems = refreshFilteredItems(items: items)
      updateSelection(rows: updatedItems)
    }
    .task {
      _ = refreshFilteredItems(items: items)
    }
  }

  private func updateSelection(rows: [CommandPaletteItem]) {
    store.send(.updateSelection(itemsCount: rows.count))
  }

  private func resetSelection(rows: [CommandPaletteItem]) {
    store.send(.resetSelection(itemsCount: rows.count))
  }

  private func moveSelection(_ direction: MoveCommandDirection, rows: [CommandPaletteItem]) {
    switch direction {
    case .up:
      store.send(.moveSelection(.upSelection, itemsCount: rows.count))
    case .down:
      store.send(.moveSelection(.downSelection, itemsCount: rows.count))
    default:
      break
    }
  }

  private func submitSelected(rows: [CommandPaletteItem]) {
    let trimmed = store.query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rows.isEmpty else { return }
    guard let selectedIndex = store.selectedIndex else {
      if trimmed.isEmpty {
        return
      }
      store.send(.activateItem(rows[0]))
      return
    }
    if rows.indices.contains(selectedIndex) {
      store.send(.activateItem(rows[selectedIndex]))
      return
    }
    store.send(.activateItem(rows[rows.count - 1]))
  }

  private func activate(_ id: CommandPaletteItem.ID, rows: [CommandPaletteItem]) {
    guard let item = rows.first(where: { $0.id == id }) else { return }
    store.send(.activateItem(item))
  }

  private func refreshFilteredItems(items: [CommandPaletteItem]) -> [CommandPaletteItem] {
    let now = Date.now
    let trimmed = store.query.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      let suggestions = CommandPaletteFeature.suggestions(
        items: items,
        recencyByID: store.recencyByItemID,
        now: now
      )
      sectionedSuggestions = suggestions
      filteredItems = suggestions.allItems
    } else {
      sectionedSuggestions = nil
      filteredItems = CommandPaletteFeature.filterItems(
        items: items,
        query: trimmed,
        recencyByID: store.recencyByItemID,
        now: now
      )
    }
    return filteredItems
  }

  private func focusQueryField() {
    queryFocusTask?.cancel()
    isQueryFocused = false
    queryFocusTask = Task { @MainActor in
      let delays: [Duration?] = [nil, .milliseconds(50), .milliseconds(150)]
      for delay in delays {
        if let delay {
          try? await ContinuousClock().sleep(for: delay)
        } else {
          await Task.yield()
        }
        guard !Task.isCancelled else { return }
        isQueryFocused = false
        await Task.yield()
        guard !Task.isCancelled else { return }
        isQueryFocused = true
      }
    }
  }
}

private struct CommandPaletteCard: View {
  static let padding: CGFloat = 16

  @Binding var query: String
  @Binding var selectedIndex: Int?
  let items: [CommandPaletteItem]
  let sections: CommandPaletteSuggestions?
  let resolvedKeybindings: ResolvedKeybindingMap
  @Binding var hoveredID: CommandPaletteItem.ID?
  let isQueryFocused: Bool
  let onEvent: (CommandPaletteKeyboardEvent) -> Void
  let activate: (CommandPaletteItem.ID) -> Void

  private var backgroundColor: Color {
    Color(nsColor: .windowBackgroundColor)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      CommandPaletteQuery(query: $query, isTextFieldFocused: isQueryFocused) { event in
        onEvent(event)
      }

      Divider()

      CommandPaletteShortcutHandler(items: Array(items.prefix(5))) { id in
        activate(id)
      }

      CommandPaletteList(
        rows: items,
        sections: sections,
        resolvedKeybindings: resolvedKeybindings,
        selectedIndex: $selectedIndex,
        hoveredID: $hoveredID
      ) { id in
        activate(id)
      }
    }
    .frame(maxWidth: 500)
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
    .shadow(radius: 32, x: 0, y: 12)
    .padding(Self.padding)
  }
}

private enum CommandPaletteKeyboardEvent: Equatable {
  case exit
  case submit
  case move(MoveCommandDirection)
}

private struct CommandPaletteQuery: View {
  static let fieldHeight: CGFloat = 48

  @Binding var query: String
  let isTextFieldFocused: Bool
  var onEvent: ((CommandPaletteKeyboardEvent) -> Void)?

  init(
    query: Binding<String>,
    isTextFieldFocused: Bool,
    onEvent: ((CommandPaletteKeyboardEvent) -> Void)? = nil
  ) {
    _query = query
    self.isTextFieldFocused = isTextFieldFocused
    self.onEvent = onEvent
  }

  var body: some View {
    ZStack {
      Group {
        Button {
          onEvent?(.move(.up))
        } label: {
          Color.clear
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.upArrow, modifiers: [])
        Button {
          onEvent?(.move(.down))
        } label: {
          Color.clear
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.downArrow, modifiers: [])

        Button {
          onEvent?(.move(.up))
        } label: {
          Color.clear
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.init("p"), modifiers: [.control])
        Button {
          onEvent?(.move(.down))
        } label: {
          Color.clear
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.init("n"), modifiers: [.control])
      }
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)

      CommandPaletteQueryTextField(
        query: $query,
        isFocused: isTextFieldFocused,
        onEvent: { event in
          onEvent?(event)
        }
      )
      .padding()
      .frame(height: Self.fieldHeight)
    }
  }
}

private struct CommandPaletteQueryTextField: NSViewRepresentable {
  @Binding var query: String
  let isFocused: Bool
  let onEvent: (CommandPaletteKeyboardEvent) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(query: $query, onEvent: onEvent)
  }

  func makeNSView(context: Context) -> QueryField {
    let field = QueryField()
    field.delegate = context.coordinator
    field.onEvent = onEvent
    field.placeholderString = "Search for actions or branches..."
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    let titleFont = NSFont.preferredFont(forTextStyle: .title3)
    field.font = NSFont.systemFont(ofSize: titleFont.pointSize, weight: .light)
    field.usesSingleLineMode = true
    field.lineBreakMode = .byTruncatingTail
    return field
  }

  func updateNSView(_ nsView: QueryField, context: Context) {
    context.coordinator.query = $query
    context.coordinator.onEvent = onEvent
    nsView.onEvent = onEvent
    if nsView.stringValue != query {
      nsView.stringValue = query
    }
    if isFocused, !Self.isFocused(nsView) {
      nsView.window?.makeFirstResponder(nsView)
    }
  }

  private static func isFocused(_ field: NSTextField) -> Bool {
    guard let window = field.window else { return false }
    return window.firstResponder === field || window.firstResponder === field.currentEditor()
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var query: Binding<String>
    var onEvent: (CommandPaletteKeyboardEvent) -> Void

    init(query: Binding<String>, onEvent: @escaping (CommandPaletteKeyboardEvent) -> Void) {
      self.query = query
      self.onEvent = onEvent
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      query.wrappedValue = field.stringValue
    }

    func control(
      _ control: NSControl,
      textView: NSTextView,
      doCommandBy commandSelector: Selector
    ) -> Bool {
      switch commandSelector {
      case #selector(NSResponder.cancelOperation(_:)):
        onEvent(.exit)
      case #selector(NSResponder.insertNewline(_:)):
        onEvent(.submit)
      case #selector(NSResponder.moveUp(_:)):
        onEvent(.move(.up))
      case #selector(NSResponder.moveDown(_:)):
        onEvent(.move(.down))
      default:
        return false
      }
      return true
    }
  }

  final class QueryField: NSTextField {
    var onEvent: ((CommandPaletteKeyboardEvent) -> Void)?

    override func cancelOperation(_ sender: Any?) {
      onEvent?(.exit)
    }

    override func keyDown(with event: NSEvent) {
      if event.keyCode == 36 || event.keyCode == 76 {
        onEvent?(.submit)
        return
      }
      if event.modifierFlags.contains(.control) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "p":
          onEvent?(.move(.up))
          return
        case "n":
          onEvent?(.move(.down))
          return
        default:
          break
        }
      }
      super.keyDown(with: event)
    }
  }
}

private struct CommandPaletteList: View {
  static let listHeight: CGFloat = 200

  let rows: [CommandPaletteItem]
  let sections: CommandPaletteSuggestions?
  let resolvedKeybindings: ResolvedKeybindingMap
  @Binding var selectedIndex: Int?
  @Binding var hoveredID: CommandPaletteItem.ID?
  let activate: (CommandPaletteItem.ID) -> Void

  var body: some View {
    if rows.isEmpty {
      EmptyView()
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            if let sections {
              renderSectioned(sections)
            } else {
              renderFlat()
            }
          }
          .padding(10)
        }
        .frame(height: Self.listHeight)
        .onChange(of: selectedIndex) { _, newValue in
          guard let selectedIndex = newValue, rows.indices.contains(selectedIndex) else { return }
          proxy.scrollTo(rows[selectedIndex].id)
        }
      }
    }
  }

  @ViewBuilder
  private func renderFlat() -> some View {
    ForEach(Array(rows.enumerated()), id: \.1.id) { index, row in
      rowView(for: row, index: index)
    }
  }

  @ViewBuilder
  private func renderSectioned(_ sections: CommandPaletteSuggestions) -> some View {
    if !sections.recent.isEmpty {
      CommandPaletteSectionHeader(title: "Recent")
      ForEach(sections.recent) { row in
        if let index = rows.firstIndex(where: { $0.id == row.id }) {
          rowView(for: row, index: index)
        }
      }
    }
    if !sections.suggested.isEmpty {
      CommandPaletteSectionHeader(title: "Suggested")
        .padding(.top, sections.recent.isEmpty ? 0 : 6)
      ForEach(sections.suggested) { row in
        if let index = rows.firstIndex(where: { $0.id == row.id }) {
          rowView(for: row, index: index)
        }
      }
    }
  }

  private func rowView(for row: CommandPaletteItem, index: Int) -> some View {
    CommandPaletteRowView(
      row: row,
      resolvedKeybindings: resolvedKeybindings,
      shortcutIndex: index < 5 ? index : nil,
      isSelected: isRowSelected(index: index),
      hoveredID: $hoveredID
    ) {
      activate(row.id)
    }
    .id(row.id)
  }

  private func isRowSelected(index: Int) -> Bool {
    guard let selectedIndex else { return false }
    if selectedIndex < rows.count {
      return selectedIndex == index
    }
    return index == rows.count - 1
  }
}

private struct CommandPaletteSectionHeader: View {
  let title: String

  var body: some View {
    Text(title.uppercased())
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 6)
      .padding(.bottom, 2)
  }
}

private struct CommandPaletteRowView: View {
  let row: CommandPaletteItem
  let resolvedKeybindings: ResolvedKeybindingMap
  let shortcutIndex: Int?
  let isSelected: Bool
  @Binding var hoveredID: CommandPaletteItem.ID?
  let activate: () -> Void

  private var badge: String? {
    switch row.kind {
    case .checkForUpdates, .openRepository, .newWorkspace, .openSettings, .newWorktree, .viewArchivedWorktrees,
      .refreshWorktrees, .installCLI, .jumpToLatestUnread, .ghosttyCommand,
      .openPullRequest, .openRepositoryOnCodeHost, .markPullRequestReady, .mergePullRequest, .closePullRequest,
      .copyFailingJobURL,
      .copyCiFailureLogs,
      .rerunFailedJobs, .openFailingCheckDetails, .worktreeSelect, .changeFocusedTabIcon,
      .toggleLeftSidebar, .toggleActiveAgentsPanel, .toggleCanvas,
      .expandCanvasCard, .arrangeCanvasCards, .organizeCanvasCards, .tileCanvasCards, .selectAllCanvasCards,
      .toggleShelf, .showDiff, .outgoingChanges,
      .revealInFinder, .copyPath, .revealInSidebar,
      .runScript, .stopRunScript, .togglePinWorktree, .renameBranch,
      .openRepositorySettings, .runCustomCommand, .handOff, .launchAgentProfile, .runWorkflow:
      return nil
    case .deleteWorktree:
      return "Delete"
    #if DEBUG
      case .debugTestToast, .debugSimulateUpdateFound, .debugLightDockNotificationDot:
        return "Debug"
    #endif
    }
  }

  private var leadingIcon: String? {
    switch row.kind {
    case .checkForUpdates:
      return "arrow.down.circle"
    case .openRepository:
      return "folder"
    case .newWorkspace:
      return "folder.badge.person.crop"
    case .openSettings:
      return "gearshape"
    case .newWorktree:
      return "plus"
    case .viewArchivedWorktrees:
      return "archivebox"
    case .refreshWorktrees:
      return "arrow.clockwise"
    case .jumpToLatestUnread:
      return "bell.badge"
    case .ghosttyCommand:
      return "terminal"
    case .openPullRequest, .openRepositoryOnCodeHost:
      return "arrow.up.right.square"
    case .markPullRequestReady:
      return "checkmark.seal"
    case .mergePullRequest:
      return "arrow.merge"
    case .closePullRequest:
      return "xmark.circle"
    case .copyFailingJobURL:
      return "link"
    case .copyCiFailureLogs:
      return "doc.on.doc"
    case .rerunFailedJobs:
      return "arrow.counterclockwise"
    case .openFailingCheckDetails:
      return "exclamationmark.triangle"
    case .installCLI:
      return "terminal"
    case .worktreeSelect:
      return nil
    case .changeFocusedTabIcon:
      return "rectangle.on.rectangle"
    case .toggleLeftSidebar:
      return "sidebar.left"
    case .toggleActiveAgentsPanel:
      return "person.crop.rectangle.stack"
    case .toggleCanvas:
      return "square.grid.2x2"
    case .expandCanvasCard:
      return "arrow.up.left.and.arrow.down.right"
    case .arrangeCanvasCards:
      return "rectangle.3.group"
    case .organizeCanvasCards:
      return "square.grid.2x2"
    case .tileCanvasCards:
      return "rectangle.split.2x1"
    case .selectAllCanvasCards:
      return "checkmark.rectangle.stack"
    case .toggleShelf:
      return "books.vertical"
    case .showDiff:
      return "plusminus.circle"
    case .outgoingChanges:
      return "arrow.up.right"
    case .revealInFinder:
      return "folder"
    case .copyPath:
      return "doc.on.clipboard"
    case .revealInSidebar:
      return "sidebar.left.badge.dot"
    case .runScript:
      return "play.circle"
    case .stopRunScript:
      return "stop.circle"
    case .togglePinWorktree(_, let isCurrentlyPinned):
      return isCurrentlyPinned ? "pin.slash" : "pin"
    case .renameBranch:
      return "pencil"
    case .openRepositorySettings:
      return "gearshape"
    case .deleteWorktree:
      return "trash"
    case .runCustomCommand(_, let systemImage):
      return systemImage
    case .handOff:
      return "arrow.left.arrow.right"
    case .launchAgentProfile:
      return "play.circle"
    case .runWorkflow:
      return "rectangle.stack.badge.play"
    #if DEBUG
      case .debugTestToast:
        return "ladybug"
      case .debugSimulateUpdateFound:
        return "ladybug"
      case .debugLightDockNotificationDot:
        return "ladybug"
    #endif
    }
  }

  private var emphasis: Bool {
    switch row.kind {
    case .checkForUpdates, .openRepository, .newWorkspace, .openSettings, .newWorktree, .viewArchivedWorktrees,
      .refreshWorktrees, .installCLI, .jumpToLatestUnread, .ghosttyCommand,
      .openPullRequest, .openRepositoryOnCodeHost, .markPullRequestReady, .mergePullRequest, .closePullRequest,
      .copyFailingJobURL,
      .copyCiFailureLogs,
      .rerunFailedJobs, .openFailingCheckDetails, .changeFocusedTabIcon,
      .toggleLeftSidebar, .toggleActiveAgentsPanel, .toggleCanvas,
      .expandCanvasCard, .arrangeCanvasCards, .organizeCanvasCards, .tileCanvasCards, .selectAllCanvasCards,
      .toggleShelf, .showDiff, .outgoingChanges,
      .revealInFinder, .copyPath, .revealInSidebar,
      .runScript, .stopRunScript, .togglePinWorktree, .renameBranch,
      .openRepositorySettings,
      .deleteWorktree, .runCustomCommand, .handOff, .launchAgentProfile, .runWorkflow:
      return true
    case .worktreeSelect:
      return false
    #if DEBUG
      case .debugTestToast, .debugSimulateUpdateFound, .debugLightDockNotificationDot:
        return true
    #endif
    }
  }

  var body: some View {
    Button(action: activate) {
      HStack(spacing: 8) {
        if let iconSource = row.agentProfileIconSource {
          AgentProfileIconImage(source: iconSource, pointSize: 15)
            .foregroundStyle(emphasis ? .primary : .secondary)
            .frame(width: 16, height: 16, alignment: .center)
        } else if let leadingIcon {
          Image(systemName: leadingIcon)
            .foregroundStyle(emphasis ? .primary : .secondary)
            .font(.subheadline.weight(.medium))
            .frame(width: 16, height: 16, alignment: .center)
            .accessibilityHidden(true)
        }

        VStack(alignment: .leading, spacing: 2) {
          Text(titleText)
            .fontWeight(emphasis ? .medium : .regular)

          if let subtitle = row.subtitle {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Spacer()

        if let badge, !badge.isEmpty {
          Text(badge)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
              Capsule().fill(Color(nsColor: .quaternaryLabelColor))
            )
            .foregroundStyle(.secondary)
        }

        if let shortcutIndex {
          ShortcutSymbolsView(symbols: commandPaletteShortcutSymbols(for: shortcutIndex))
            .foregroundStyle(.secondary)
        }
      }
      .padding(8)
      // The selected row paints an accent background; force a dark color scheme
      // for its content so the label and symbols stay legible in light mode.
      .transformEnvironment(\.colorScheme) { colorScheme in
        if isSelected { colorScheme = .dark }
      }
      .background(rowBackground)
      .clipShape(.rect(cornerRadius: 14))
    }
    .buttonStyle(.plain)
    .help(helpText)
    .onHover { hovering in
      hoveredID = hovering ? row.id : nil
    }
  }

  private var rowBackground: some View {
    Group {
      if isSelected {
        Color(nsColor: .selectedContentBackgroundColor)
      } else if hoveredID == row.id {
        Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.7)
      } else {
        Color.clear
      }
    }
  }

  private var helpText: String {
    let base: String
    switch row.kind {
    case .worktreeSelect:
      base = "Switch to \(row.title)"
    case .checkForUpdates:
      base = "Check for Updates"
    case .openRepository:
      base = "Open Repository"
    case .newWorkspace:
      base = "New Workspace"
    case .openSettings:
      base = "Open Settings"
    case .newWorktree:
      base = "New Worktree"
    case .viewArchivedWorktrees:
      base = "View Archived Worktrees"
    case .refreshWorktrees:
      base = "Refresh Worktrees"
    case .jumpToLatestUnread:
      base = "Jump to Latest Unread"
    case .ghosttyCommand:
      base = row.title
    case .openPullRequest, .openRepositoryOnCodeHost:
      base = row.title
    case .markPullRequestReady:
      base = "Mark pull request ready for review"
    case .mergePullRequest:
      base = "Merge pull request"
    case .closePullRequest:
      base = "Close pull request"
    case .copyFailingJobURL:
      base = "Copy failing job URL"
    case .copyCiFailureLogs:
      base = "Copy CI failure logs"
    case .rerunFailedJobs:
      base = "Re-run failed jobs"
    case .openFailingCheckDetails:
      base = "Open failing check details"
    case .installCLI:
      base = "Install Command Line Tool"
    case .changeFocusedTabIcon:
      base = "Change Tab Icon"
    case .toggleLeftSidebar:
      base = "Toggle Sidebar"
    case .toggleActiveAgentsPanel:
      base = "Toggle Active Agents Panel"
    case .toggleCanvas:
      base = "Toggle Canvas"
    case .expandCanvasCard:
      base = "Expand / Restore Canvas Card"
    case .arrangeCanvasCards:
      base = "Arrange Canvas Cards"
    case .organizeCanvasCards:
      base = "Organize Canvas Cards"
    case .tileCanvasCards:
      base = "Tile Canvas Cards"
    case .selectAllCanvasCards:
      base = "Select All Canvas Cards"
    case .toggleShelf:
      base = "Toggle Shelf"
    case .showDiff:
      base = "Show Diff"
    case .outgoingChanges:
      base = "Show committed changes relative to the branch's base"
    case .revealInFinder:
      base = "Reveal in Finder"
    case .copyPath:
      base = "Copy Path"
    case .revealInSidebar:
      base = "Reveal in Sidebar"
    case .runScript:
      base = "Run Script"
    case .stopRunScript:
      base = "Stop Script"
    case .togglePinWorktree(_, let isCurrentlyPinned):
      base = isCurrentlyPinned ? "Unpin Worktree" : "Pin Worktree"
    case .renameBranch:
      base = "Rename Branch"
    case .openRepositorySettings:
      base = "Open Repo Settings"
    case .deleteWorktree:
      base = "Delete \(row.title)"
    case .runCustomCommand:
      base = "Run Custom Command: \(row.title)"
    case .handOff:
      base = row.title
    case .launchAgentProfile:
      base = row.title
    case .runWorkflow:
      base = row.title
    #if DEBUG
      case .debugTestToast, .debugSimulateUpdateFound, .debugLightDockNotificationDot:
        base = row.title
    #endif
    }
    if let explicitShortcutLabel {
      return "\(base) (\(explicitShortcutLabel))"
    }
    if let shortcutIndex {
      return "\(base) (\(commandPaletteShortcutLabel(for: shortcutIndex)))"
    }
    return base
  }

  private var titleText: String {
    guard let shortcutLabel = row.appShortcutLabel(in: resolvedKeybindings) else {
      return row.title
    }
    return "\(row.title) (\(shortcutLabel))"
  }

  private var explicitShortcutLabel: String? {
    row.appShortcutLabel(in: resolvedKeybindings)
  }
}

private struct ShortcutSymbolsView: View {
  let symbols: [String]

  var body: some View {
    HStack(spacing: 1) {
      ForEach(symbols, id: \.self) { symbol in
        Text(symbol)
          .frame(minWidth: 13)
      }
    }
  }
}

private struct CommandPaletteShortcutHandler: View {
  let items: [CommandPaletteItem]
  let activate: (CommandPaletteItem.ID) -> Void

  var body: some View {
    Group {
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        shortcutButton(index: index, itemID: item.id)
      }
    }
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }

  private func shortcutButton(index: Int, itemID: CommandPaletteItem.ID) -> some View {
    Button {
      activate(itemID)
    } label: {
      Color.clear
    }
    .buttonStyle(.plain)
    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
  }
}

private func commandPaletteShortcutSymbols(for index: Int) -> [String] {
  ["⌘", "\(index + 1)"]
}

private func commandPaletteShortcutLabel(for index: Int) -> String {
  "Cmd+\(index + 1)"
}
