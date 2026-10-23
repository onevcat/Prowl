import Foundation

/// The command lane of one host as remote folders use it (docs-ai 084 B3): commands with
/// `sh -s` and scripts with `bash -s`, each with the user's login `PATH`.
nonisolated struct RemoteCommandLane: Sendable {
  var run: @Sendable (RemoteShellCommand, RemoteCommandLimits) async throws -> RemoteCommandOutcome
  var runScript: @Sendable (RemoteScript, RemoteCommandLimits) async throws -> RemoteCommandOutcome

  /// The lane of an owner that the caller keeps leased.
  static func owner(_ owner: RemoteConnectionOwner) -> Self {
    Self(
      run: { command, limits in try await owner.run(command, limits: limits) },
      runScript: { script, limits in try await owner.run(script, limits: limits) }
    )
  }

  /// Leases the connection of `profile` for each command. While nothing else holds a
  /// lease, each command connects again; B3d keeps a lease while a repository is loaded.
  ///
  /// Each command first resolves the profile's recipe with `ssh -G`, as panes do. When the
  /// configuration now reaches another user, host name or port, nothing runs: a removal
  /// or a branch deletion must not reach another machine (C1 asks to rebind).
  static func leased(_ profile: HostProfile, registry: RemoteConnectionRegistry = .shared) -> Self {
    Self(
      run: { command, limits in
        try await withLease(profile, registry) { try await $0.run(command, limits: limits) }
      },
      runScript: { script, limits in
        try await withLease(profile, registry) { try await $0.run(script, limits: limits) }
      }
    )
  }

  private static func withLease(
    _ profile: HostProfile, _ registry: RemoteConnectionRegistry,
    _ body: (RemoteConnectionOwner) async throws -> RemoteCommandOutcome
  ) async throws -> RemoteCommandOutcome {
    guard let key = await registry.resolve(profile.recipe) else {
      throw RemoteRepositoryHostError.configurationRejected
    }
    guard !profile.authorityChanged(to: key) else { throw RemoteRepositoryHostError.authorityChanged }
    let owner = await registry.acquire(key, recipe: profile.recipe)
    do {
      let outcome = try await body(owner)
      await registry.release(key)
      return outcome
    } catch {
      await registry.release(key)
      throw error
    }
  }
}
