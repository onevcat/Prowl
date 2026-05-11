import SwiftUI
import Testing

import GhosttyKit
@testable import supacode

@MainActor
struct GhosttyRuntimeColorSchemeTests {
  @Test func initialColorSchemeIsAppliedBeforeSurfacesAreRegistered() {
    let runtime = GhosttyRuntime(initialColorScheme: .dark)

    #expect(runtime.appliedColorSchemeForTesting == .dark)
  }

  @Test func missingInitialColorSchemeLeavesRuntimeUnspecified() {
    let runtime = GhosttyRuntime()

    #expect(runtime.appliedColorSchemeForTesting == nil)
  }

  @Test func initialColorSchemeIsAvailableForSurfaceConfigRefresh() {
    let runtime = GhosttyRuntime(initialColorScheme: .dark)

    #expect(runtime.currentSurfaceRefreshColorSchemeForTesting == GHOSTTY_COLOR_SCHEME_DARK)
  }
}
