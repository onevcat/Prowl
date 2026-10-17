import Foundation
import Testing

@testable import Prowl

/// The connection owner's scheduling, budgets, and snapshot contract (docs-ai 082, C3/C4),
/// with a scripted runner in place of `ssh`.
struct RemoteConnectionOwnerTests {
  private static let key = ConnectionKey(user: "onevcat", hostname: "mini.local")
  private static let recipe = SSHConnectionRecipe(destination: "mini", options: ["-p", "22"])

  /// Records every call; each probe call can be held open until the test releases it.
  private struct FakeCall {
    let arguments: [String]
    let input: Data
  }

  private actor FakeRunner {
    var calls: [FakeCall] = []
    var outcomes: [RemoteCommandOutcome] = []
    var holds = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var holdsExit = false
    private var heldExit: CheckedContinuation<Void, Never>?
    private var exitWaiter: CheckedContinuation<Void, Never>?
    var events: [String] = []

    func setOutcomes(_ outcomes: [RemoteCommandOutcome]) { self.outcomes = outcomes }
    func setHolds(_ holds: Bool) { self.holds = holds }
    func setHoldsExit(_ holds: Bool) { holdsExit = holds }

    func waitForExitCall() async {
      guard heldExit == nil else { return }
      await withCheckedContinuation { exitWaiter = $0 }
    }

    func releaseExit() {
      heldExit?.resume()
      heldExit = nil
    }

    func run(_ arguments: [String], _ input: Data) async -> RemoteCommandOutcome {
      calls.append(FakeCall(arguments: arguments, input: input))
      if arguments.contains("-O") {
        events.append("exit started")
        if holdsExit {
          await withCheckedContinuation { continuation in
            heldExit = continuation
            exitWaiter?.resume()
            exitWaiter = nil
          }
        }
        events.append("exit finished")
        return .exited(Self.success)
      }
      if arguments.last == "-s" { events.append("probe") }
      let probes = calls.filter { $0.arguments.last == "-s" }.count
      for waiter in enteredWaiters where waiter.count <= probes { waiter.continuation.resume() }
      enteredWaiters.removeAll { $0.count <= probes }
      if holds, arguments.last == "-s" {
        await withCheckedContinuation { held.append($0) }
      }
      return outcomes.isEmpty ? .exited(Self.success) : outcomes.removeFirst()
    }

    func waitForProbes(_ count: Int) async {
      guard calls.filter({ $0.arguments.last == "-s" }).count < count else { return }
      await withCheckedContinuation { enteredWaiters.append((count, $0)) }
    }

    func releaseOne() {
      guard !held.isEmpty else { return }
      held.removeFirst().resume()
    }

    var probeCount: Int { calls.filter { $0.arguments.last == "-s" }.count }

    static let success = RemoteCommandResult(
      exitCode: 0, output: Data(RemoteProbeParserTests.linux.utf8), outputTruncated: false, errorOutput: "")
  }

  private nonisolated final class Recorder: @unchecked Sendable {
    let delays = LockIsolatedArray()
  }

