import GhosttyKit
import Testing

@testable import supacode

struct WorktreeTerminalStateFontSizeTests {
  @Test func tabContextUsesDefaultFontSizeOnly() {
    let resolvedWithDefault = WorktreeTerminalState.resolvedFontSizeForNewSurface(
      defaultFontSize: 14,
      inheritedFontSize: 18,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
    #expect(resolvedWithDefault == 14)

    let resolvedWithoutDefault = WorktreeTerminalState.resolvedFontSizeForNewSurface(
      defaultFontSize: nil,
      inheritedFontSize: 18,
      context: GHOSTTY_SURFACE_CONTEXT_TAB
    )
    #expect(resolvedWithoutDefault == nil)
  }

  @Test func splitContextPrefersInheritedFontSize() {
    let resolvedWithInherited = WorktreeTerminalState.resolvedFontSizeForNewSurface(
      defaultFontSize: 14,
      inheritedFontSize: 18,
      context: GHOSTTY_SURFACE_CONTEXT_SPLIT
    )
    #expect(resolvedWithInherited == 18)

    let resolvedWithoutInherited = WorktreeTerminalState.resolvedFontSizeForNewSurface(
      defaultFontSize: 14,
      inheritedFontSize: nil,
      context: GHOSTTY_SURFACE_CONTEXT_SPLIT
    )
    #expect(resolvedWithoutInherited == 14)
  }
}
