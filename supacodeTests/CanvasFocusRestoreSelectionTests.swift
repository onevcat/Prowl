import Foundation
import Testing

@testable import supacode

@MainActor
struct CanvasFocusRestoreSelectionTests {
  @Test func returnsFocusedTabWhenFocusSuspensionEnds() {
    let focused = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!)

    let result = canvasRestoredFocusTabID(
      wasSuspended: true,
      isSuspended: false,
      focusedTabID: focused
    )

    #expect(result == focused)
  }

  @Test func returnsNilWhenFocusRemainsSuspended() {
    let focused = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!)

    let result = canvasRestoredFocusTabID(
      wasSuspended: true,
      isSuspended: true,
      focusedTabID: focused
    )

    #expect(result == nil)
  }

  @Test func returnsNilWhenSuspensionDidNotChange() {
    let focused = TerminalTabID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!)

    let result = canvasRestoredFocusTabID(
      wasSuspended: false,
      isSuspended: false,
      focusedTabID: focused
    )

    #expect(result == nil)
  }

  @Test func returnsNilWhenNoFocusedTabExistsToRestore() {
    let result = canvasRestoredFocusTabID(
      wasSuspended: true,
      isSuspended: false,
      focusedTabID: nil
    )

    #expect(result == nil)
  }
}
