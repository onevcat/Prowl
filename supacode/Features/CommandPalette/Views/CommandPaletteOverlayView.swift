import AppKit
import ComposableArchitecture
import Foundation
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
                mode: store.mode,
                detachedCards: store.detachedCards,
                resolvedKeybindings: resolvedKeybindings,
                hoveredID: $hoveredID,
                isQueryFocused: isQueryFocused,
                onEvent: { event in
                  switch event {
                  case .exit:
                    store.send(.setPresented(false))
                  case .submit:
                    if store.mode == .detachedCards {
                      store.send(.confirmDetachedCardSelection)
                    } else {
                      submitSelected(rows: filteredItems)
                    }
                  case .move(let direction):
                    moveSelection(direction, rows: filteredItems)
                  }
                },
                activate: { id in
                  activate(id, rows: filteredItems)
                },
                toggleDetachedCardSelection: { id in
                  store.send(.toggleDetachedCardSelection(id))
                },
                selectDetachedCardRange: { id, orderedIDs in
                  store.send(.selectDetachedCardRange(id, orderedIDs: orderedIDs))
                },
                confirmDetachedCardSelection: {
                  store.send(.confirmDetachedCardSelection)
                },
                cancelDetachedCardSelection: {
                  store.send(.setPresented(false))
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
    .onChange(of: store.mode) { _, _ in
      let updatedItems = refreshFilteredItems(items: items)
      updateSelection(rows: updatedItems)
    }
    .onChange(of: store.detachedCards) { _, _ in
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
    if store.mode == .detachedCards, case .restoreDetachedCard(let candidateID) = item.kind {
      store.send(.toggleDetachedCardSelection(candidateID))
      return
    }
    store.send(.activateItem(item))
  }

  private func refreshFilteredItems(items: [CommandPaletteItem]) -> [CommandPaletteItem] {
    let now = Date.now
    switch store.mode {
    case .commands:
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
    case .detachedCards:
      sectionedSuggestions = nil
      let updatedItems = CommandPaletteFeature.filterDetachedCardItems(
        presentations: store.detachedCards.rows,
        query: store.query,
        recencyByID: store.recencyByItemID,
        now: now
      )
      filteredItems = updatedItems
      return updatedItems
    }
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
  let mode: CommandPaletteFeature.State.Mode
  let detachedCards: CommandPaletteFeature.State.DetachedCardsState
  let resolvedKeybindings: ResolvedKeybindingMap
  @Binding var hoveredID: CommandPaletteItem.ID?
  let isQueryFocused: Bool
  let onEvent: (CommandPaletteKeyboardEvent) -> Void
  let activate: (CommandPaletteItem.ID) -> Void
  let toggleDetachedCardSelection: (TmuxDetachedCardCandidate.ID) -> Void
  let selectDetachedCardRange: (TmuxDetachedCardCandidate.ID, [TmuxDetachedCardCandidate.ID]) -> Void
  let confirmDetachedCardSelection: () -> Void
  let cancelDetachedCardSelection: () -> Void

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

      CommandPaletteExitShortcut {
        onEvent(.exit)
      }

      if mode == .detachedCards {
        RestoreCardsPanel(
          rows: items,
          selectedIDs: detachedCards.selectedIDs,
          diagnostics: detachedCards.diagnostics,
          selectedIndex: $selectedIndex,
          hoveredID: $hoveredID,
          toggleSelection: toggleDetachedCardSelection,
          selectRange: selectDetachedCardRange,
          cancel: cancelDetachedCardSelection,
          restore: confirmDetachedCardSelection
        )
      } else {
        CommandPaletteList(
          rows: items,
          sections: sections,
          emptyMessage: "",
          resolvedKeybindings: resolvedKeybindings,
          selectedIndex: $selectedIndex,
          hoveredID: $hoveredID
        ) { id in
          activate(id)
        }
      }
    }
    .frame(maxWidth: mode == .detachedCards ? 760 : 500)
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
    .shadow(radius: 32, x: 0, y: 12)
    .padding(Self.padding)
  }
}

private struct RestoreCardsPanel: View {
  let rows: [CommandPaletteItem]
  let selectedIDs: Set<TmuxDetachedCardCandidate.ID>
  let diagnostics: [TmuxCardStructureDiagnostic]
  @Binding var selectedIndex: Int?
  @Binding var hoveredID: CommandPaletteItem.ID?
  let toggleSelection: (TmuxDetachedCardCandidate.ID) -> Void
  let selectRange: (TmuxDetachedCardCandidate.ID, [TmuxDetachedCardCandidate.ID]) -> Void
  let cancel: () -> Void
  let restore: () -> Void

