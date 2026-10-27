import Dependencies
import Foundation
import Sharing

nonisolated enum RemoteFolderValidationError: Error, Equatable, LocalizedError {
  case emptyDestination
  case emptyPath
  /// The host profile was bound to another user, host name or port; the sheet offers to
  /// rebind it to `resolved` (C1b).
  case authorityChanged(HostProfile, resolved: ConnectionKey)
  case hostsFileNotSaved
  /// `hosts.json` exists but this build cannot read it, so it is never written over (B2b).
  case hostsFileUnreadable
  case folderNotFound(String)
  case folderInaccessible(String)
  case notAFolder(String)
  case invalidPath

  var errorDescription: String? {
    switch self {
    case .emptyDestination:
      String(localized: "Enter a host, such as user@example.com or an alias from your SSH configuration.")
    case .emptyPath:
      String(localized: "Enter the folder's path on the host.")
    case .authorityChanged(let profile, let resolved):
      String(
        localized: """
          The SSH configuration of \(profile.alias) now reaches \(resolved.displayName). Its folders were \
          added for \(profile.connectionKey.displayName).
          """)
    case .hostsFileNotSaved:
      String(localized: "Prowl could not save the host. Try again.")
    case .hostsFileUnreadable:
      String(localized: "This version of Prowl cannot read ~/.prowl/hosts.json, so it adds no host to it.")
    case .folderNotFound(let path):
      String(localized: "There is no folder at \(path) on the host.")
    case .folderInaccessible(let path):
      String(localized: "Prowl cannot open \(path) on the host.")
    case .notAFolder(let path):
      String(localized: "\(path) on the host is a file, not a folder.")
    case .invalidPath:
      String(localized: "The path cannot be used for a remote folder.")
    }
  }
}

/// A remote folder that is ready to add: its host profile (new or existing) and its root
/// on that host (docs-ai 084 C1, D7).
nonisolated struct ValidatedRemoteFolder: Equatable, Sendable {
  let profile: HostProfile
  let isNewProfile: Bool
  let rootPath: String
  let kind: Repository.Kind

  var location: RepositoryLocation { .remote(hostProfileID: profile.id, path: rootPath) }
}

/// Checks a host and a path before a remote folder is added (D7): the SSH configuration
/// resolves (`ssh -G`), the host answers, and the path is found (`pwd -P`, `git rev-parse`).
nonisolated struct RemoteFolderValidatorClient: Sendable {
  /// `existing` is the chosen host profile, or nil for a new host at `destination`.
  var validate:
    @Sendable (_ existing: HostProfile?, _ destination: String, _ path: String, _ knownProfiles: [HostProfile])
      async throws -> ValidatedRemoteFolder
  /// The subfolders of `path` on the host, for the folder browser. Nothing is stored.
  var listFolder:
    @Sendable (_ existing: HostProfile?, _ destination: String, _ path: String, _ knownProfiles: [HostProfile])
      async throws -> RemoteFolderListing = { _, _, _, _ in throw RemoteRepositoryHostError.unsupported }
}

extension RemoteFolderValidatorClient: DependencyKey {
  static let liveValue = RemoteFolderValidatorClient(
    validate: { existing, destination, path, knownProfiles in
      let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !path.isEmpty else { throw RemoteFolderValidationError.emptyPath }
      let (profile, isNewProfile) = try await resolveProfile(existing, destination, knownProfiles)
      let host = RemoteRepositoryHost(hostProfileID: profile.id, lane: .leased(profile))
      let discovery = try await host.discoverFolder(path)
      return ValidatedRemoteFolder(
        profile: profile, isNewProfile: isNewProfile, rootPath: discovery.rootPath, kind: discovery.kind)
    },
    listFolder: { existing, destination, path, knownProfiles in
      // A new host is not stored by browsing: only adding a folder is consent (D2).
      let (profile, _) = try await resolveProfile(existing, destination, knownProfiles)
      let host = RemoteRepositoryHost(hostProfileID: profile.id, lane: .leased(profile))
      return try await host.listFolder(path)
    })

  /// The host profile to connect with: `existing`, the known profile of a new destination,
  /// or a new profile that is not stored yet.
  private static func resolveProfile(
    _ existing: HostProfile?, _ destination: String, _ knownProfiles: [HostProfile]
  ) async throws -> (profile: HostProfile, isNew: Bool) {
    try RemoteCommandLane.requireSideChannel()
    let registry = RemoteConnectionRegistry.shared
    if let existing {
      guard let key = await registry.resolve(existing.recipe) else {
        throw RemoteRepositoryHostError.configurationRejected
      }
      guard !existing.authorityChanged(to: key) else {
        throw RemoteFolderValidationError.authorityChanged(existing, resolved: key)
      }
      return (existing, false)
    }
    let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !destination.isEmpty else { throw RemoteFolderValidationError.emptyDestination }
    let recipe = SSHConnectionRecipe(destination: destination)
    guard let key = await registry.resolve(recipe) else { throw RemoteRepositoryHostError.configurationRejected }
    if let known = try knownProfile(for: recipe, resolvedTo: key, in: knownProfiles) {
      return (known, false)
    }
    return (HostProfile(id: UUID(), alias: destination, recipe: recipe, connectionKey: key), true)
  }

  /// The known profile for a new destination: one with the same recipe keeps its profile.
  /// One whose target changed needs a rebind, not a second profile with the same name.
  nonisolated static func knownProfile(
    for recipe: SSHConnectionRecipe, resolvedTo key: ConnectionKey, in profiles: [HostProfile]
  ) throws(RemoteFolderValidationError) -> HostProfile? {
    guard let known = profiles.first(where: { $0.recipe == recipe }) else { return nil }
    guard !known.authorityChanged(to: key) else { throw .authorityChanged(known, resolved: key) }
    return known
  }

  static let testValue = RemoteFolderValidatorClient(validate: { _, _, _, _ in
    throw RemoteRepositoryHostError.unsupported
  })
}
