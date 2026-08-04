import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

struct SettingsFilePersistenceTests {
  @Test(.dependencies) func loadWritesDefaultsWhenMissing() throws {
    let storage = SettingsTestStorage()

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings == .default)

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(reloaded == .default)
  }

  @Test(.dependencies) func saveAndReload() throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock {
        $0.global.appearanceMode = .dark
        $0.repositoryRoots = ["/tmp/repo-a", "/tmp/repo-b"]
        $0.pinnedWorktreeIDs = ["/tmp/repo-a/wt-1"]
      }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(reloaded.global.appearanceMode == .dark)
    #expect(reloaded.repositoryRoots == ["/tmp/repo-a", "/tmp/repo-b"])
    #expect(reloaded.pinnedWorktreeIDs == ["/tmp/repo-a/wt-1"])
  }

  @Test(.dependencies) func saveAndReloadToolbarAndDockSettings() throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock {
        $0.global.showRunButtonInToolbar = false
        $0.global.showDefaultEditorInToolbar = false
        $0.global.dockBounceMode = .continuous
        $0.global.showNotificationDotOnDock = true
      }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(reloaded.global.showRunButtonInToolbar == false)
    #expect(reloaded.global.showDefaultEditorInToolbar == false)
    #expect(reloaded.global.dockBounceMode == .continuous)
    #expect(reloaded.global.showNotificationDotOnDock == true)
  }

  @Test(.dependencies) func saveAndReloadShelfSpineTintPreferences() throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock {
        $0.global.shelfSpineTintFallback = .systemTint
        $0.global.shelfSpineTintFollowsRepositoryColor = false
        $0.global.showActiveAgentStatusInShelf = false
      }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(reloaded.global.shelfSpineTintFallback == .systemTint)
    #expect(reloaded.global.shelfSpineTintFollowsRepositoryColor == false)
    #expect(reloaded.global.showActiveAgentStatusInShelf == false)
  }

  @Test(.dependencies) func invalidJSONResetsToDefaults() throws {
    let storage = MutableTestStorage(initialData: Data("{".utf8))

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings == .default)

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(reloaded == .default)
  }

  @Test(.dependencies) func decodesMissingInAppNotificationsEnabled() throws {
    let legacy = LegacySettingsFile(
      global: LegacyGlobalSettings(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: false,
        updatesAutomaticallyDownloadUpdates: true
      ),
      repositories: [:]
    )
    let data = try JSONEncoder().encode(legacy)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.appearanceMode == .dark)
    #expect(settings.global.confirmBeforeQuit == true)
    #expect(settings.global.updatesAutomaticallyCheckForUpdates == false)
    #expect(settings.global.updatesAutomaticallyDownloadUpdates == true)
    #expect(settings.global.inAppNotificationsEnabled == true)
    // Missing key (pre-feature file) decodes to the default sound.
    #expect(settings.global.notificationSound == .supacodeClassic)
    #expect(settings.global.systemNotificationsEnabled == false)
    #expect(settings.global.moveNotifiedWorktreeToTop == true)
    #expect(settings.global.analyticsEnabled == true)
    #expect(settings.global.crashReportsEnabled == true)
    #expect(settings.global.githubIntegrationEnabled == true)
    #expect(settings.global.deleteBranchOnAutomaticCleanup == false)
    #expect(settings.global.mergedWorktreeAction == nil)
    #expect(settings.global.promptForWorktreeCreation == true)
    #expect(settings.global.defaultWorktreeBaseDirectoryPath == nil)
    #expect(settings.global.restoreTerminalLayoutOnLaunch == false)
    #expect(settings.global.defaultEditorID == OpenWorktreeAction.automaticSettingsID)
    #expect(settings.global.showRunButtonInToolbar == true)
    #expect(settings.global.showDefaultEditorInToolbar == true)
    #expect(settings.global.dockBounceMode == .off)
    #expect(settings.global.showNotificationDotOnDock == false)
    #expect(settings.global.showActiveAgentStatusInShelf == true)
    #expect(settings.global.shelfSpineTintFallback == .neutral)
    #expect(settings.global.shelfSpineTintFollowsRepositoryColor == true)
    // Absent from legacy payloads → falls back to the new Tile default.
    #expect(settings.global.canvasDefaultLayout == .tile)
    #expect(settings.repositoryRoots.isEmpty)
    #expect(settings.pinnedWorktreeIDs.isEmpty)
  }

  @Test(.dependencies) func legacyAutomaticallyArchiveMergedWorktreesMigratesToMergedWorktreeAction() throws {
    let legacy = LegacyAutoArchiveSettingsFile(
      global: LegacyAutoArchiveGlobalSettings(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: false,
        updatesAutomaticallyDownloadUpdates: true,
        automaticallyArchiveMergedWorktrees: true
      ),
      repositories: [:]
    )
    let data = try JSONEncoder().encode(legacy)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.mergedWorktreeAction == .archive)
  }

  @Test(.dependencies) func legacyAutomaticallyArchiveFalseMigratesToNil() throws {
    let legacy = LegacyAutoArchiveSettingsFile(
      global: LegacyAutoArchiveGlobalSettings(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: false,
        updatesAutomaticallyDownloadUpdates: true,
        automaticallyArchiveMergedWorktrees: false
      ),
      repositories: [:]
    )
    let data = try JSONEncoder().encode(legacy)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.mergedWorktreeAction == nil)
  }

  @Test(.dependencies) func legacyDeleteBranchOnDeleteWorktreeMigratesToAutomaticCleanup() throws {
    // Files written before the setting was split carry only the legacy key;
    // an opted-in user keeps branch deletion during automatic cleanup.
    let encoded = try JSONEncoder().encode(GlobalSettings.default)
    var globalDict = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    globalDict.removeValue(forKey: "deleteBranchOnAutomaticCleanup")
    globalDict["deleteBranchOnDeleteWorktree"] = true
    let data = try JSONSerialization.data(withJSONObject: ["global": globalDict, "repositories": [:]])
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.deleteBranchOnAutomaticCleanup == true)
  }

  @Test(.dependencies) func explicitDeleteBranchOnAutomaticCleanupWinsOverLegacyKey() throws {
    let encoded = try JSONEncoder().encode(GlobalSettings.default)
    var globalDict = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    globalDict["deleteBranchOnAutomaticCleanup"] = false
    globalDict["deleteBranchOnDeleteWorktree"] = true
    let data = try JSONSerialization.data(withJSONObject: ["global": globalDict, "repositories": [:]])
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.deleteBranchOnAutomaticCleanup == false)
  }

  @Test func encodesAutomaticCleanupSettingWithoutLegacyKey() throws {
    var settings = GlobalSettings.default
    settings.deleteBranchOnAutomaticCleanup = true

    let encoded = try JSONEncoder().encode(settings)
    let globalDict = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    #expect(globalDict["deleteBranchOnAutomaticCleanup"] as? Bool == true)
    #expect(globalDict["deleteBranchOnDeleteWorktree"] == nil)
  }

  @Test(.dependencies) func roundTripsExplicitNotificationSound() throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock { $0.global.notificationSound = .submarine }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var reloaded: SettingsFile
      return reloaded
    }

    // An explicitly chosen sound must survive a save / reload round-trip.
    #expect(reloaded.global.notificationSound == .submarine)
  }

  @Test(.dependencies) func migratesLegacyNotificationSoundEnabledFalseToNever() throws {
    // A pre-picker file with the sound explicitly muted must stay muted, not
    // resurface as the default sound on upgrade.
    let legacy = LegacySettingsFileWithSoundToggle(
      global: LegacyGlobalSettingsWithSoundToggle(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: true,
        updatesAutomaticallyDownloadUpdates: false,
        notificationSoundEnabled: false
      ),
      repositories: [:]
    )
    let data = try JSONEncoder().encode(legacy)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.notificationSound == .never)
  }

  @Test(.dependencies) func migratesLegacyNotificationSoundEnabledTrueToDefault() throws {
    // Symmetric to the `false` case: the sound was on, so it folds to the
    // classic chime — what those users were already hearing.
    let legacy = LegacySettingsFileWithSoundToggle(
      global: LegacyGlobalSettingsWithSoundToggle(
        appearanceMode: .dark,
        updatesAutomaticallyCheckForUpdates: true,
        updatesAutomaticallyDownloadUpdates: false,
        notificationSoundEnabled: true
      ),
      repositories: [:]
    )
    let data = try JSONEncoder().encode(legacy)
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.notificationSound == .supacodeClassic)
  }

  @Test(.dependencies) func decodesUnrecognizedNotificationSoundAsDefaultWithoutResettingSiblings() throws {
    // A hand-edited or downgraded file carrying a sound case this build doesn't
    // know yet. The `try?` must isolate the fallback to this one field.
    var global = GlobalSettings.default
    global.appearanceMode = .dark
    global.systemNotificationsEnabled = true
    global.updatesAutomaticallyDownloadUpdates = true

    let encoded = try JSONEncoder().encode(global)
    var globalDict = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    globalDict["notificationSound"] = "futureSoundFromNewerBuild"
    let data = try JSONSerialization.data(withJSONObject: ["global": globalDict, "repositories": [:]])
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    // The unknown sound falls back to the default...
    #expect(settings.global.notificationSound == .supacodeClassic)
    // ...but the rest of the file survives. This is what `try?` buys over `try`.
    #expect(settings.global.appearanceMode == .dark)
    #expect(settings.global.systemNotificationsEnabled == true)
    #expect(settings.global.updatesAutomaticallyDownloadUpdates == true)
  }

  @Test(.dependencies) func saveAndReloadMinimumTextSize() throws {
    let storage = SettingsTestStorage()

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      $settings.withLock {
        $0.global.minimumTextSize = .points12
      }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(reloaded.global.minimumTextSize == .points12)
  }

  @Test(.dependencies) func decodesUnrecognizedMinimumTextSizeAsDefaultWithoutResettingSiblings() throws {
    var global = GlobalSettings.default
    global.appearanceMode = .dark
    global.systemNotificationsEnabled = true

    let encoded = try JSONEncoder().encode(global)
    var globalDict = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    globalDict["minimumTextSize"] = "futureSizeFromNewerBuild"
    let data = try JSONSerialization.data(withJSONObject: ["global": globalDict, "repositories": [:]])
    let storage = MutableTestStorage(initialData: data)

    let settings: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(settings.global.minimumTextSize == .system)
    #expect(settings.global.appearanceMode == .dark)
    #expect(settings.global.systemNotificationsEnabled == true)
  }
}