  private nonisolated final class LockIsolatedArray: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TimeInterval] = []
    func append(_ value: TimeInterval) { lock.withLock { storage.append(value) } }
    var values: [TimeInterval] { lock.withLock { storage } }
  }

  private func makeOwner(_ fake: FakeRunner, recorder: Recorder = Recorder()) -> RemoteConnectionOwner {
    var configuration = RemoteConnectionOwner.Configuration(controlDirectory: "/tmp/prowl-ssh-tests")
    configuration.controlPersistSeconds = 30
    return RemoteConnectionOwner(
      connection: Self.key, recipe: Self.recipe, configuration: configuration,
      runner: RemoteCommandRunner { _, arguments, input, _ in await fake.run(arguments, input) },
      now: { 100 },
      sleep: { recorder.delays.append($0) },
      random: { 0.5 })
  }

  @Test func probeRunsTheScriptOverTheSideChannelAndPublishesACompleteSnapshot() async throws {
    let fake = FakeRunner()
    let owner = makeOwner(fake)
    let (_, stream) = await owner.subscribe()
    await owner.requestRefresh()
    var iterator = stream.makeAsyncIterator()
    let snapshot = try #require(await iterator.next())
    #expect(snapshot.outcome == .complete)
    #expect(snapshot.sequence == 1)
    #expect(snapshot.connection == Self.key)
    #expect(snapshot.report?.sessions.count == 2)

    let call = try #require(await fake.calls.first)
    #expect(call.input == Data(RemoteProbeScript.text.utf8))
    // Overrides come before the user's options, the destination after `--`.
    let overrides = call.arguments.prefix(SSHSideChannel.sessionOverrides.count)
    #expect(Array(overrides) == SSHSideChannel.sessionOverrides)
    #expect(call.arguments.suffix(4) == ["--", "mini", "sh", "-s"])
    #expect(call.arguments.contains("ControlPersist=30"))
    #expect(call.arguments.contains("ClearAllForwardings=yes"))
    #expect(call.arguments.contains("RemoteCommand=none"))
  }

  @Test func requestsDuringAProbeCoalesceIntoOneFollowUpRun() async {
    let fake = FakeRunner()
    await fake.setHolds(true)
    let owner = makeOwner(fake)
    await owner.requestRefresh()
    await fake.waitForProbes(1)
    for _ in 0..<20 { await owner.requestRefresh() }
    await fake.releaseOne()
    await fake.waitForProbes(2)
    // Requests that arrive during the follow-up run coalesce again into exactly one more.
    await owner.requestRefresh()
    await fake.releaseOne()
    await fake.waitForProbes(3)
    await fake.releaseOne()
    await owner.waitUntilIdle()
    #expect(await fake.probeCount == 3)
    #expect(await owner.latest?.sequence == 3)
  }

  @Test func failuresBackOffWithJitterAndStartANewEpoch() async {
    let fake = FakeRunner()
    let refused = RemoteCommandResult(
      exitCode: 255, output: Data(), outputTruncated: false,
      errorOutput: "ssh: connect to host mini port 22: Connection refused\n")
    await fake.setOutcomes([.exited(refused), .timedOut, .exited(FakeRunner.success)])
    let recorder = Recorder()
    let owner = makeOwner(fake, recorder: recorder)

    await owner.requestRefresh()
    await owner.waitUntilIdle()
    #expect(await owner.latest?.outcome == .failed(.unreachable))
    #expect(await owner.latest?.connectionEpoch == 1)
    await owner.requestRefresh()
    await owner.waitUntilIdle()
    #expect(await owner.latest?.outcome == .timedOut)
    await owner.requestRefresh()
    await owner.waitUntilIdle()
    #expect(await owner.latest?.outcome == .complete)
    // The failure streak kept one epoch; the recovered run reports in it.
    #expect(await owner.latest?.connectionEpoch == 1)
    // random() == 0.5 keeps the base delay: 0.5 s after one failure, 1 s after two.
    #expect(recorder.delays.values == [0.5, 1])
  }

  @Test func shutdownFinishesSubscriptionsAndClosesTheControlConnection() async throws {
    let fake = FakeRunner()
    let owner = makeOwner(fake)
    let (_, stream) = await owner.subscribe()
    await owner.shutdown()
    var iterator = stream.makeAsyncIterator()
    #expect(await iterator.next() == nil)
    let exit = try #require(await fake.calls.last)
    #expect(exit.arguments.contains("-O"))
    #expect(exit.arguments.contains("exit"))
    #expect(await owner.subscriberCount == 0)
  }

  @Test func aReacquiredKeyWaitsUntilTheRetiringOwnerClosed() async {
    let fake = FakeRunner()
    await fake.setHoldsExit(true)
    let registry = RemoteConnectionRegistry(
      configuration: RemoteConnectionOwner.Configuration(controlDirectory: "/tmp/prowl-ssh-tests"),
      runner: RemoteCommandRunner { _, arguments, input, _ in await fake.run(arguments, input) })
    let first = await registry.acquire(Self.key, recipe: Self.recipe)
    #expect(await registry.leaseCount(Self.key) == 1)
    let retiring = Task { await registry.release(Self.key) }
    await fake.waitForExitCall()
    let reacquired = Task { () -> RemoteConnectionOwner in
      let owner = await registry.acquire(Self.key, recipe: Self.recipe)
      await owner.requestRefresh()
      await owner.waitUntilIdle()
      return owner
    }
    await fake.releaseExit()
    await retiring.value
    let second = await reacquired.value
    #expect(first !== second)
    #expect(await fake.events == ["exit started", "exit finished", "probe"])
    await fake.setHoldsExit(false)
    await registry.release(Self.key)
  }

  @Test func onlyTheLastLeaseRetiresTheOwner() async {
    let fake = FakeRunner()
    let registry = RemoteConnectionRegistry(
      configuration: RemoteConnectionOwner.Configuration(controlDirectory: "/tmp/prowl-ssh-tests"),
      runner: RemoteCommandRunner { _, arguments, input, _ in await fake.run(arguments, input) })
    let first = await registry.acquire(Self.key, recipe: Self.recipe)
    let second = await registry.acquire(Self.key, recipe: Self.recipe)
    #expect(first === second)
    await registry.release(Self.key)
    #expect(await fake.events.isEmpty)
    await registry.release(Self.key)
    #expect(await fake.events == ["exit started", "exit finished"])
    #expect(await registry.leaseCount(Self.key) == 0)
  }

  @Test func truncatedOrForeignOutputIsNeverComplete() {
    let truncated = RemoteCommandResult(
      exitCode: 0, output: Data(RemoteProbeParserTests.linux.utf8), outputTruncated: true, errorOutput: "")
    #expect(RemoteConnectionOwner.interpret(.exited(truncated)).0 == .partial)
    let banner = RemoteCommandResult(
      exitCode: 0, output: Data("Last login\n".utf8), outputTruncated: false, errorOutput: "")
    #expect(RemoteConnectionOwner.interpret(.exited(banner)).0 == .failed(.unrecognizedOutput))
  }

  @Test(arguments: [
    ("Host key verification failed.", RemoteProbeFailure.hostKey),
    ("onevcat@mini: Permission denied (publickey).", .authentication),
    ("ssh: Could not resolve hostname nowhere: nodename nor servname provided, or not known", .unresolvableHost),
    ("ssh: connect to host mini port 22: Operation timed out", .unreachable),
    ("Something else", .exit(255, "Something else")),
  ])
  func sshErrorsMapToActionableReasons(message: String, expected: RemoteProbeFailure) {
    let result = RemoteCommandResult(exitCode: 255, output: Data(), outputTruncated: false, errorOutput: message + "\n")
    #expect(RemoteConnectionOwner.failure(result) == expected)
  }

  @Test func controlPathStaysWithinTheSocketLimit() {
    let path = SSHSideChannel.controlPath(for: Self.key, directory: RemoteConnectionOwner.defaultControlDirectory())
    // `ssh` adds a 17-byte random suffix while it creates the socket; `sun_path` is 104.
    #expect(path.utf8.count + 17 < 104)
    #expect(
      path == SSHSideChannel.controlPath(for: Self.key, directory: RemoteConnectionOwner.defaultControlDirectory()))
    let other = ConnectionKey(user: "bob", hostname: "mini.local")
    #expect(path != SSHSideChannel.controlPath(for: other, directory: RemoteConnectionOwner.defaultControlDirectory()))
  }

  @Test func connectionKeyComesFromTheEffectiveConfiguration() {
    let text = """
      user alice
      hostname mini.local
      port 2022
      proxyjump a@jump1,b@jump2:2200
      sendenv LANG
      """
    #expect(
      ConnectionKey(effectiveConfiguration: text, configFile: "/tmp/cfg")
        == ConnectionKey(
          user: "alice", hostname: "mini.local", port: 2022, jumpChain: ["a@jump1", "b@jump2:2200"],
          configFile: "/tmp/cfg"))
    #expect(
      ConnectionKey(effectiveConfiguration: "user a\nhostname h\nport 22\nproxyjump none\n", configFile: nil)?.jumpChain
        == [])
    #expect(ConnectionKey(effectiveConfiguration: "user a\nport 22\n", configFile: nil) == nil)
  }
}