  private var orderedCandidateIDs: [TmuxDetachedCardCandidate.ID] {
    rows.compactMap(\.detachedCardCandidateID)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Detached Cards")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

          Spacer()

          Text("\(rows.count) available")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        }

        ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
          Text(diagnostic.message)
            .font(.caption)
            .foregroundStyle(Color(nsColor: .systemOrange))
            .lineLimit(2)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)

      Divider()

      if rows.isEmpty {
        Text("No matching detached cards")
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 260)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
              ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                RestoreCardRow(
                  row: row,
                  shortcutIndex: index < 5 ? index : nil,
                  isHighlighted: selectedIndex == index || hoveredID == row.id,
                  isSelected: row.detachedCardCandidateID.map { selectedIDs.contains($0) } ?? false
                ) {
                  handleRowClick(row)
                }
                .id(row.id)
                .onHover { hovering in
                  hoveredID = hovering ? row.id : nil
                }
              }
            }
            .padding(12)
          }
          .frame(maxHeight: 420)
          .onChange(of: selectedIndex) { _, index in
            guard let index, rows.indices.contains(index) else { return }
            withAnimation(.easeOut(duration: 0.12)) {
              proxy.scrollTo(rows[index].id, anchor: .center)
            }
          }
        }
      }

      Divider()

      HStack(spacing: 12) {
        Text(selectionSummary)
          .font(.callout)
          .foregroundStyle(.secondary)

        Spacer()

        Button("Cancel") {
          cancel()
        }
        .keyboardShortcut(.cancelAction)
        .help("Cancel restore")

        Button("Restore Selected") {
          restore()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(selectedIDs.isEmpty)
        .buttonStyle(.borderedProminent)
        .help("Restore selected cards")
      }
      .padding(14)
      .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
  }

  private var selectionSummary: String {
    switch selectedIDs.count {
    case 0:
      return "No cards selected"
    case 1:
      return "1 card selected"
    default:
      return "\(selectedIDs.count) cards selected"
    }
  }

  private func handleRowClick(_ row: CommandPaletteItem) {
    guard let candidateID = row.detachedCardCandidateID else { return }
    if NSEvent.modifierFlags.contains(.shift) {
      selectRange(candidateID, orderedCandidateIDs)
    } else {
      toggleSelection(candidateID)
    }
  }
}

