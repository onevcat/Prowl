import Foundation
import Testing

@testable import supacode

struct AppLaunchProfileTests {
  @Test(
    arguments: [
      (DefaultViewMode.normal, AppLaunchProfile.standard(initialViewMode: .normal)),
      (DefaultViewMode.shelf, AppLaunchProfile.standard(initialViewMode: .shelf)),
      (DefaultViewMode.canvas, AppLaunchProfile.standard(initialViewMode: .canvas)),
      (DefaultViewMode.clean, AppLaunchProfile.clean),
    ]
  )
  func resolvesStoredViewMode(
    mode: DefaultViewMode,
    expectedProfile: AppLaunchProfile
  ) {
    #expect(AppLaunchProfile.resolve(mode) == expectedProfile)
  }

  @Test(arguments: DefaultViewMode.allCases)
  func storedViewModeCodableRoundTrips(mode: DefaultViewMode) throws {
    let encoded = try JSONEncoder().encode(mode)
    let decoded = try JSONDecoder().decode(DefaultViewMode.self, from: encoded)

    #expect(String(decoding: encoded, as: UTF8.self) == #""\#(mode.rawValue)""#)
    #expect(decoded == mode)
  }

  @Test func legacySettingsWithoutDefaultViewModeUseNormal() throws {
    let encodedSettings = try JSONEncoder().encode(GlobalSettings.default)
    var legacySettings = try #require(
      JSONSerialization.jsonObject(with: encodedSettings) as? [String: Any]
    )
    legacySettings.removeValue(forKey: "defaultViewMode")
    let legacyData = try JSONSerialization.data(withJSONObject: legacySettings)
    let settings = try JSONDecoder().decode(GlobalSettings.self, from: legacyData)

    #expect(settings.defaultViewMode == .normal)
  }
}
