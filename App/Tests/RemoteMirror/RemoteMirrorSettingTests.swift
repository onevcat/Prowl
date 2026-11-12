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

  @Test func listenerStartAtLaunchIsOffByDefaultAndSurvivesCoding() throws {
    #expect(!GlobalSettings.default.remoteMirrorStartsHostOnLaunch)
    var settings = GlobalSettings.default
    settings.remoteMirrorStartsHostOnLaunch = true
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(GlobalSettings.self, from: data).remoteMirrorStartsHostOnLaunch)
    var dictionary = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    dictionary.removeValue(forKey: "remoteMirrorStartsHostOnLaunch")
    let older = try JSONSerialization.data(withJSONObject: dictionary)
    #expect(!(try JSONDecoder().decode(GlobalSettings.self, from: older).remoteMirrorStartsHostOnLaunch))
  }

  @Test func listenOptionsNameInterfacesAndKeepASavedCustomAddress() {
    let interfaces = [
      MirrorNetworkInterface(
        name: "en0", displayName: "Wi-Fi", address: "192.168.1.20", isIPv4: true, isLoopback: false),
      MirrorNetworkInterface(name: "lo0", displayName: nil, address: "127.0.0.1", isIPv4: true, isLoopback: true),
      MirrorNetworkInterface(name: "en0", displayName: "Wi-Fi", address: "fe80::1", isIPv4: false, isLoopback: false),
    ]
    let standard = MirrorListenOption.options(interfaces: interfaces, current: "0.0.0.0")
    #expect(standard.map(\.address) == ["0.0.0.0", "192.168.1.20", "127.0.0.1"])
    #expect(standard[1].label == "Wi-Fi · 192.168.1.20")
    let custom = MirrorListenOption.options(interfaces: interfaces, current: "10.0.0.9")
    #expect(custom.last == MirrorListenOption(address: "10.0.0.9", label: "Custom · 10.0.0.9"))
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
