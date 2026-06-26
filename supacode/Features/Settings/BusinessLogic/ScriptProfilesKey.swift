import Dependencies
import Foundation
import Sharing

nonisolated struct ScriptProfilesKeyID: Hashable, Sendable {
  let url: URL
}

nonisolated enum ScriptProfilesFileURLKey: DependencyKey {
  static var liveValue: URL { SupacodePaths.scriptProfilesURL }
  static var previewValue: URL { SupacodePaths.scriptProfilesURL }
  static var testValue: URL { SupacodePaths.scriptProfilesURL }
}

extension DependencyValues {
  nonisolated var scriptProfilesFileURL: URL {
    get { self[ScriptProfilesFileURLKey.self] }
    set { self[ScriptProfilesFileURLKey.self] = newValue }
  }
}

nonisolated struct ScriptProfilesKey: SharedKey {
  var id: ScriptProfilesKeyID {
    @Dependency(\.scriptProfilesFileURL) var url
    return ScriptProfilesKeyID(url: url)
  }

  func load(
    context _: LoadContext<[ScriptProfile]>,
    continuation: LoadContinuation<[ScriptProfile]>
  ) {
    @Dependency(\.settingsFileStorage) var storage
    @Dependency(\.scriptProfilesFileURL) var url
    let decoder = JSONDecoder()
    if let data = try? storage.load(url),
      let profiles = try? decoder.decode([ScriptProfile].self, from: data)
    {
      continuation.resume(returning: normalizedProfiles(profiles))
      return
    }
    continuation.resumeReturningInitialValue()
  }

  func subscribe(
    context _: LoadContext<[ScriptProfile]>,
    subscriber _: SharedSubscriber<[ScriptProfile]>
  ) -> SharedSubscription {
    SharedSubscription {}
  }

  func save(
    _ value: [ScriptProfile],
    context _: SaveContext,
    continuation: SaveContinuation
  ) {
    @Dependency(\.settingsFileStorage) var storage
    @Dependency(\.scriptProfilesFileURL) var url
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
  _ profiles: [ScriptProfile]
) -> [ScriptProfile] {
  var seen = Set<String>()
  var result: [ScriptProfile] = []
  for profile in profiles {
    let normalized = profile.normalized
    guard !normalized.id.isEmpty, seen.insert(normalized.id).inserted else {
      continue
    }
    result.append(normalized)
  }
  return result
}

nonisolated extension SharedReaderKey where Self == ScriptProfilesKey.Default {
  static var scriptProfiles: Self {
    Self[ScriptProfilesKey(), default: []]
  }
}