private struct RestoreCardRow: View {
  let row: CommandPaletteItem
  let shortcutIndex: Int?
  let isHighlighted: Bool
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .center, spacing: 12) {
        selectionBox

        VStack(alignment: .leading, spacing: 5) {
          Text(row.title)
            .font(.headline.weight(.semibold))
            .foregroundStyle(primaryForeground)
            .lineLimit(1)

          ForEach(subtitleLines, id: \.self) { line in
            Text(line)
              .font(.caption)
              .foregroundStyle(secondaryForeground)
              .lineLimit(1)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        VStack(alignment: .trailing, spacing: 8) {
          if let shortcutIndex {
            ShortcutSymbolsView(symbols: commandPaletteShortcutSymbols(for: shortcutIndex))
              .font(.callout.weight(.semibold))
              .foregroundStyle(primaryForeground)
          }

          Text("Detached")
            .font(.caption.weight(.semibold))
            .foregroundStyle(secondaryForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.75), in: Capsule())
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .contentShape(Rectangle())
      .background(background)
      .clipShape(.rect(cornerRadius: 7))
      .overlay(
        RoundedRectangle(cornerRadius: 7)
          .stroke(borderColor)
      )
    }
    .buttonStyle(.plain)
    .help("Select \(row.title)")
  }

  private var subtitleLines: [String] {
    row.subtitle?.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) ?? []
  }

  private var primaryForeground: Color {
    isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : Color(nsColor: .labelColor)
  }

  private var secondaryForeground: Color {
    isSelected ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.82) : Color(nsColor: .secondaryLabelColor)
  }

  private var background: some View {
    Group {
      if isSelected {
        Color.accentColor
      } else if isHighlighted {
        Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
      } else {
        Color.clear
      }
    }
  }

  private var borderColor: Color {
    isSelected ? Color.accentColor.opacity(0.9) : Color(nsColor: .separatorColor).opacity(isHighlighted ? 0.75 : 0)
  }

  private var selectionBox: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 5)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        .background(
          RoundedRectangle(cornerRadius: 5)
            .fill(isSelected ? Color(nsColor: .alternateSelectedControlTextColor).opacity(0.22) : .clear)
        )
        .frame(width: 22, height: 22)

      if isSelected {
        Image(systemName: "checkmark")
          .font(.caption.weight(.bold))
          .foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
      }
    }
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
  let emptyMessage: String
  let resolvedKeybindings: ResolvedKeybindingMap
  @Binding var selectedIndex: Int?
  @Binding var hoveredID: CommandPaletteItem.ID?
  let activate: (CommandPaletteItem.ID) -> Void

  var body: some View {
    if rows.isEmpty {
      if emptyMessage.isEmpty {
        EmptyView()
      } else {
        CommandPaletteEmptyRowsView(message: emptyMessage)
      }
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

private struct CommandPaletteEmptyRowsView: View {
  let message: String

  var body: some View {
    Text(message)
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, minHeight: CommandPaletteList.listHeight)
  }
}

@MainActor
private enum CommandPaletteAppIcons {
  static let openInVSCode = appImage(for: .vscode)
  static let openInFork = appImage(for: .fork)
  static let revealInFinder = appImage(for: .finder)

  private static func appImage(for action: OpenWorktreeAction) -> NSImage? {
    guard let menuIcon = action.menuIcon else { return nil }
    switch menuIcon {
    case .app(let image):
      return image
    case .symbol:
      return nil
    }
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
    case .checkForUpdates, .openRepository, .layoutCenter, .layoutArrange, .layoutOverview,
      .openInVSCode, .openInFork, .openWeb, .openSettings, .newWorktree,
      .viewArchivedWorktrees, .refreshWorktrees, .installCLI, .jumpToLatestUnread, .ghosttyCommand,
      .openPullRequest, .openRepositoryOnCodeHost, .markPullRequestReady, .mergePullRequest, .closePullRequest,
      .copyFailingJobURL,
      .copyCiFailureLogs,
      .rerunFailedJobs, .openFailingCheckDetails, .worktreeSelect, .changeFocusedTabIcon,
      .toggleLeftSidebar, .toggleActiveAgentsPanel, .toggleCanvas, .expandCanvasCard, .arrangeCanvasCards,
      .organizeCanvasCards, .selectAllCanvasCards, .toggleShelf, .showDiff,
      .revealInFinder, .copyPath, .revealInSidebar,
      .runScript, .stopRunScript, .togglePinWorktree, .renameBranch,
      .openRepositorySettings, .restoreRunningTab, .restoreDetachedCard, .runCustomCommand:
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
    case .layoutCenter:
      return "scope"
    case .layoutArrange:
      return "rectangle.3.group"
    case .layoutOverview:
      return "binoculars"
    case .openInVSCode:
      return "chevron.left.forwardslash.chevron.right"
    case .openInFork:
      return "arrow.triangle.branch"
    case .openWeb:
      return "globe"
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
    case .restoreRunningTab, .restoreDetachedCard:
      return "arrow.counterclockwise"
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
      return "rectangle.3.group.bubble"
    case .selectAllCanvasCards:
      return "selection.pin.in.out"
    case .toggleShelf:
      return "books.vertical"
    case .showDiff:
      return "plusminus.circle"
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
    case .runCustomCommand(_, _, let systemImage):
      return systemImage
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

  private var appIcon: NSImage? {
    switch row.kind {
    case .openInVSCode:
      return CommandPaletteAppIcons.openInVSCode
    case .openInFork:
      return CommandPaletteAppIcons.openInFork
    case .revealInFinder:
      return CommandPaletteAppIcons.revealInFinder
    case .checkForUpdates, .openRepository, .layoutCenter, .layoutArrange, .layoutOverview,
      .openWeb, .copyPath, .openSettings, .newWorktree, .viewArchivedWorktrees, .refreshWorktrees, .installCLI,
      .jumpToLatestUnread, .restoreRunningTab, .restoreDetachedCard, .ghosttyCommand, .openPullRequest,
      .openRepositoryOnCodeHost,
      .markPullRequestReady, .mergePullRequest, .closePullRequest, .copyFailingJobURL, .copyCiFailureLogs,
      .rerunFailedJobs, .openFailingCheckDetails, .worktreeSelect, .changeFocusedTabIcon,
      .toggleLeftSidebar, .toggleActiveAgentsPanel, .toggleCanvas, .expandCanvasCard, .arrangeCanvasCards,
      .organizeCanvasCards, .selectAllCanvasCards, .toggleShelf, .showDiff,
      .revealInSidebar, .runScript, .stopRunScript, .togglePinWorktree, .renameBranch,
      .openRepositorySettings, .deleteWorktree, .runCustomCommand:
      return nil
    #if DEBUG
      case .debugTestToast, .debugSimulateUpdateFound, .debugLightDockNotificationDot:
        return nil
    #endif
    }
  }

  private var emphasis: Bool {
    switch row.kind {
    case .checkForUpdates, .openRepository, .layoutCenter, .layoutArrange, .layoutOverview,
      .openInVSCode, .openInFork, .openWeb, .openSettings, .newWorktree,
      .viewArchivedWorktrees, .refreshWorktrees, .installCLI, .jumpToLatestUnread, .ghosttyCommand,
      .openPullRequest, .openRepositoryOnCodeHost, .markPullRequestReady, .mergePullRequest, .closePullRequest,
      .copyFailingJobURL,
      .copyCiFailureLogs,
      .rerunFailedJobs, .openFailingCheckDetails, .changeFocusedTabIcon,
      .toggleLeftSidebar, .toggleActiveAgentsPanel, .toggleCanvas, .expandCanvasCard, .arrangeCanvasCards,
      .organizeCanvasCards, .selectAllCanvasCards, .toggleShelf, .showDiff,
      .revealInFinder, .copyPath, .revealInSidebar,
      .runScript, .stopRunScript, .togglePinWorktree, .renameBranch,
      .openRepositorySettings,
      .deleteWorktree, .runCustomCommand:
      return true
    case .worktreeSelect:
      return false
    case .restoreRunningTab, .restoreDetachedCard:
      return true
    #if DEBUG
      case .debugTestToast, .debugSimulateUpdateFound, .debugLightDockNotificationDot:
        return true
    #endif
    }
  }

  var body: some View {
    let foregroundColors = commandPaletteRowForegroundColors(isSelected: isSelected)
    let primaryForeground = Color(nsColor: foregroundColors.primary)
    let secondaryForeground = Color(nsColor: foregroundColors.secondary)

    Button(action: activate) {
      HStack(spacing: 8) {
        if let appIcon {
          Image(nsImage: appIcon)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 16, height: 16, alignment: .center)
            .accessibilityHidden(true)
        } else if let leadingIcon {
          Image(systemName: leadingIcon)
            .foregroundStyle(emphasis ? primaryForeground : secondaryForeground)
            .font(.subheadline.weight(.medium))
            .frame(width: 16, height: 16, alignment: .center)
            .accessibilityHidden(true)
        }

        VStack(alignment: .leading, spacing: 2) {
          Text(titleText)
            .fontWeight(emphasis ? .medium : .regular)
            .foregroundStyle(primaryForeground)

          if let subtitle = row.subtitle {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(secondaryForeground)
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
            .foregroundStyle(secondaryForeground)
        }

        if let shortcutIndex {
          ShortcutSymbolsView(symbols: commandPaletteShortcutSymbols(for: shortcutIndex))
            .foregroundStyle(secondaryForeground)
        }
      }
      .padding(8)
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
    case .layoutCenter:
      base = "Layout: Center"
    case .layoutArrange:
      base = "Layout: Arrange"
    case .layoutOverview:
      base = "Layout: Overview"
    case .openInVSCode:
      base = "Open in VS Code"
    case .openInFork:
      base = "Open in Fork"
    case .copyPath:
      base = "Copy Path"
    case .revealInFinder:
      base = "Reveal in Finder"
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
    case .restoreRunningTab:
      base = "Restore Running Tab"
    case .restoreDetachedCard:
      base = "Restore Card"
    case .ghosttyCommand:
      base = row.title
    case .openWeb:
      base = "Open repository web URL"
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
      base = "Expand Canvas Card"
    case .arrangeCanvasCards:
      base = "Arrange Canvas Cards"
    case .organizeCanvasCards:
      base = "Organize Canvas Cards"
    case .selectAllCanvasCards:
      base = "Select All Canvas Cards"
    case .toggleShelf:
      base = "Toggle Shelf"
    case .showDiff:
      base = "Show Diff"
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

struct CommandPaletteRowForegroundColors {
  let primary: NSColor
  let secondary: NSColor
}

func commandPaletteRowForegroundColors(isSelected: Bool) -> CommandPaletteRowForegroundColors {
  if isSelected {
    return CommandPaletteRowForegroundColors(
      primary: .alternateSelectedControlTextColor,
      secondary: .alternateSelectedControlTextColor
    )
  }
  return CommandPaletteRowForegroundColors(
    primary: .labelColor,
    secondary: .secondaryLabelColor
  )
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

private struct CommandPaletteExitShortcut: View {
  let exit: () -> Void

  var body: some View {
    Button {
      exit()
    } label: {
      Color.clear
    }
    .buttonStyle(.plain)
    .keyboardShortcut(.cancelAction)
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }
}

private func commandPaletteShortcutSymbols(for index: Int) -> [String] {
  ["⌘", "\(index + 1)"]
}

private func commandPaletteShortcutLabel(for index: Int) -> String {
  "Cmd+\(index + 1)"
}

private extension CommandPaletteItem {
  var detachedCardCandidateID: TmuxDetachedCardCandidate.ID? {
    guard case .restoreDetachedCard(let id) = kind else { return nil }
    return id
  }
}
