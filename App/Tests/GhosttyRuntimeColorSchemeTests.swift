import SwiftUI
import Testing

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
}
