import Foundation
import Testing

@testable import supacode

struct RepositoryColorChoiceTests {
  @Test func paletteHasTenSystemColors() {
    // The fixed palette is part of the persistence contract: once
    // shipped, removing or renaming a preset would break user JSON. This
    // test pins the count so an accidental rename or removal trips a
    // failure before release.
    #expect(RepositoryColorChoice.presets.count == 10)
  }

  @Test func presetCaseNamesAreStable() throws {
    // Presets encode as their bare case-name string (the legacy raw value);
    // reordering `presets` is fine but case names are forever. Pin them by
    // checking the encoded string for each preset.
    let encoder = JSONEncoder()
    let names = try RepositoryColorChoice.presets.map { choice -> String in
      try JSONDecoder().decode(String.self, from: encoder.encode(choice))
    }
    .sorted()
    #expect(
      names == [
        "blue",
        "cyan",
        "gray",
        "green",
        "mint",
        "orange",
        "pink",
        "purple",
        "red",
        "yellow",
      ]
    )
  }

  @Test func presetCodableRoundTrip() throws {
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    for choice in RepositoryColorChoice.presets {
      let data = try encoder.encode(choice)
      let decoded = try decoder.decode(RepositoryColorChoice.self, from: data)
      #expect(decoded == choice)
    }
  }

  @Test func displayNameNonEmpty() {
    for choice in RepositoryColorChoice.presets + [.custom(.default)] {
      #expect(!choice.displayName.isEmpty)
    }
  }

  // MARK: - Custom color

  @Test func customDisplayNameIsCustom() {
    #expect(RepositoryColorChoice.custom(.default).displayName == "Custom")
  }

  @Test func legacyStringDecodesToPreset() throws {
    let data = Data("\"green\"".utf8)
    let decoded = try JSONDecoder().decode(RepositoryColorChoice.self, from: data)
    #expect(decoded == .green)
  }

  @Test func customRoundTrips() throws {
    let original = RepositoryColorChoice.custom(TintColor(red: 0.1, green: 0.2, blue: 0.3))
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(RepositoryColorChoice.self, from: data)
    #expect(decoded == original)
  }

  @Test func customEncodesAsObjectNotABareString() throws {
    let data = try JSONEncoder().encode(RepositoryColorChoice.custom(.default))
    // A custom color must not be mistaken for a preset case-name string.
    #expect((try? JSONDecoder().decode(String.self, from: data)) == nil)
  }

  @Test func repositoryAppearanceRoundTripsWithCustomColor() throws {
    let appearance = RepositoryAppearance(color: .custom(TintColor(red: 0.5, green: 0.6, blue: 0.7)))
    let data = try JSONEncoder().encode(appearance)
    let decoded = try JSONDecoder().decode(RepositoryAppearance.self, from: data)
    #expect(decoded == appearance)
  }

  @Test func legacyRepositoryAppearanceWithStringColorStillDecodes() throws {
    let data = Data(#"{"color":"red"}"#.utf8)
    let decoded = try JSONDecoder().decode(RepositoryAppearance.self, from: data)
    #expect(decoded.color == .red)
  }
}
