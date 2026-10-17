import Foundation

/// The single owner of one host's side channel (docs-ai 082, C4).
///
/// Panes subscribe and ask for refreshes; the owner runs at most one probe at a time and
/// publishes every snapshot to every subscriber. A request while idle runs at once; the
/// requests that arrive while a probe runs coalesce into one refresh that runs right after
/// it, so continuous screen output neither floods the host nor postpones the refresh. After
/// a failure the next run waits a jittered, growing delay. All work runs off the main
/// actor; the side channel is `ssh` with Prowl's own ControlMaster and the overrides of
/// `SSHSideChannel`.
actor RemoteConnectionOwner {
  struct Configuration: Sendable {
    var sshExecutable = URL(filePath: "/usr/bin/ssh")
    var controlDirectory: String
    var controlPersistSeconds = 60
    var limits = RemoteCommandLimits()
    var backoff = Backoff()

    init(controlDirectory: String = RemoteConnectionOwner.defaultControlDirectory()) {
      self.controlDirectory = controlDirectory
    }
  }

  struct Backoff: Sendable {
    var initial: TimeInterval = 0.5
    var maximum: TimeInterval = 8
    /// The delay is multiplied by a factor in `1 - jitter ... 1 + jitter`.
    var jitter = 0.2

    func delay(afterFailures failures: Int, random: Double) -> TimeInterval {
      guard failures > 0 else { return 0 }
      let base = min(maximum, initial * pow(2, Double(failures - 1)))
      return base * (1 - jitter + 2 * jitter * random)
    }
  }

  nonisolated let connection: ConnectionKey
  nonisolated let recipe: SSHConnectionRecipe
  private let configuration: Configuration
  private let runner: RemoteCommandRunner
  private let now: @Sendable () -> TimeInterval
  private let sleep: @Sendable (TimeInterval) async throws -> Void
  private let random: @Sendable () -> Double

  private var subscribers: [UUID: AsyncStream<RemoteProbeSnapshot>.Continuation] = [:]
  private var running: Task<Void, Never>?
  private var refreshPending = false
  private var sequence: UInt64 = 0
  private var connectionEpoch: UInt64 = 0
  private var consecutiveFailures = 0
  private(set) var latest: RemoteProbeSnapshot?

  init(
    connection: ConnectionKey,
    recipe: SSHConnectionRecipe,
    configuration: Configuration = Configuration(),
    runner: RemoteCommandRunner = .live,
    now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
    random: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
  ) {
    self.connection = connection
    self.recipe = recipe
    self.configuration = configuration
    self.runner = runner
    self.now = now
    self.sleep = sleep
    self.random = random
  }

  /// A stream of every snapshot published after the call; the latest one, if any, is
  /// delivered first. Finishing the stream's consumer does not stop the owner; call
  /// `unsubscribe`.
  func subscribe() -> (id: UUID, snapshots: AsyncStream<RemoteProbeSnapshot>) {
    let id = UUID()
    let (stream, continuation) = AsyncStream<RemoteProbeSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
    if let latest { continuation.yield(latest) }
    subscribers[id] = continuation
    return (id, stream)
  }

  func unsubscribe(_ id: UUID) {
    subscribers.removeValue(forKey: id)?.finish()
  }

  var subscriberCount: Int { subscribers.count }

  /// Asks for a fresh snapshot: now when idle, otherwise once after the running probe.
  func requestRefresh() {
    if running != nil {
      refreshPending = true
      return
    }
    running = Task { await self.drain() }
  }

  /// Waits until no probe is running or pending. For tests and orderly shutdown.
  func waitUntilIdle() async {
    while let running {
      await running.value
    }
  }

  /// Stops the probe in flight, finishes every subscription, and closes the control
  /// master, so no `ssh` process outlives the owner for longer than its own exit.
  func shutdown() async {
    refreshPending = false
    running?.cancel()
    await waitUntilIdle()
    for continuation in subscribers.values { continuation.finish() }
    subscribers.removeAll()
    _ = await runner.run(
      configuration.sshExecutable,
      ["-o", "ControlPath=\(controlPath)", "-O", "exit", "--", recipe.destination],
      Data(),
      RemoteCommandLimits(deadline: 2, outputBytes: 1024, errorBytes: 1024))
  }

  nonisolated static func defaultControlDirectory() -> String {
    FileManager.default.temporaryDirectory.appending(path: "prowl-ssh", directoryHint: .isDirectory)
      .path(percentEncoded: false)
  }

  var controlPath: String {
    SSHSideChannel.controlPath(for: connection, directory: configuration.controlDirectory)
  }

  private func drain() async {
    repeat {
      refreshPending = false
      let delay = configuration.backoff.delay(afterFailures: consecutiveFailures, random: random())
      if delay > 0 {
        do { try await sleep(delay) } catch { break }
      }
      guard !Task.isCancelled else { break }
      let snapshot = await probe()
      guard !Task.isCancelled else { break }
      publish(snapshot)
    } while refreshPending
    running = nil
  }

  private func probe() async -> RemoteProbeSnapshot {
    sequence &+= 1
    let sequence = sequence
    let startedAt = now()
    prepareControlDirectory()
    let arguments = SSHSideChannel.scriptArguments(
      recipe: recipe, controlPath: controlPath, persist: configuration.controlPersistSeconds)
    let outcome = await runner.run(
      configuration.sshExecutable, arguments, Data(RemoteProbeScript.text.utf8), configuration.limits)
    let (result, report) = Self.interpret(outcome)
    switch result {
    case .complete, .partial:
      consecutiveFailures = 0
    case .failed, .timedOut:
      // The next success runs on a new connection; its records start a new epoch.
      if consecutiveFailures == 0 { connectionEpoch &+= 1 }
      consecutiveFailures += 1
    }
    return RemoteProbeSnapshot(
      connection: connection, connectionEpoch: connectionEpoch, sequence: sequence, startedAt: startedAt,
      finishedAt: now(), outcome: result, report: report)
  }

  private func publish(_ snapshot: RemoteProbeSnapshot) {
    latest = snapshot
    for continuation in subscribers.values { continuation.yield(snapshot) }
  }

  private func prepareControlDirectory() {
    try? FileManager.default.createDirectory(
      atPath: configuration.controlDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
  }

  static func interpret(_ outcome: RemoteCommandOutcome) -> (RemoteProbeSnapshot.Outcome, RemoteProbeReport?) {
    switch outcome {
    case .timedOut:
      return (.timedOut, nil)
    case .launchFailed(let reason):
      return (.failed(.launch(reason)), nil)
    case .exited(let result):
      guard result.exitCode == 0 else { return (.failed(failure(result)), nil) }
      switch RemoteProbeParser.parse(result.output) {
      case .complete(let report):
        return result.outputTruncated ? (.partial, report) : (.complete, report)
      case .partial(let report):
        return (.partial, report)
      case .unrecognized:
        return (.failed(.unrecognizedOutput), nil)
      }
    }
  }

  /// `ssh` exits 255 for its own errors and prints them on stderr.
  static func failure(_ result: RemoteCommandResult) -> RemoteProbeFailure {
    let message = result.errorOutput.lowercased()
    if result.exitCode == 255,
      let match = failureMessages.first(where: { pair in pair.fragments.contains(where: message.contains) })
    {
      return match.failure
    }
    let lastLine = result.errorOutput.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    return .exit(result.exitCode, lastLine)
  }

  private static let failureMessages: [(fragments: [String], failure: RemoteProbeFailure)] = [
    (["host key verification failed", "remote host identification has changed"], .hostKey),
    (["permission denied", "too many authentication failures"], .authentication),
    (["could not resolve hostname", "nodename nor servname"], .unresolvableHost),
    (
      [
        "connection refused", "timed out", "no route to host", "network is unreachable", "connection closed",
        "broken pipe",
      ], .unreachable
    ),
  ]
}
