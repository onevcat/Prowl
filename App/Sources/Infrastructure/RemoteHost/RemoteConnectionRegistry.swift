import Foundation

/// Hands out one `RemoteConnectionOwner` per connection key (docs-ai 082, C4), so panes and
/// folders that reach the same effective target share one side channel and one probe.
///
/// Callers lease an owner and release it. The last release retires the owner; an acquire
/// for the same key waits until that retirement (and its `-O exit`) finished, so two
/// lifecycles never share a control socket.
actor RemoteConnectionRegistry {
  static let shared = RemoteConnectionRegistry()

  private let configuration: RemoteConnectionOwner.Configuration
  private let runner: RemoteCommandRunner
  private var owners: [ConnectionKey: RemoteConnectionOwner] = [:]
  private var leases: [ConnectionKey: Int] = [:]
  private var retirements: [ConnectionKey: Task<Void, Never>] = [:]

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
      RemoteCommandLimits(deadline: 3, outputBytes: 64 * 1024, errorBytes: 4 * 1024),
      workingDirectory: recipe.workingDirectory)
    guard case .exited(let result) = outcome, result.exitCode == 0 else { return nil }
    return ConnectionKey(
      effectiveConfiguration: String(bytes: result.output, encoding: .utf8) ?? "", configFile: recipe.configFile)
  }

  /// Leases the owner for `key`; the first recipe that reached the key is the one it
  /// connects with. Every acquire needs one `release`.
  func acquire(_ key: ConnectionKey, recipe: SSHConnectionRecipe) async -> RemoteConnectionOwner {
    while let retirement = retirements[key] {
      await retirement.value
      // A finished task returns without suspending, so whoever sees it end removes it.
      if retirements[key] == retirement { retirements.removeValue(forKey: key) }
    }
    leases[key, default: 0] += 1
    if let owner = owners[key] { return owner }
    let owner = RemoteConnectionOwner(connection: key, recipe: recipe, configuration: configuration, runner: runner)
    owners[key] = owner
    return owner
  }

  /// Ends one lease. The last one shuts the owner down and returns after it closed.
  func release(_ key: ConnectionKey) async {
    guard let count = leases[key] else { return }
    guard count == 1 else {
      leases[key] = count - 1
      return
    }
    leases.removeValue(forKey: key)
    guard let owner = owners.removeValue(forKey: key) else { return }
    let retirement = Task { await owner.shutdown() }
    retirements[key] = retirement
    await retirement.value
    if retirements[key] == retirement { retirements.removeValue(forKey: key) }
  }

  func leaseCount(_ key: ConnectionKey) -> Int {
    leases[key] ?? 0
  }
}