struct HostProfileTests {
  @Test func onlyAnotherUserHostnameOrPortChangesTheAuthority() throws {
    let key = ConnectionKey(user: "alice", hostname: "mini.local", port: 22)
    var profile = HostProfile(
      id: UUID(), alias: "mini", recipe: SSHConnectionRecipe(destination: "mini"), connectionKey: key)
    #expect(!profile.authorityChanged(to: key))
    #expect(!profile.authorityChanged(to: ConnectionKey(user: "alice", hostname: "mini.local", jumpChain: ["j"])))
    #expect(profile.authorityChanged(to: ConnectionKey(user: "bob", hostname: "mini.local")))
    #expect(profile.authorityChanged(to: ConnectionKey(user: "alice", hostname: "mini2.local")))
    #expect(profile.authorityChanged(to: ConnectionKey(user: "alice", hostname: "mini.local", port: 2222)))
    // Renaming the alias changes nothing a persisted repository refers to.
    let id = profile.id
    profile.alias = "build box"
    let decoded = try JSONDecoder().decode(HostProfile.self, from: JSONEncoder().encode(profile))
    #expect(decoded == profile)
    #expect(decoded.id == id)
  }
}

/// The C3 presence rule a pane applies to the owner's snapshots.
struct RemoteProcessPresenceTests {
  private func snapshot(
    _ sequence: UInt64, epoch: UInt64 = 0, outcome: RemoteProbeSnapshot.Outcome = .complete, at time: TimeInterval = 0
  ) -> RemoteProbeSnapshot {
    RemoteProbeSnapshot(
      connection: ConnectionKey(user: "u", hostname: "h"), connectionEpoch: epoch, sequence: sequence,
      startedAt: time, finishedAt: time, outcome: outcome,
      report: outcome == .complete || outcome == .partial
        ? RemoteProbeReport(operatingSystem: .linux, bootID: "b", sessions: []) : nil)
  }

