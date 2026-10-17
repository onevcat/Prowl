import Foundation

/// Hands out one `RemoteConnectionOwner` per connection key (docs-ai 082, C4), so panes and
/// folders that reach the same effective target share one side channel and one probe.
actor RemoteConnectionRegistry {
  static let shared = RemoteConnectionRegistry()

  private let configuration: RemoteConnectionOwner.Configuration
  private let runner: RemoteCommandRunner
  private var owners: [ConnectionKey: RemoteConnectionOwner] = [:]

  init(
    configuration: RemoteConnectionOwner.Configuration = RemoteConnectionOwner.Configuration(),
    runner: RemoteCommandRunner = .live
  ) {
    self.configuration = configuration
    self.runner = runner
  }

  /// The effective target of `recipe` from `ssh -G`; nil when `ssh` rejects the options.
  func resolve(_ recipe: SSHConnectionRecipe) async -> ConnectionKey? {
    let outcome = await runner.run(
      configuration.sshExecutable, SSHSideChannel.resolveArguments(recipe: recipe), Data(),
      RemoteCommandLimits(deadline: 3, outputBytes: 64 * 1024, errorBytes: 4 * 1024))
    guard case .exited(let result) = outcome, result.exitCode == 0 else { return nil }
    return ConnectionKey(
      effectiveConfiguration: String(bytes: result.output, encoding: .utf8) ?? "", configFile: recipe.configFile)
  }

  /// The owner for `key`; the first recipe that reached the key is the one it connects with.
  func owner(for key: ConnectionKey, recipe: SSHConnectionRecipe) -> RemoteConnectionOwner {
    if let owner = owners[key] { return owner }
    let owner = RemoteConnectionOwner(connection: key, recipe: recipe, configuration: configuration, runner: runner)
    owners[key] = owner
    return owner
  }

  /// Shuts the owner down once nothing subscribes to it any more.
  func releaseIfUnused(_ key: ConnectionKey) async {
    guard let owner = owners[key], await owner.subscriberCount == 0 else { return }
    owners.removeValue(forKey: key)
    await owner.shutdown()
  }
}
