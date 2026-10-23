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
    /// Command lane processes that may run at once on the shared connection (docs-ai 084 B1);
    /// `sshd` allows ten sessions per connection by default, and the probe needs one.
    var maxConcurrentCommands = 4

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
  // Command lane state.
  private var isShutDown = false
  private var commandsInFlight = 0
  private var commandWaiters: [(id: UUID, continuation: CheckedContinuation<Void, Never>)] = []
  private var grantedWaiters: Set<UUID> = []
  private var activeCommands: [UUID: Task<RemoteCommandOutcome, Never>] = [:]
  private var loginPathTask: Task<String?, Never>?

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

  /// Stops the probe and the lane commands in flight, finishes every subscription, and
  /// closes the shared connection, so no `ssh` process outlives the owner for longer than
  /// its own exit.
  func shutdown() async {
    // A lane command after `-O exit` would start a new master that outlives the owner; so
    // would one that is still connecting, whose master does not exist yet for `-O exit`.
    isShutDown = true
    for waiter in commandWaiters { waiter.continuation.resume() }
    commandWaiters.removeAll()
    let commands = Array(activeCommands.values)
    for command in commands { command.cancel() }
    for command in commands { _ = await command.value }
    refreshPending = false
    running?.cancel()
    await waitUntilIdle()
    for continuation in subscribers.values { continuation.finish() }
    subscribers.removeAll()
    _ = await runner.run(
      configuration.sshExecutable,
      ["-o", "ControlPath=\(controlPath)", "-O", "exit", "--", recipe.destination],
      Data(),
      RemoteCommandLimits(deadline: 2, outputBytes: 1024, errorBytes: 1024),
      workingDirectory: recipe.workingDirectory)
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
      configuration.sshExecutable, arguments, Data(RemoteProbeScript.text.utf8), configuration.limits,
      workingDirectory: recipe.workingDirectory)
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
        "broken pipe", "connection reset", "kex_exchange_identification",
      ], .unreachable
    ),
  ]
}

// MARK: - Command lane

/// The command lane (docs-ai 084 B1): general remote commands on the owner's shared
/// connection, next to the probe lane. Each command has its own deadline and output budget,
/// at most `Configuration.maxConcurrentCommands` run at once, and commands get the user's
/// login `PATH` for tools such as `git`. After `shutdown`, commands fail without connecting.
extension RemoteConnectionOwner {
  /// Runs `command` with `sh -s`.
  func run(
    _ command: RemoteShellCommand, limits: RemoteCommandLimits = .commandLane
  ) async throws(RemoteShellCommand.ValidationError) -> RemoteCommandOutcome {
    var command = command
    if !command.environment.contains(where: { $0.name == "PATH" }), let path = await loginPath() {
      command.environment.insert((name: "PATH", value: path), at: 0)
    }
    let input = try command.script()
    return await runOnLane(remoteCommand: ["sh", "-s"], input: input, limits: limits, onOutput: nil)
  }

  /// Runs `script` with `bash -s`.
  func run(
    _ script: RemoteScript, limits: RemoteCommandLimits = .commandLane
  ) async throws(RemoteShellCommand.ValidationError) -> RemoteCommandOutcome {
    let input = try script.standardInput(path: await loginPath())
    return await runOnLane(remoteCommand: ["bash", "-s"], input: input, limits: limits, onOutput: nil)
  }

  /// Runs `script` with `bash -s` and hands each line of output and error output to
  /// `onLine` as it arrives, such as the progress of a worktree creation (git and `wt`
  /// report progress on stderr). The outcome still holds both whole outputs.
  func stream(
    _ script: RemoteScript, limits: RemoteCommandLimits = .longRunning,
    onLine: @escaping @Sendable (RemoteOutputStream, String) -> Void
  ) async throws(RemoteShellCommand.ValidationError) -> RemoteCommandOutcome {
    let input = try script.standardInput(path: await loginPath())
    let output = RemoteOutputLineSplitter { onLine(.standardOutput, $0) }
    let errorOutput = RemoteOutputLineSplitter { onLine(.standardError, $0) }
    let outcome = await runOnLane(
      remoteCommand: ["bash", "-s"], input: input, limits: limits,
      onOutput: { stream, chunk in
        switch stream {
        case .standardOutput: output.append(chunk)
        case .standardError: errorOutput.append(chunk)
        }
      })
    output.finish()
    errorOutput.finish()
    return outcome
  }

  /// The `PATH` of the user's login shell on the host, read once per owner; concurrent
  /// callers share one read. Nil when it cannot be read, and that result is kept too:
  /// commands then run with the default `PATH` of a non-login session.
  func loginPath() async -> String? {
    if let loginPathTask { return await loginPathTask.value }
    let task = Task { await self.readLoginPath() }
    loginPathTask = task
    return await task.value
  }

