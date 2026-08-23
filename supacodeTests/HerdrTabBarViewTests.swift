import Foundation
import Testing

@testable import supacode

struct HerdrTabBarViewTests {
  @Test func projectsOnlyFocusedWorkspaceTabsAndZoomSuffix() {
    let snapshot = HerdrSessionSnapshot(
      version: "0.8.2",
      protocolVersion: 20,
      focusedWorkspaceID: "w1",
      focusedTabID: "w1:t2",
      focusedPaneID: nil,
      workspaces: [],
      tabs: [
        HerdrTab(tabID: "w1:t1", workspaceID: "w1", label: "shell"),
        HerdrTab(tabID: "w2:t1", workspaceID: "w2", label: "other"),
        HerdrTab(tabID: "w1:t2", workspaceID: "w1", label: "logs", focused: true),
      ],
      panes: [],
      layouts: [HerdrLayout(workspaceID: "w1", tabID: "w1:t2", zoomed: true)],
      agents: []
    )

    let items = HerdrTabBarProjection.items(in: snapshot, workspaceID: "w1")

    #expect(items.map(\.id) == ["w1:t1", "w1:t2"])
    #expect(items.map(\.displayLabel) == ["shell", "logs Z"])
    #expect(items.last?.isFocused == true)
  }

  @Test func computesServerInsertIndexBeforeDropTarget() {
    let items = [
      HerdrTabBarItem(id: "t1", workspaceID: "w1", label: "one", isZoomed: false, isFocused: true),
      HerdrTabBarItem(id: "t2", workspaceID: "w1", label: "two", isZoomed: false, isFocused: false),
      HerdrTabBarItem(id: "t3", workspaceID: "w1", label: "three", isZoomed: false, isFocused: false),
    ]

    #expect(
      HerdrTabBarProjection.insertIndex(sourceID: "t3", targetID: "t1", items: items) == 0
    )
    #expect(
      HerdrTabBarProjection.insertIndex(sourceID: "t2", targetID: "t3", items: items) == 2
    )
    #expect(
      HerdrTabBarProjection.insertIndex(sourceID: "t2", targetID: "t2", items: items) == nil
    )
  }

  @Test func cyclesTabsLikeHerdrMouseWheel() {
    let items = [
      HerdrTabBarItem(id: "t1", workspaceID: "w1", label: "one", isZoomed: false, isFocused: true),
      HerdrTabBarItem(id: "t2", workspaceID: "w1", label: "two", isZoomed: false, isFocused: false),
      HerdrTabBarItem(id: "t3", workspaceID: "w1", label: "three", isZoomed: false, isFocused: false),
    ]

    #expect(HerdrTabBarProjection.cycleTarget(selectedID: "t1", direction: 1, items: items) == "t2")
    #expect(HerdrTabBarProjection.cycleTarget(selectedID: "t1", direction: -1, items: items) == "t3")
  }
}
