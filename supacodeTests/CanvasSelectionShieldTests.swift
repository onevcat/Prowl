import Testing

@testable import supacode

struct CanvasSelectionShieldTests {
  @Test func commandClickWithoutLinkKeepsSelectionShield() {
    #expect(
      shouldShowCanvasSelectionShield(
        commandKeyPressed: true,
        isSelecting: false,
        isBroadcasting: false,
        isPrimaryTab: true,
        mouseOverLink: nil
      )
    )
  }

  @Test func commandClickOverLinkBypassesSelectionShieldForPrimaryTab() {
    #expect(
      !shouldShowCanvasSelectionShield(
        commandKeyPressed: true,
        isSelecting: false,
        isBroadcasting: false,
        isPrimaryTab: true,
        mouseOverLink: "https://example.com"
      )
    )
  }

  @Test func nonPrimaryBroadcastTabStillUsesSelectionShieldOverLink() {
    #expect(
      shouldShowCanvasSelectionShield(
        commandKeyPressed: true,
        isSelecting: false,
        isBroadcasting: true,
        isPrimaryTab: false,
        mouseOverLink: "https://example.com"
      )
    )
  }
}
