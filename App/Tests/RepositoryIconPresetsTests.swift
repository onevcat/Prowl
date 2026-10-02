import AppKit
import Testing

@testable import supacode

struct RepositoryIconPresetsTests {
  @Test func presetsCountIsForty() {
    // Picker grid is 8 columns wide and we want full rows. Pinning
    // the count here catches accidental drops or duplicates during
    // refactors.
    #expect(RepositoryIconPresets.presets.count == 40)
  }

  @Test func presetsAreUnique() {
    let unique = Set(RepositoryIconPresets.presets)
    #expect(unique.count == RepositoryIconPresets.presets.count)
  }

  @Test func presetsHaveNoEmptyEntries() {
    for symbol in RepositoryIconPresets.presets {
      #expect(!symbol.isEmpty)
    }
  }

  @Test func everyPresetResolvesToARealSFSymbolOnThisOS() {
    // Catches a regression where a preset is added with a name like
    // `rocket.fill` that *looks* plausible but doesn't actually exist
    // (only `rocket` does, no `.fill` variant). A missing symbol
    // would render as a blank tile in the picker grid — invisible
    // bug. Run on the test machine's macOS, which is at least the
    // project's minimum (macOS 26+ per CLAUDE.md).
    let missing =
      RepositoryIconPresets.presets
      .filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) == nil }
    #expect(missing.isEmpty, "Unrecognized SF Symbols in presets: \(missing)")
  }
}
