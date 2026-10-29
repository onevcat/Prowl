import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import Prowl

struct SidebarLayoutKeyTests {
  @Test(.dependencies) func aMissingFileMigratesTheLegacyRepositoryOrder() {
    let storage = SettingsTestStorage()
    let url = URL(fileURLWithPath: "/tmp/sidebar-layout-\(UUID().uuidString).json")
    let defaults = UserDefaults(suiteName: "SidebarLayoutKeyTests-\(UUID().uuidString)")!
    defaults.set(["/tmp/b", "/tmp/a"], forKey: "repositoryOrderIDs")

    let layout: SidebarLayout = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.sidebarLayoutFileURL = url
      $0.defaultAppStorage = defaults
    } operation: {
      @Shared(.sidebarLayout) var layout
      return layout
    }

    #expect(layout == SidebarLayout(repositoryIDs: ["/tmp/b", "/tmp/a"]))
  }

  @Test(.dependencies) func anUnreadableFileIsKeptAsACopyBeforeTheLegacyFallback() throws {
    let storage = SettingsTestStorage()
    let url = URL(fileURLWithPath: "/tmp/sidebar-layout-\(UUID().uuidString).json")
    let defaults = UserDefaults(suiteName: "SidebarLayoutKeyTests-\(UUID().uuidString)")!
    defaults.set(["/tmp/a"], forKey: "repositoryOrderIDs")
    let unreadable = Data("{\"items\": [".utf8)
    try storage.storage.save(unreadable, url)

    let layout: SidebarLayout = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.sidebarLayoutFileURL = url
      $0.defaultAppStorage = defaults
    } operation: {
      @Shared(.sidebarLayout) var layout
      return layout
    }

    #expect(layout == SidebarLayout(repositoryIDs: ["/tmp/a"]))
    #expect(try storage.storage.load(url.appendingPathExtension("unreadable")) == unreadable)
  }

  @Test(.dependencies) func saveAndReloadRoundTripIgnoresTheLegacyOrder() {
    let storage = SettingsTestStorage()
    let url = URL(fileURLWithPath: "/tmp/sidebar-layout-\(UUID().uuidString).json")
    let defaults = UserDefaults(suiteName: "SidebarLayoutKeyTests-\(UUID().uuidString)")!
    defaults.set(["/tmp/legacy"], forKey: "repositoryOrderIDs")
    let groupID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    let saved = SidebarLayout(items: [
      .group(RepositoryGroup(id: groupID, title: "G", color: .blue, repositoryIDs: ["/tmp/a"])),
      .repository("/tmp/b"),
    ])

    withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.sidebarLayoutFileURL = url
      $0.defaultAppStorage = defaults
    } operation: {
      @Shared(.sidebarLayout) var layout
      $layout.withLock { $0 = saved }
    }

    let reloaded: SidebarLayout = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.sidebarLayoutFileURL = url
      $0.defaultAppStorage = defaults
    } operation: {
      @Shared(.sidebarLayout) var layout
      return layout
    }

    #expect(reloaded == saved)
  }
}
