import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import Prowl

struct RepositorySettingsKeyTests {
  @Test func encodingOmitsNilWorktreeBaseRef() throws {
    let data = try JSONEncoder().encode(RepositorySettings.default)
    let json = String(bytes: data, encoding: .utf8) ?? ""

    #expect(!json.contains("worktreeBaseRef"))
    #expect(!json.contains("worktreeBaseDirectoryPath"))
  }

  @Test(.dependencies) func loadCreatesDefaultAndPersists() throws {
    let storage = SettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")

    let settings = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      return repositorySettings
    }

    #expect(settings == RepositorySettings.default)

    let saved: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(
      saved.repositories[rootURL.path(percentEncoded: false)] == RepositorySettings.default
    )
  }

  @Test(.dependencies) func saveOverwritesExistingSettings() throws {
    let storage = SettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")

    var updated = RepositorySettings.default
    updated.runScript = "echo updated"

    withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      $repositorySettings.withLock {
        $0 = updated
      }
    }

    let reloaded: SettingsFile = withDependencies {
      $0.settingsFileStorage = storage.storage
    } operation: {
      @Shared(.settingsFile) var settings: SettingsFile
      return settings
    }

    #expect(reloaded.repositories[rootURL.path(percentEncoded: false)] == updated)
  }

  @Test func decodeMissingArchiveScriptDefaultsToEmpty() throws {
    let data = Data(
      """
      {
        "setupScript": "echo setup",
        "runScript": "echo run",
        "openActionID": "automatic"
      }
      """.utf8
    )
    let settings = try JSONDecoder().decode(RepositorySettings.self, from: data)

    #expect(settings.archiveScript.isEmpty)
  }

  @Test(.dependencies) func loadNormalizesLegacyDefaultOverridesToInheritedValues() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/prowl-settings-\(UUID().uuidString).json")
    let localURL = ProwlPaths.repositorySettingsURL(for: rootURL)
    let legacyData = Data(
      """
      {
        "setupScript": "",
        "archiveScript": "",
        "runScript": "echo run",
        "openActionID": "automatic",
        "copyIgnoredOnWorktreeCreate": false,
        "copyUntrackedOnWorktreeCreate": true,
        "pullRequestMergeStrategy": "merge"
      }
      """.utf8
    )

    try localStorage.save(legacyData, at: localURL)

    let loaded = withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      return repositorySettings
    }

    #expect(loaded.copyIgnoredOnWorktreeCreate == nil)
    #expect(loaded.copyUntrackedOnWorktreeCreate == true)
    #expect(loaded.pullRequestMergeStrategy == nil)
  }

  @Test func decodeCurrentSchemaPreservesExplicitDefaultOverrides() throws {
    let settings = RepositorySettings(
      setupScript: "",
      archiveScript: "",
      runScript: "echo run",
      openActionID: OpenWorktreeAction.automaticSettingsID,
      worktreeBaseRef: nil,
      copyIgnoredOnWorktreeCreate: false,
      copyUntrackedOnWorktreeCreate: false,
      pullRequestMergeStrategy: .merge,
    )

    let decoded = try JSONDecoder().decode(RepositorySettings.self, from: encode(settings))

    #expect(decoded.copyIgnoredOnWorktreeCreate == false)
    #expect(decoded.copyUntrackedOnWorktreeCreate == false)
    #expect(decoded.pullRequestMergeStrategy == .merge)
  }

  @Test func decodeMissingObservationOverridesDefaultsToEnabled() throws {
    let data = Data(
      """
      {
        "setupScript": "",
        "archiveScript": "",
        "runScript": "echo run",
        "openActionID": "automatic"
      }
      """.utf8
    )
    let settings = try JSONDecoder().decode(RepositorySettings.self, from: data)

    #expect(settings.observeLineDiffsAutomatically == nil)
    #expect(settings.fetchPullRequestState == nil)
    #expect(settings.observesLineDiffsAutomatically)
    #expect(settings.fetchesPullRequestState)
  }

  @Test func decodePreservesExplicitObservationOverrides() throws {
    var settings = RepositorySettings.default
    settings.observeLineDiffsAutomatically = false
    settings.fetchPullRequestState = false

    let decoded = try JSONDecoder().decode(RepositorySettings.self, from: encode(settings))

    #expect(decoded.observeLineDiffsAutomatically == false)
    #expect(decoded.fetchPullRequestState == false)
    #expect(!decoded.observesLineDiffsAutomatically)
    #expect(!decoded.fetchesPullRequestState)
  }

  @Test(.dependencies) func loadPrefersLocalSettingsFileOverGlobalEntry() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/prowl-settings-\(UUID().uuidString).json")
    let repositoryID = rootURL.standardizedFileURL.path(percentEncoded: false)
    var globalSettings = RepositorySettings.default
    globalSettings.runScript = "echo global"
    var localSettings = RepositorySettings.default
    localSettings.runScript = "echo local"

    withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.settingsFile) var settingsFile: SettingsFile
      $settingsFile.withLock {
        $0.repositories[repositoryID] = globalSettings
      }
    }

    try localStorage.save(
      encode(localSettings),
      at: ProwlPaths.repositorySettingsURL(for: rootURL)
    )

    let loaded = withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      return repositorySettings
    }

    #expect(loaded == localSettings)
  }

  @Test(.dependencies) func loadFallsBackToGlobalWhenLocalMissing() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/prowl-settings-\(UUID().uuidString).json")
    let repositoryID = rootURL.standardizedFileURL.path(percentEncoded: false)
    var globalSettings = RepositorySettings.default
    globalSettings.runScript = "echo global"

    withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.settingsFile) var settingsFile: SettingsFile
      $settingsFile.withLock {
        $0.repositories[repositoryID] = globalSettings
      }
    }

    let loaded = withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      return repositorySettings
    }

    #expect(loaded == globalSettings)
  }

  @Test(.dependencies) func loadFallsBackToGlobalWhenLocalInvalid() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/prowl-settings-\(UUID().uuidString).json")
    let repositoryID = rootURL.standardizedFileURL.path(percentEncoded: false)
    let localURL = ProwlPaths.repositorySettingsURL(for: rootURL)
    var globalSettings = RepositorySettings.default
    globalSettings.runScript = "echo global"

    withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.settingsFile) var settingsFile: SettingsFile
      $settingsFile.withLock {
        $0.repositories[repositoryID] = globalSettings
      }
    }

    try localStorage.save(Data("{".utf8), at: localURL)

    let loaded = withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      return repositorySettings
    }

    #expect(loaded == globalSettings)
  }

  @Test(.dependencies) func loadMigratesLegacyRepositoryRootFile() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/prowl-settings-\(UUID().uuidString).json")
    let localURL = ProwlPaths.repositorySettingsURL(for: rootURL)
    let legacyURL = ProwlPaths.legacyRepositorySettingsURL(for: rootURL)
    var legacySettings = RepositorySettings.default
    legacySettings.runScript = "echo from-legacy"

    try localStorage.save(encode(legacySettings), at: legacyURL)

    let loaded = withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      return repositorySettings
    }

    #expect(loaded == legacySettings)

    let localData = try #require(localStorage.data(at: localURL))
    let localDecoded = try JSONDecoder().decode(RepositorySettings.self, from: localData)
    #expect(localDecoded == legacySettings)
  }

  @Test(.dependencies) func loadCopiesSettingsFromTheBasenameDirectory() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/work-\(UUID().uuidString)/repo")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/prowl-settings-\(UUID().uuidString).json")
    let localURL = ProwlPaths.repositorySettingsURL(for: rootURL)
    let basenameURL = ProwlPaths.legacyRepositorySettingsURLs(for: rootURL)[0]
    var stored = RepositorySettings.default
    stored.runScript = "echo from-basename-directory"
    let storedData = try encode(stored)
    try localStorage.save(storedData, at: basenameURL)

    let loaded = withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      return repositorySettings
    }

    #expect(loaded == stored)
    let copied = try JSONDecoder().decode(RepositorySettings.self, from: #require(localStorage.data(at: localURL)))
    #expect(copied == stored)
    #expect(localStorage.data(at: basenameURL) == storedData)
  }

  @Test(.dependencies) func copyFromTheBasenameDirectoryPreservesItsLinkThroughCreate() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/work-\(UUID().uuidString)/repo")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/prowl-settings-\(UUID().uuidString).json")
    let basenameURL = ProwlPaths.legacyRepositorySettingsURLs(for: rootURL)[0]
    try localStorage.save(encode(.default), at: basenameURL)
    let creations = LockIsolated<[(URL, URL?)]>([])
    var storage = localStorage.storage
    storage.create = { data, url, source in
      creations.withValue { $0.append((url, source)) }
      try localStorage.save(data, at: url)
    }

    withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      _ = repositorySettings
    }

    #expect(creations.value.map(\.0) == [ProwlPaths.repositorySettingsURL(for: rootURL)])
    #expect(creations.value.map(\.1) == [basenameURL])
  }

  @Test(.dependencies) func failedLinkCopyStillWritesTheRepositoryFile() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/work-\(UUID().uuidString)/repo")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/prowl-settings-\(UUID().uuidString).json")
    let localURL = ProwlPaths.repositorySettingsURL(for: rootURL)
    try localStorage.save(encode(.default), at: ProwlPaths.legacyRepositorySettingsURLs(for: rootURL)[0])
    var storage = localStorage.storage
    storage.create = { _, _, _ in throw CocoaError(.fileWriteFileExists) }

    withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      $repositorySettings.withLock { $0.runScript = "echo edited" }
    }

    let saved = try JSONDecoder().decode(RepositorySettings.self, from: #require(localStorage.data(at: localURL)))
    #expect(saved.runScript == "echo edited")
  }

  @Test(.dependencies) func editAfterAFailedCopyGoesToTheRepositoryFile() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/work-\(UUID().uuidString)/repo")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/prowl-settings-\(UUID().uuidString).json")
    let localURL = ProwlPaths.repositorySettingsURL(for: rootURL)
    let repositoryID = rootURL.standardizedFileURL.path(percentEncoded: false)
    var legacy = RepositorySettings.default
    legacy.runScript = "echo legacy"
    try localStorage.save(encode(legacy), at: ProwlPaths.legacyRepositorySettingsURLs(for: rootURL)[0])
    let writesFail = LockIsolated(true)
    var storage = localStorage.storage
    storage.save = { data, url in
      if writesFail.value { throw CocoaError(.fileWriteOutOfSpace) }
      try localStorage.save(data, at: url)
    }
    storage.create = { _, _, _ in throw CocoaError(.fileWriteOutOfSpace) }

    withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      #expect(repositorySettings == legacy)
      writesFail.setValue(false)
      $repositorySettings.withLock { $0.runScript = "echo edited" }
      @Shared(.settingsFile) var settingsFile: SettingsFile
      #expect(settingsFile.repositories[repositoryID] == nil)
    }

    let saved = try JSONDecoder().decode(RepositorySettings.self, from: #require(localStorage.data(at: localURL)))
    #expect(saved.runScript == "echo edited")
  }

  @Test(.dependencies) func repositoriesWithOneBasenameSplitAfterTheCopy() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let run = UUID().uuidString
    let firstRoot = URL(fileURLWithPath: "/tmp/first-\(run)/repo")
    let secondRoot = URL(fileURLWithPath: "/tmp/second-\(run)/repo")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/prowl-settings-\(run).json")
    let sharedURL = ProwlPaths.legacyRepositorySettingsURLs(for: firstRoot)[0]
    #expect(sharedURL == ProwlPaths.legacyRepositorySettingsURLs(for: secondRoot)[0])
    var shared = RepositorySettings.default
    shared.runScript = "echo shared"
    let sharedData = try encode(shared)
    try localStorage.save(sharedData, at: sharedURL)

    withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.repositorySettings(firstRoot)) var first: RepositorySettings
      @Shared(.repositorySettings(secondRoot)) var second: RepositorySettings
      #expect(first == shared)
      #expect(second == shared)
      $first.withLock { $0.runScript = "echo first" }
    }

    let firstSaved = try JSONDecoder().decode(
      RepositorySettings.self, from: #require(localStorage.data(at: ProwlPaths.repositorySettingsURL(for: firstRoot))))
    let secondSaved = try JSONDecoder().decode(
      RepositorySettings.self, from: #require(localStorage.data(at: ProwlPaths.repositorySettingsURL(for: secondRoot))))
    #expect(firstSaved.runScript == "echo first")
    #expect(secondSaved == shared)
    #expect(localStorage.data(at: sharedURL) == sharedData)
  }

  @Test(.dependencies) func saveWritesLocalWhenLocalFileExists() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/prowl-settings-\(UUID().uuidString).json")
    let repositoryID = rootURL.standardizedFileURL.path(percentEncoded: false)
    let localURL = ProwlPaths.repositorySettingsURL(for: rootURL)

    try localStorage.save(encode(.default), at: localURL)

    var updated = RepositorySettings.default
    updated.runScript = "echo local"

    withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      $repositorySettings.withLock {
        $0 = updated
      }
    }

    let localData = try #require(localStorage.data(at: localURL))
    let localDecoded = try JSONDecoder().decode(RepositorySettings.self, from: localData)
    #expect(localDecoded == updated)

    let globalSaved: SettingsFile = withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.settingsFile) var settingsFile: SettingsFile
      return settingsFile
    }

    #expect(globalSaved.repositories[repositoryID] == nil)
  }

  @Test(.dependencies) func saveWritesGlobalWhenLocalFileMissing() throws {
    let globalStorage = SettingsTestStorage()
    let localStorage = RepositoryLocalSettingsTestStorage()
    let rootURL = URL(fileURLWithPath: "/tmp/repo")
    let settingsFileURL = URL(fileURLWithPath: "/tmp/prowl-settings-\(UUID().uuidString).json")
    let repositoryID = rootURL.standardizedFileURL.path(percentEncoded: false)
    let localURL = ProwlPaths.repositorySettingsURL(for: rootURL)

    var updated = RepositorySettings.default
    updated.runScript = "echo global"

    withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.repositorySettings(rootURL)) var repositorySettings: RepositorySettings
      $repositorySettings.withLock {
        $0 = updated
      }
    }

    let globalSaved: SettingsFile = withDependencies {
      $0.settingsFileStorage = globalStorage.storage
      $0.settingsFileURL = settingsFileURL
      $0.repositoryLocalSettingsStorage = localStorage.storage
    } operation: {
      @Shared(.settingsFile) var settingsFile: SettingsFile
      return settingsFile
    }

    #expect(globalSaved.repositories[repositoryID] == updated)
    #expect(localStorage.data(at: localURL) == nil)
  }

  private func encode(_ settings: RepositorySettings) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(settings)
  }
}

nonisolated final class RepositoryLocalSettingsTestStorage: @unchecked Sendable {
  private let lock = NSLock()
  private var dataByURL: [URL: Data] = [:]

  var storage: RepositoryLocalSettingsStorage {
    RepositoryLocalSettingsStorage(
      load: { try self.load($0) },
      save: { try self.save($0, at: $1) }
    )
  }

  func data(at url: URL) -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return dataByURL[url]
  }

  func save(_ data: Data, at url: URL) throws {
    lock.lock()
    defer { lock.unlock() }
    dataByURL[url] = data
  }

  private func load(_ url: URL) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    guard let data = dataByURL[url] else {
      throw RepositoryLocalSettingsStorageError.missing
    }
    return data
  }
}