nonisolated private final class MutableTestStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  private let initialData: Data

  init(initialData: Data) {
    self.initialData = initialData
  }

  var storage: SettingsFileStorage {
    SettingsFileStorage(
      load: { try self.load($0) },
      save: { try self.save($0, $1) }
    )
  }

  private func load(_ url: URL) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    if let data {
      return data
    }
    return initialData
  }

  private func save(_ data: Data, _ url: URL) throws {
    lock.lock()
    defer { lock.unlock() }
    self.data = data
  }
}

private struct LegacyAutoArchiveSettingsFile: Codable {
  var global: LegacyAutoArchiveGlobalSettings
  var repositories: [String: RepositorySettings]
}

private struct LegacyAutoArchiveGlobalSettings: Codable {
  var appearanceMode: AppearanceMode
  var updatesAutomaticallyCheckForUpdates: Bool
  var updatesAutomaticallyDownloadUpdates: Bool
  var automaticallyArchiveMergedWorktrees: Bool
}

private struct LegacySettingsFileWithSoundToggle: Codable {
  var global: LegacyGlobalSettingsWithSoundToggle
  var repositories: [String: RepositorySettings]
}

private struct LegacyGlobalSettingsWithSoundToggle: Codable {
  var appearanceMode: AppearanceMode
  var updatesAutomaticallyCheckForUpdates: Bool
  var updatesAutomaticallyDownloadUpdates: Bool
  var notificationSoundEnabled: Bool
}

private struct LegacySettingsFile: Codable {
  var global: LegacyGlobalSettings
  var repositories: [String: RepositorySettings]
}

private struct LegacyGlobalSettings: Codable {
  var appearanceMode: AppearanceMode
  var updatesAutomaticallyCheckForUpdates: Bool
  var updatesAutomaticallyDownloadUpdates: Bool
}