  @Test func twoConsecutiveCompleteSnapshotsWithoutTheProcessRelease() {
    var presence = RemoteProcessPresence()
    #expect(presence.observe(snapshot(1), contains: true, now: 0) == .present)
    #expect(presence.observe(snapshot(2), contains: false, now: 0) == .missing)
    #expect(presence.observe(snapshot(3), contains: false, now: 0) == .released)
  }

  @Test func eachSequenceCountsOnceAndInconclusiveRunsNeitherReleaseNorReset() {
    var presence = RemoteProcessPresence()
    #expect(presence.observe(snapshot(1), contains: true, now: 0) == .present)
    #expect(presence.observe(snapshot(2), contains: false, now: 0) == .missing)
    // Many pane ticks on one sequence count once.
    #expect(presence.observe(snapshot(2), contains: false, now: 0) == .unchanged)
    #expect(presence.observe(snapshot(3, outcome: .partial), contains: false, now: 0) == .unchanged)
    #expect(presence.observe(snapshot(4, outcome: .failed(.unreachable)), contains: false, now: 0) == .unchanged)
    #expect(presence.observe(snapshot(5, outcome: .timedOut), contains: false, now: 0) == .unchanged)
    #expect(presence.observe(snapshot(6), contains: false, now: 0) == .released)
  }

  @Test func staleSnapshotsAndOlderEpochsProveNothing() {
    var presence = RemoteProcessPresence()
    #expect(presence.observe(snapshot(1, epoch: 1, at: 0), contains: true, now: 0) == .present)
    // Started more than ten seconds ago: no proof of absence.
    #expect(presence.observe(snapshot(2, epoch: 1, at: 0), contains: false, now: 11) == .unchanged)
    #expect(presence.observe(snapshot(9, epoch: 0, at: 11), contains: false, now: 11) == .unchanged)
    #expect(presence.isStale(now: 10.5))
    #expect(!presence.isStale(now: 9))
    // A new epoch restarts the sequence numbering.
    #expect(presence.observe(snapshot(1, epoch: 2, at: 12), contains: false, now: 12) == .missing)
  }

  @Test func aPartialSnapshotThatShowsTheProcessConfirmsIt() {
    var presence = RemoteProcessPresence()
    #expect(presence.observe(snapshot(1, outcome: .partial), contains: true, now: 0) == .present)
    #expect(presence.lastSeenAt == 0)
  }
}
