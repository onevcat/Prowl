import Testing

@testable import supacode

struct SidebarFooterViewTests {
  @Test func activeAgentsPanelToggleUsesStableSymbols() {
    #expect(SidebarFooterView.activeAgentsPanelIconName(isPanelHidden: true) == "person.crop.rectangle.stack")
    #expect(SidebarFooterView.activeAgentsPanelIconName(isPanelHidden: false) == "person.crop.rectangle.stack.fill")
  }
}
