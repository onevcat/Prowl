import Foundation
import Testing

@testable import supacode

@MainActor
struct CanvasCurrentVisibleTabSelectionTests {
  @Test func prefersFocusedTabWhenItIsVisible() {
    let focused = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let selected = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

    let result = canvasCurrentVisibleTabID(
      focusedTabID: focused,
      visibleTabIDs: [selected, focused],
      selectedTabIDs: [selected]
    )

    #expect(result == focused)
  }

  @Test func fallsBackToFirstSelectedVisibleTab() {
    let selectedVisible = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    let selectedHidden = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
    let otherVisible = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)

    let result = canvasCurrentVisibleTabID(
      focusedTabID: nil,
      visibleTabIDs: [otherVisible, selectedVisible],
      selectedTabIDs: [selectedHidden, selectedVisible]
    )

    #expect(result == selectedVisible)
  }

  @Test func fallsBackToFirstVisibleTabWhenNoFocusedOrSelected() {
    let first = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!)
    let second = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!)

    let result = canvasCurrentVisibleTabID(
      focusedTabID: nil,
      visibleTabIDs: [first, second],
      selectedTabIDs: []
    )

    #expect(result == first)
  }

  @Test func returnsNilWhenNoVisibleTabsExist() {
    let focused = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000008")!)
    let selected = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!)

    let result = canvasCurrentVisibleTabID(
      focusedTabID: focused,
      visibleTabIDs: [],
      selectedTabIDs: [selected]
    )

    #expect(result == nil)
  }
}
