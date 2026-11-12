import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import Prowl

/// The alpha switch of Remote Mirror (docs-ai 091).
@MainActor
struct RemoteMirrorSettingTests {
  @Test func switchIsOffByDefaultAndSurvivesCoding() throws {
    #expect(!GlobalSettings.default.remoteMirrorEnabled)
    var settings = GlobalSettings.default
    settings.remoteMirrorEnabled = true
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(GlobalSettings.self, from: data).remoteMirrorEnabled)
    var dictionary = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    dictionary.removeValue(forKey: "remoteMirrorEnabled")
    let older = try JSONSerialization.data(withJSONObject: dictionary)
    #expect(!(try JSONDecoder().decode(GlobalSettings.self, from: older).remoteMirrorEnabled))
  }

  @Test(.dependencies) func settingsSwitchPersistsAndReportsTheChange() async {
    @Shared(.settingsFile) var settingsFile
    let store = TestStore(initialState: SettingsFeature.State(settings: settingsFile.global)) {
      SettingsFeature()
    }
    await store.send(.binding(.set(\.remoteMirrorEnabled, true))) {
      $0.remoteMirrorEnabled = true
    }
    await store.receive(\.delegate.settingsChanged)
    #expect(settingsFile.global.remoteMirrorEnabled)
  }
}
