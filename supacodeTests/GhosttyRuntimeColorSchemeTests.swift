import GhosttyKit
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

  @Test func initialColorSchemeIsAvailableForSurfaceConfigRefresh() {
    let runtime = GhosttyRuntime(initialColorScheme: .dark)

    #expect(runtime.currentSurfaceRefreshColorSchemeForTesting == GHOSTTY_COLOR_SCHEME_DARK)
  }

  @Test func persistentRuntimeOverridesSurviveDynamicOverrideComposition() {
    let runtime = GhosttyRuntime(persistentRuntimeOverrideContents: "macos-option-as-alt = true")

    #expect(
      runtime.runtimeOverrideContents(appending: "background-opacity = 1")
        == "macos-option-as-alt = true\nbackground-opacity = 1"
    )
  }

  @Test func persistentOptionAsAltOverrideIsAppliedToGhosttyConfig() throws {
    let runtime = GhosttyRuntime(persistentRuntimeOverrideContents: "macos-option-as-alt = true")
    let config = try #require(runtime.config)
    let key = "macos-option-as-alt"
    var optionAsAlt: UnsafePointer<CChar>?

    #expect(ghostty_config_get(config, &optionAsAlt, key, UInt(key.lengthOfBytes(using: .utf8))))
    #expect(optionAsAlt.map(String.init(cString:)) == "true")
  }
}
