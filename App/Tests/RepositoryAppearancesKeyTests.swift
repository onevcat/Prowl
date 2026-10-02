import Dependencies
import DependenciesTestSupport
import Foundation
import Sharing
import Testing

@testable import supacode

struct RepositoryAppearancesKeyTests {
  @Test(.dependencies) func loadReturnsEmptyDictionaryWhenFileMissing() {
    let storage = SettingsTestStorage()
    let url = URL(fileURLWithPath: "/tmp/repo-appearances-\(UUID().uuidString).json")

    let appearances: [Repository.ID: RepositoryAppearance] = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.repositoryAppearancesFileURL = url
    } operation: {
      @Shared(.repositoryAppearances) var appearances
      return appearances
    }

    #expect(appearances.isEmpty)
  }

  @Test(.dependencies) func saveAndReloadRoundTrip() {
    let storage = SettingsTestStorage()
    let url = URL(fileURLWithPath: "/tmp/repo-appearances-\(UUID().uuidString).json")

    withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.repositoryAppearancesFileURL = url
    } operation: {
      @Shared(.repositoryAppearances) var appearances
      $appearances.withLock {
        $0["repo-1"] = RepositoryAppearance(icon: .sfSymbol("folder.fill"), color: .blue)
        $0["repo-2"] = RepositoryAppearance(icon: nil, color: .purple)
      }
    }

    let reloaded: [Repository.ID: RepositoryAppearance] = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.repositoryAppearancesFileURL = url
    } operation: {
      @Shared(.repositoryAppearances) var appearances
      return appearances
    }

    #expect(
      reloaded["repo-1"] == RepositoryAppearance(icon: .sfSymbol("folder.fill"), color: .blue)
    )
    #expect(reloaded["repo-2"] == RepositoryAppearance(icon: nil, color: .purple))
  }

  @Test(.dependencies) func saveDropsEmptyEntries() {
    // Clearing both icon and color resets a repo to the implicit
    // "no appearance" state — we don't want to leave dead `{}` entries
    // in the file forever.
    let storage = SettingsTestStorage()
    let url = URL(fileURLWithPath: "/tmp/repo-appearances-\(UUID().uuidString).json")

    withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.repositoryAppearancesFileURL = url
    } operation: {
      @Shared(.repositoryAppearances) var appearances
      $appearances.withLock {
        $0["keep"] = RepositoryAppearance(icon: .sfSymbol("folder"), color: nil)
        $0["drop"] = .empty
      }
    }

    let reloaded: [Repository.ID: RepositoryAppearance] = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.repositoryAppearancesFileURL = url
    } operation: {
      @Shared(.repositoryAppearances) var appearances
      return appearances
    }

    #expect(reloaded["keep"] != nil)
    #expect(reloaded["drop"] == nil)
  }

  @Test(.dependencies) func loadIgnoresCorruptFile() {
    let storage = SettingsTestStorage()
    let url = URL(fileURLWithPath: "/tmp/repo-appearances-\(UUID().uuidString).json")
    try? storage.storage.save(Data("not-json".utf8), url)

    let appearances: [Repository.ID: RepositoryAppearance] = withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.repositoryAppearancesFileURL = url
    } operation: {
      @Shared(.repositoryAppearances) var appearances
      return appearances
    }

    // Corrupt JSON should fall back to default (empty) rather than crash.
    #expect(appearances.isEmpty)
  }

  @Test(.dependencies) func savedJSONShape() throws {
    // The on-disk shape is part of the public surface — pin it so a
    // refactor of Codable defaults doesn't silently change the file
    // format users have on disk.
    let storage = SettingsTestStorage()
    let url = URL(fileURLWithPath: "/tmp/repo-appearances-\(UUID().uuidString).json")

    withDependencies {
      $0.settingsFileStorage = storage.storage
      $0.repositoryAppearancesFileURL = url
    } operation: {
      @Shared(.repositoryAppearances) var appearances
      $appearances.withLock {
        $0["alpha"] = RepositoryAppearance(icon: .sfSymbol("folder"), color: .red)
      }
    }

    let data = try storage.storage.load(url)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
    let alpha = try #require(json?["alpha"])
    #expect(alpha["icon"] == "folder")
    #expect(alpha["color"] == "red")
  }
}
