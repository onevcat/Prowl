import Foundation
import Testing

@testable import supacode

struct WorktreeTerminalStateTests {
  @Test func resolveInheritancePrefersExplicitSurface() {
    let explicit = UUID()
    let focused = UUID()

    let resolved = WorktreeTerminalState.resolveInheritanceSurfaceID(
      inheritingFromSurfaceId: explicit,
      focusedSurfaceId: focused,
      inheritFromFocusedSurface: false
    )

    #expect(resolved == explicit)
  }

  @Test func resolveInheritanceUsesFocusedSurfaceWhenEnabled() {
    let focused = UUID()

    let resolved = WorktreeTerminalState.resolveInheritanceSurfaceID(
      inheritingFromSurfaceId: nil,
      focusedSurfaceId: focused,
      inheritFromFocusedSurface: true
    )

    #expect(resolved == focused)
  }

  @Test func resolveInheritanceIgnoresFocusedSurfaceWhenDisabled() {
    let focused = UUID()

    let resolved = WorktreeTerminalState.resolveInheritanceSurfaceID(
      inheritingFromSurfaceId: nil,
      focusedSurfaceId: focused,
      inheritFromFocusedSurface: false
    )

    #expect(resolved == nil)
  }
}
