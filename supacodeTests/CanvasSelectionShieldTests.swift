import Testing

@testable import supacode

struct CanvasSelectionShieldTests {
  @Test func commandClickLeavesSelectionShieldHidden() {
    #expect(
      !shouldShowCanvasSelectionShield(
        selectionModifierPressed: false,
        isSelecting: false,
        isBroadcasting: false,
        isPrimaryTab: true
      )
    )
  }

  @Test func optionClickShowsSelectionShield() {
    #expect(
      shouldShowCanvasSelectionShield(
        selectionModifierPressed: true,
        isSelecting: false,
        isBroadcasting: false,
        isPrimaryTab: true
      )
    )
  }

  @Test func nonPrimaryBroadcastTabStillUsesSelectionShield() {
    #expect(
      shouldShowCanvasSelectionShield(
        selectionModifierPressed: false,
        isSelecting: false,
        isBroadcasting: true,
        isPrimaryTab: false
      )
    )
  }

  @Test func unfocusedTerminalContentShowsFocusTapOverlay() {
    #expect(shouldShowCanvasTerminalFocusTapOverlay(isFocused: false, showsSelectionShield: false))
    #expect(!shouldShowCanvasTerminalFocusTapOverlay(isFocused: true, showsSelectionShield: false))
    #expect(!shouldShowCanvasTerminalFocusTapOverlay(isFocused: false, showsSelectionShield: true))
  }
}
