import Foundation
import Observation

@MainActor
@Observable
final class TerminalTabManager {
  var tabs: [TerminalTabItem] = [] {
    didSet {
      guard let editingTabID, !tabs.contains(where: { $0.id == editingTabID }) else { return }
      self.editingTabID = nil
    }
  }
  var selectedTabId: TerminalTabID?
  private(set) var editingTabID: TerminalTabID?

  func createTab(
    id: TerminalTabID = TerminalTabID(),
    title: String,
    icon: String?,
    isTitleLocked: Bool = false
  ) -> TerminalTabID {
    let tab = TerminalTabItem(id: id, title: title, icon: icon, isTitleLocked: isTitleLocked)
    if let selectedTabId,
      let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabId })
    {
      tabs.insert(tab, at: selectedIndex + 1)
    } else {
      tabs.append(tab)
    }
    selectedTabId = tab.id
    return tab.id
  }

  func selectTab(_ id: TerminalTabID) {
    guard tabs.contains(where: { $0.id == id }) else { return }
    selectedTabId = id
  }

  /// Updates the live shell title. Returns `true` when the visible
  /// `displayTitle` actually changed (a custom title masks live updates),
  /// so callers can refresh derived UI like the Active Agents subtitle.
  @discardableResult
  func updateTitle(_ id: TerminalTabID, title: String) -> Bool {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
    guard !tabs[index].isTitleLocked else { return false }
    // A TUI re-emits the same title constantly; skip the no-op write so it
    // doesn't invalidate the tab bar while an agent streams output.
    guard tabs[index].title != title else { return false }
    let previousDisplayTitle = tabs[index].displayTitle
    tabs[index].title = title
    return tabs[index].displayTitle != previousDisplayTitle
  }

  /// Sets (or clears, when blank) the user-defined title. Returns `true` when
  /// the visible `displayTitle` actually changed.
  @discardableResult
  func setCustomTitle(_ id: TerminalTabID, title: String) -> Bool {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
    guard !tabs[index].isTitleLocked else { return false }
    let previousDisplayTitle = tabs[index].displayTitle
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    tabs[index].customTitle = trimmed.isEmpty ? nil : trimmed
    return tabs[index].displayTitle != previousDisplayTitle
  }

  func beginTabRename(_ id: TerminalTabID) {
    guard tabs.contains(where: { $0.id == id && !$0.isTitleLocked }) else { return }
    editingTabID = id
  }

  func endTabRename() {
    editingTabID = nil
  }

  /// Auto-detection write path (e.g. `CommandIconMap`). Only applies
  /// when nothing has claimed the icon slot.
  func updateIcon(_ id: TerminalTabID, icon: String?) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    guard tabs[index].iconLock == .auto else { return }
    tabs[index].icon = icon
  }

  /// User picker path. Always wins, transitioning the slot to `.user`.
  func overrideIcon(_ id: TerminalTabID, icon: String) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    tabs[index].icon = icon
    tabs[index].iconLock = .user
  }

  /// "Reset to default" from the icon picker. Drops back to `.none`
  /// so the next auto-detected match can take over.
  func clearIconOverride(_ id: TerminalTabID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    tabs[index].iconLock = .auto
  }

  /// Run Script / Custom Command write path. Pins the icon to `.script`
  /// — strong enough to block auto-detection, weak enough to yield to
  /// a user-set `.user` lock.
  func setScriptIcon(_ id: TerminalTabID, icon: String) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    guard tabs[index].iconLock != .user else { return }
    tabs[index].icon = icon
    tabs[index].iconLock = .script
  }

  func updateDirty(_ id: TerminalTabID, isDirty: Bool) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    // OSC-9 drives this on every progress tick; skip the no-op write so an
    // unchanged dirty flag doesn't re-render the tab bar during agent activity.
    guard tabs[index].isDirty != isDirty else { return }
    tabs[index].isDirty = isDirty
  }

  func reorderTabs(_ orderedIds: [TerminalTabID]) {
    let existingIds = Set(tabs.map(\.id))
    let incomingIds = Set(orderedIds)
    guard existingIds == incomingIds else { return }
    let map = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
    tabs = orderedIds.compactMap { map[$0] }
  }

  func closeTab(_ id: TerminalTabID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    tabs.remove(at: index)
    guard selectedTabId == id else { return }
    if index > 0 {
      selectedTabId = tabs[index - 1].id
    } else if !tabs.isEmpty {
      selectedTabId = tabs[0].id
    } else {
      selectedTabId = nil
    }
  }

  func closeOthers(keeping id: TerminalTabID) {
    tabs = tabs.filter { $0.id == id }
    selectedTabId = tabs.first?.id
  }

  func closeToRight(of id: TerminalTabID) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
    tabs = Array(tabs.prefix(index + 1))
    if let selectedTabId, !tabs.contains(where: { $0.id == selectedTabId }) {
      self.selectedTabId = tabs.last?.id
    }
  }

  func closeAll() {
    tabs.removeAll()
    selectedTabId = nil
  }
}