  private func readLoginPath() async -> String? {
    let outcome = await runOnLane(
      remoteCommand: ["sh", "-s"], input: Self.loginPathScript,
      limits: RemoteCommandLimits(deadline: 10, outputBytes: 64 * 1024, errorBytes: 16 * 1024), onOutput: nil)
    guard case .exited(let result) = outcome, result.exitCode == 0 else { return nil }
    return Self.parseLoginPath(result.output)
  }

  /// Prints the login shell's `PATH` between two U+0001 markers, so that output from the
  /// login files (a banner, `echo` in a profile) cannot be mistaken for it. Like the local
  /// `ShellClient.loginShellInvocation`, it also reads the interactive rc file, where tools
  /// such as Homebrew, mise or nvm often extend `PATH`, and it uses zsh for a shell it
  /// cannot drive. zsh finds its rc file after its login files ran, so a `ZDOTDIR` set in
  /// `.zshenv` applies.
  static let loginPathScript = """
    print_path='printf "\\001%s\\001" "$PATH"'
    zsh_rc='prowl_rc="${ZDOTDIR:-$HOME}/.zshrc"; [ -f "$prowl_rc" ] && . "$prowl_rc" >/dev/null 2>&1'
    fish_rc='test -f ~/.config/fish/config.fish; and source ~/.config/fish/config.fish >/dev/null 2>&1'
    case "${SHELL##*/}" in
      zsh|bash|fish) prowl_shell=$SHELL ;;
      *) prowl_shell=$(command -v zsh || command -v bash || echo /bin/sh) ;;
    esac
    case "${prowl_shell##*/}" in
      fish) exec "$prowl_shell" -l -c "$fish_rc; $print_path" ;;
      bash) exec "$prowl_shell" -l -c "[ -f ~/.bashrc ] && . ~/.bashrc >/dev/null 2>&1; $print_path" ;;
      zsh) exec "$prowl_shell" -l -c "$zsh_rc; $print_path" ;;
      *) exec "$prowl_shell" -l -c "$print_path" ;;
    esac

    """

  static func parseLoginPath(_ output: Data) -> String? {
    let text = String(bytes: output, encoding: .utf8) ?? ""
    let parts = text.split(separator: "\u{1}", omittingEmptySubsequences: false)
    guard parts.count >= 3 else { return nil }
    let path = parts[parts.count - 2].trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? nil : path
  }

  /// The number of lane commands running now; for tests.
  var runningCommandCount: Int { commandsInFlight }

  /// Runs one lane command in a task the owner tracks, so `shutdown` can stop it and wait
  /// for it; the caller's cancellation reaches it too.
  private func runOnLane(
    remoteCommand: [String], input: String, limits: RemoteCommandLimits,
    onOutput: RemoteCommandRunner.OutputHandler?
  ) async -> RemoteCommandOutcome {
    guard await acquireCommandSlot() else { return .launchFailed(Self.laneClosedReason) }
    defer { releaseCommandSlot() }
    prepareControlDirectory()
    let arguments = SSHSideChannel.scriptArguments(
      recipe: recipe, controlPath: controlPath, persist: configuration.controlPersistSeconds,
      remoteCommand: remoteCommand)
    let (runner, executable, directory) = (runner, configuration.sshExecutable, recipe.workingDirectory)
    let id = UUID()
    let command = Task {
      if let onOutput {
        return await runner.runStreaming(
          executable, arguments, Data(input.utf8), limits, workingDirectory: directory, onOutput: onOutput)
      }
      return await runner.run(executable, arguments, Data(input.utf8), limits, workingDirectory: directory)
    }
    activeCommands[id] = command
    defer { activeCommands.removeValue(forKey: id) }
    return await withTaskCancellationHandler {
      await command.value
    } onCancel: {
      command.cancel()
    }
  }

  static let laneClosedReason = "The remote connection was closed or the command was cancelled."

  /// Waits for a lane slot, in order. False when the owner shut down or the caller was
  /// cancelled while it waited; a cancelled waiter leaves the queue at once.
  private func acquireCommandSlot() async -> Bool {
    guard !isShutDown, !Task.isCancelled else { return false }
    if commandsInFlight < configuration.maxConcurrentCommands {
      commandsInFlight += 1
      return true
    }
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { commandWaiters.append((id, $0)) }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
    guard grantedWaiters.remove(id) != nil else { return false }
    // The owner can shut down, or the caller be cancelled, between the grant and this resume.
    if isShutDown || Task.isCancelled {
      releaseCommandSlot()
      return false
    }
    return true
  }

  private func cancelWaiter(_ id: UUID) {
    guard let index = commandWaiters.firstIndex(where: { $0.id == id }) else { return }
    commandWaiters.remove(at: index).continuation.resume()
  }

  /// Hands the slot to the next waiter, or frees it.
  private func releaseCommandSlot() {
    guard !isShutDown, !commandWaiters.isEmpty else {
      commandsInFlight -= 1
      return
    }
    let next = commandWaiters.removeFirst()
    grantedWaiters.insert(next.id)
    next.continuation.resume()
  }
}
