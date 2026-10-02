import Testing

@testable import supacode

struct GhosttySearchNavigatorTests {
  @Test func nextWrapsAtNewestToOldest() {
    let actions = GhosttySearchNavigator.bindingActions(
      direction: .next,
      selected: 0,
      total: 5
    )

    #expect(actions == Array(repeating: "navigate_search:next", count: 4))
  }

  @Test func previousWrapsAtOldestToNewest() {
    let actions = GhosttySearchNavigator.bindingActions(
      direction: .previous,
      selected: 4,
      total: 5
    )

    #expect(actions == Array(repeating: "navigate_search:previous", count: 4))
  }

  @Test func nonBoundaryUsesDirectAction() {
    let actions = GhosttySearchNavigator.bindingActions(
      direction: .next,
      selected: 1,
      total: 5
    )

    #expect(actions == ["navigate_search:previous"])
  }

  @Test func unknownSelectionUsesDirectAction() {
    let actions = GhosttySearchNavigator.bindingActions(
      direction: .next,
      selected: nil,
      total: 5
    )

    #expect(actions == ["navigate_search:previous"])
  }
}
