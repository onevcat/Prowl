import Dependencies
import Foundation
import Sharing

nonisolated struct BootstrapProfilesKeyID: Hashable, Sendable {
  let url: URL
}

nonisolated enum BootstrapProfilesFileURLKey: DependencyKey {
  static var liveValue: URL { SupacodePaths.bootstrapProfilesURL }
  static var previewValue: URL { SupacodePaths.bootstrapProfilesURL }
  static var testValue: URL { SupacodePaths.bootstrapProfilesURL }
}

extension DependencyValues {
  nonisolated var bootstrapProfilesFileURL: URL {
    get { self[BootstrapProfilesFileURLKey.self] }
    set { self[BootstrapProfilesFileURLKey.self] = newValue }
  }
}

nonisolated struct BootstrapProfilesKey: SharedKey {
  var id: BootstrapProfilesKeyID {
    @Dependency(\.bootstrapProfilesFileURL) var url
    return BootstrapProfilesKeyID(url: url)
  }

  func load(
    context _: LoadContext<[ProjectWorkspaceBootstrapProfile]>,
    continuation: LoadContinuation<[ProjectWorkspaceBootstrapProfile]>
  ) {
    @Dependency(\.settingsFileStorage) var storage
    @Dependency(\.bootstrapProfilesFileURL) var url
    let decoder = JSONDecoder()
    if let data = try? storage.load(url),
      let profiles = try? decoder.decode([ProjectWorkspaceBootstrapProfile].self, from: data)
    {
      continuation.resume(returning: normalizedProfiles(profiles))
      return
    }
    continuation.resumeReturningInitialValue()
  }

  func subscribe(
    context _: LoadContext<[ProjectWorkspaceBootstrapProfile]>,
    subscriber _: SharedSubscriber<[ProjectWorkspaceBootstrapProfile]>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: [ProjectWorkspaceBootstrapProfile],
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    @Dependency(\.settingsFileStorage) var storage
    @Dependency(\.bootstrapProfilesFileURL) var url
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
      let data = try encoder.encode(normalizedProfiles(value))
      try storage.save(data, url)
      continuation.resume()
    } catch {
      continuation.resume(throwing: error)
    }
  }
}

private nonisolated func normalizedProfiles(
  _ profiles: [ProjectWorkspaceBootstrapProfile]
) -> [ProjectWorkspaceBootstrapProfile] {
  var seen = Set<String>()
  var result: [ProjectWorkspaceBootstrapProfile] = []
  for profile in profiles {
    let normalized = profile.normalized
    guard !normalized.id.isEmpty, seen.insert(normalized.id).inserted else {
      continue
    }
    result.append(normalized)
  }
  return result
}

nonisolated extension SharedReaderKey where Self == BootstrapProfilesKey.Default {
  static var bootstrapProfiles: Self {
    Self[BootstrapProfilesKey(), default: []]
  }
}
