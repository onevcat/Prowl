import Testing

@testable import supacode

@MainActor
struct TerminalTabManagerTests {
  @Test func customTitleOverridesDisplayTitleWithoutFreezingLiveTitle() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(title: "shell", icon: nil)

    manager.setCustomTitle(tabId, title: "  build  ")
    manager.updateTitle(tabId, title: "npm test")

    #expect(manager.tabs.first?.title == "npm test")
    #expect(manager.tabs.first?.customTitle == "build")
    #expect(manager.tabs.first?.displayTitle == "build")
  }

  @Test func clearingCustomTitleRestoresLiveShellTitle() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(title: "shell", icon: nil)

    manager.setCustomTitle(tabId, title: "build")
    manager.updateTitle(tabId, title: "npm test")
    manager.setCustomTitle(tabId, title: "   ")

    #expect(manager.tabs.first?.customTitle == nil)
    #expect(manager.tabs.first?.displayTitle == "npm test")
  }

  @Test func updateTitleReportsDisplayTitleChange() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(title: "shell", icon: nil)

    #expect(manager.updateTitle(tabId, title: "npm test") == true)
    #expect(manager.updateTitle(tabId, title: "npm test") == false)
  }

  @Test func updateTitleReportsNoChangeWhenMaskedByCustomTitle() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(title: "shell", icon: nil)
    manager.setCustomTitle(tabId, title: "build")

    // Live title moves but the custom title still masks the visible display.
    #expect(manager.updateTitle(tabId, title: "npm test") == false)
    #expect(manager.tabs.first?.displayTitle == "build")
  }

  @Test func updateTitleReportsNoChangeForLockedTab() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(title: "RUN SCRIPT", icon: "play.fill", isTitleLocked: true)

    #expect(manager.updateTitle(tabId, title: "npm run dev") == false)
  }

  @Test func setCustomTitleReportsDisplayTitleChange() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(title: "shell", icon: nil)

    #expect(manager.setCustomTitle(tabId, title: "build") == true)
    #expect(manager.setCustomTitle(tabId, title: "build") == false)
    // Clearing the custom title restores the live title, another visible change.
    #expect(manager.setCustomTitle(tabId, title: "   ") == true)
    #expect(manager.tabs.first?.displayTitle == "shell")
  }

  @Test func customTitleIgnoresLockedTabs() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(title: "RUN SCRIPT", icon: "play.fill", isTitleLocked: true)

    manager.setCustomTitle(tabId, title: "build")

    #expect(manager.tabs.first?.customTitle == nil)
    #expect(manager.tabs.first?.displayTitle == "RUN SCRIPT")
  }

  @Test func editingTabIDIsDroppedWhenTabCloses() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(title: "one", icon: nil)

    manager.beginTabRename(tabId)
    manager.closeTab(tabId)

    #expect(manager.editingTabID == nil)
  }

  @Test func createTabInsertsAfterSelection() {
    let manager = TerminalTabManager()
    let first = manager.createTab(title: "one", icon: nil)
    let second = manager.createTab(title: "two", icon: nil)
    manager.selectTab(first)
    let third = manager.createTab(title: "three", icon: nil)
    let ids = manager.tabs.map(\.id)
    #expect(ids == [first, third, second])
  }

  @Test func closeTabSelectsAdjacent() {
    let manager = TerminalTabManager()
    let first = manager.createTab(title: "one", icon: nil)
    let second = manager.createTab(title: "two", icon: nil)
    let third = manager.createTab(title: "three", icon: nil)
    manager.selectTab(second)
    manager.closeTab(second)
    #expect(manager.tabs.map(\.id) == [first, third])
    #expect(manager.selectedTabId == first)
  }

  @Test func closeToRightRemovesTrailingTabs() {
    let manager = TerminalTabManager()
    let first = manager.createTab(title: "one", icon: nil)
    let second = manager.createTab(title: "two", icon: nil)
    let third = manager.createTab(title: "three", icon: nil)
    manager.closeToRight(of: second)
    #expect(manager.tabs.map(\.id) == [first, second])
    #expect(manager.tabs.contains { $0.id == third } == false)
  }

  @Test func closeOthersLeavesSingleTab() {
    let manager = TerminalTabManager()
    let first = manager.createTab(title: "one", icon: nil)
    let second = manager.createTab(title: "two", icon: nil)
    _ = manager.createTab(title: "three", icon: nil)
    manager.closeOthers(keeping: second)
    #expect(manager.tabs.map(\.id) == [second])
    #expect(manager.selectedTabId == second)
    #expect(manager.tabs.contains { $0.id == first } == false)
  }

  @Test func reorderTabsUsesProvidedOrder() {
    let manager = TerminalTabManager()
    let first = manager.createTab(title: "one", icon: nil)
    let second = manager.createTab(title: "two", icon: nil)
    let third = manager.createTab(title: "three", icon: nil)
    manager.reorderTabs([third, first, second])
    #expect(manager.tabs.map(\.id) == [third, first, second])
  }

  @Test func updateDirtyUpdatesTabState() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(title: "one", icon: nil)
    manager.updateDirty(tabId, isDirty: true)
    #expect(manager.tabs.first?.isDirty == true)
    manager.updateDirty(tabId, isDirty: false)
    #expect(manager.tabs.first?.isDirty == false)
  }

  @Test func overrideIconLocksAndSetsIcon() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(title: "one", icon: "terminal")
    manager.overrideIcon(tabId, icon: "sparkles")
    #expect(manager.tabs.first?.icon == "sparkles")
    #expect(manager.tabs.first?.iconLock == .user)
  }

  @Test func updateIconRespectsLock() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(title: "one", icon: "terminal")
    manager.overrideIcon(tabId, icon: "sparkles")
    manager.updateIcon(tabId, icon: "terminal")
    #expect(manager.tabs.first?.icon == "sparkles")
  }

  @Test func clearIconOverrideUnlocksIcon() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(title: "one", icon: "terminal")
    manager.overrideIcon(tabId, icon: "sparkles")
    manager.clearIconOverride(tabId)
    #expect(manager.tabs.first?.iconLock == .auto)
    manager.updateIcon(tabId, icon: "play.fill")
    #expect(manager.tabs.first?.icon == "play.fill")
  }

  @Test func setScriptIconAppliesAndFlags() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(title: "one", icon: "terminal")
    manager.setScriptIcon(tabId, icon: "play.fill")
    #expect(manager.tabs.first?.icon == "play.fill")
    #expect(manager.tabs.first?.iconLock == .script)
  }

  @Test func updateIconYieldsToScriptLock() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(title: "one", icon: "terminal")
    manager.setScriptIcon(tabId, icon: "play.fill")
    manager.updateIcon(tabId, icon: "@asset:Npm")
    #expect(manager.tabs.first?.icon == "play.fill")
  }

  @Test func userOverrideSupersedesScriptLock() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(title: "one", icon: "terminal")
    manager.setScriptIcon(tabId, icon: "play.fill")
    manager.overrideIcon(tabId, icon: "sparkles")
    #expect(manager.tabs.first?.icon == "sparkles")
    #expect(manager.tabs.first?.iconLock == .user)
  }

  @Test func setScriptIconYieldsToUserLock() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(title: "one", icon: "terminal")
    manager.overrideIcon(tabId, icon: "sparkles")
    manager.setScriptIcon(tabId, icon: "play.fill")
    #expect(manager.tabs.first?.icon == "sparkles")
    #expect(manager.tabs.first?.iconLock == .user)
  }

  @Test func clearIconOverrideReleasesScriptLock() {
    let manager = TerminalTabManager()
    let tabId = manager.createTab(title: "one", icon: "terminal")
    manager.setScriptIcon(tabId, icon: "play.fill")
    manager.clearIconOverride(tabId)
    #expect(manager.tabs.first?.iconLock == .auto)
    manager.updateIcon(tabId, icon: "@asset:Npm")
    #expect(manager.tabs.first?.icon == "@asset:Npm")
  }
}
