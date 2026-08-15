import Foundation
import Testing

@testable import supacode

@MainActor
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

  @Test func cleanProfileTreatsOptionAsTerminalAlt() {
    #expect(AppLaunchProfile.clean.ghosttyRuntimeOverrideContents == "macos-option-as-alt = true")
  }

  @Test func standardProfilePreservesUserOptionBehavior() {
    #expect(AppLaunchProfile.standard(initialViewMode: .normal).ghosttyRuntimeOverrideContents.isEmpty)
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

  @Test func cleanSelectionDoesNotConstructStandardOnlyDependencies() {
    var repositoryFactoryCount = 0
    var tmuxFactoryCount = 0
    var cliFactoryCount = 0
    var cleanFactoryCount = 0

    let selection = AppRuntimeSelector.make(
      profile: .clean,
      makeStandard: { _ in
        repositoryFactoryCount += 1
        tmuxFactoryCount += 1
        cliFactoryCount += 1
        return "standard"
      },
      makeClean: {
        cleanFactoryCount += 1
        return "clean"
      }
    )

    let cleanValue: String
    switch selection {
    case .standard:
      Issue.record("Clean profile selected the Standard runtime")
      return
    case .clean(let value):
      cleanValue = value
    }
    #expect(cleanValue == "clean")
    #expect(cleanFactoryCount == 1)
    #expect(repositoryFactoryCount == 0)
    #expect(tmuxFactoryCount == 0)
    #expect(cliFactoryCount == 0)
  }

  @Test(
    arguments: [
      (AppLaunchProfile.standard(initialViewMode: .normal), StandardViewMode.normal),
      (AppLaunchProfile.standard(initialViewMode: .shelf), StandardViewMode.shelf),
      (AppLaunchProfile.standard(initialViewMode: .canvas), StandardViewMode.canvas),
    ]
  )
  func standardSelectionForwardsInitialViewMode(
    profile: AppLaunchProfile,
    expectedMode: StandardViewMode
  ) {
    var cleanFactoryCount = 0
    let selection = AppRuntimeSelector.make(
      profile: profile,
      makeStandard: { $0 },
      makeClean: {
        cleanFactoryCount += 1
        return StandardViewMode.normal
      }
    )

    let selectedMode: StandardViewMode
    switch selection {
    case .standard(let mode):
      selectedMode = mode
    case .clean:
      Issue.record("Standard profile selected the Clean runtime")
      return
    }
    #expect(selectedMode == expectedMode)
    #expect(cleanFactoryCount == 0)
  }

  @Test func standardStateKeepsLaunchViewAfterSettingsChange() {
    var settings = SettingsFeature.State()
    settings.defaultViewMode = .canvas
    var state = AppFeature.State(settings: settings)

    state.settings.defaultViewMode = .normal

    #expect(state.initialViewMode == .canvas)
    #expect(state.settings.defaultViewMode == .normal)
  }
}
