import Clocks
import Foundation
import Network
import Observation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct MirrorHostTests {
  @Test func disabledHostNeverStartsOrGeneratesCredentials() {
    let host = MirrorHost(source: Source(), enabled: false)
    host.start()
    #expect(!host.isStarting)
    #expect(!host.isRunning)
    #expect(host.pairingKey.isEmpty)
    #expect(host.hostRunID == nil)
  }

  @Test func initialHostStartDoesNotRetryIdentityFailure() async {
    enum Failure: Error { case unavailable }
    var attempts = 0
    let host = MirrorHost(
      source: Source(), enabled: true,
      loadIdentity: {
        attempts += 1
        throw Failure.unavailable
      }, saveIdentity: { _ in })
    host.address = "127.0.0.1"
    host.port = "7880"
    defer { host.stop() }
    await #expect(throws: (any Error).self) { try await MirrorTestPort.startHost(host) }
    #expect(attempts == 1)
    #expect(host.port == "7880")
    #expect(!host.isRunning)
    #expect(host.error != nil)
  }

  @Test(.timeLimit(.minutes(1)))
  func hostDisconnectPreservesOtherMirrorsAndRejectsStaleConfirmation() async throws {
    let source = Source()
    source.includesOtherPane = true
    let suite = "MirrorDisconnectTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let host = MirrorHost(
      source: source, defaults: defaults, enabled: true, loadIdentity: { Self.identity },
      saveIdentity: { _ in })
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    defer { host.stop() }
    try await MirrorTestPort.startHost(host)
    let first = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    let other = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer {
      first.connection.close()
      other.connection.close()
    }
    var firstMessages = first.messages.makeAsyncIterator()
    var otherMessages = other.messages.makeAsyncIterator()
    first.connection.send(.subscribe(.init(paneID: source.id, representation: .text, intent: .ifFree)))
    let lease = try #require(await firstMessages.next()?.subscriptionID)
    #expect(await firstMessages.next()?.kind == .textFrame)
    other.connection.send(.subscribe(.init(paneID: source.otherID, representation: .text, intent: .ifFree)))
    #expect(await otherMessages.next()?.kind == .subscribed)
    #expect(await otherMessages.next()?.kind == .textFrame)
    let deviceID = Self.identity.devices[0].id
    #expect(host.subscriptionID(for: source.id, deviceID: deviceID) == lease)
    #expect(host.subscriptionID(for: source.id, deviceID: UUID()) == nil)
    host.disconnect(subscriptionID: lease)
    #expect(host.subscriberCount == 1)
    #expect(host.mirroredPanes(for: deviceID).map(\.id) == [source.otherID])
    #expect(host.isRunning)
    #expect(host.devices.count == 1)
    #expect(await firstMessages.next()?.error == "This mirror was disconnected by Host.")
    #expect(await firstMessages.next() == nil)
    #expect(source.input.isEmpty)
    other.connection.send(.list)
    #expect(await otherMessages.next()?.kind == .panes)

    let replacement = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer { replacement.connection.close() }
    var replacementMessages = replacement.messages.makeAsyncIterator()
    replacement.connection.send(.subscribe(.init(paneID: source.id, representation: .text, intent: .ifFree)))
    let newLease = try #require(await replacementMessages.next()?.subscriptionID)
    #expect(await replacementMessages.next()?.kind == .textFrame)
    host.disconnect(subscriptionID: lease)
    #expect(host.subscriptionID(for: source.id, deviceID: deviceID) == newLease)
    #expect(host.subscriberCount == 2)
    replacement.connection.send(.list)
    #expect(await replacementMessages.next()?.kind == .panes)
  }

  @Test(.timeLimit(.minutes(1)))
  func fullSilentHandshakePoolStillAllowsAuthenticatedSubscription() async throws {
    let source = Source()
    let suite = "MirrorHandshakeTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let host = MirrorHost(
      source: source, defaults: defaults, enabled: true, loadIdentity: { Self.identity },
      saveIdentity: { _ in })
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    var silent: [NWConnection] = []
    defer {
      for connection in silent { connection.cancel() }
      host.stop()
    }
    try await MirrorTestPort.startHost(host)
    for _ in 0..<MirrorHost.maximumPendingHandshakes {
      let connection = NWConnection(
        host: "127.0.0.1", port: .init(rawValue: UInt16(host.port)!)!, using: .tcp)
      silent.append(connection)
      connection.start(queue: .main)
    }
    for await full in Observations({
      host.pendingHandshakeCount == MirrorHost.maximumPendingHandshakes
    }) where full {
      break
    }
    let client = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer { client.connection.close() }
    var messages = client.messages.makeAsyncIterator()
    client.connection.send(
      .subscribe(.init(paneID: source.id, representation: .terminal, intent: .ifFree)))
    #expect(await messages.next()?.kind == .subscribed)
    #expect(await messages.next()?.kind == .frame)
    #expect(host.subscriberCount == 1)
    #expect(host.pendingHandshakeCount < MirrorHost.maximumPendingHandshakes)
    host.stop()
    #expect(host.pendingHandshakeCount == 0)
  }

  @Test(.timeLimit(.minutes(1)))
  func explicitTakeoverRevokesOldOwnerAndTextReplacesRatherThanAppends() async throws {
    let source = Source()
    let suite = "MirrorTakeoverTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let host = MirrorHost(
      source: source, defaults: defaults, enabled: true, loadIdentity: { Self.identity },
      saveIdentity: { _ in })
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    defer { host.stop() }
    try await MirrorTestPort.startHost(host)
    let first = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    let second = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer {
      first.connection.close()
      second.connection.close()
    }
    var firstMessages = first.messages.makeAsyncIterator()
    var secondMessages = second.messages.makeAsyncIterator()
    first.connection.send(
      .subscribe(.init(paneID: source.id, representation: .terminal, intent: .ifFree)))
    _ = try #require(await firstMessages.next()?.subscriptionID)
    #expect(await firstMessages.next()?.kind == .frame)
    second.connection.send(.list)
    let list = try #require(await secondMessages.next())
    #expect(list.hostRunID != nil)
    #expect(source.reads == 1)
    second.connection.send(
      .subscribe(.init(paneID: source.id, representation: .text, intent: .ifFree)))
    #expect(await secondMessages.next()?.error?.hasPrefix("PANE_BUSY") == true)
    #expect(source.reads == 1)
    second.connection.send(
      .subscribe(.init(paneID: source.id, representation: .text, intent: .takeover)))
    let lease = try #require(await secondMessages.next())
    #expect(lease.kind == .subscribed)
    #expect(lease.hostRunID == host.hostRunID)
    let frame = try #require(await secondMessages.next())
    #expect(frame.text == "thinking")
    #expect(frame.subscriptionID == lease.subscriptionID)
    #expect(await firstMessages.next()?.reason == .takenOver)
    #expect(host.subscriberCount == 1)
    source.text = ""
    second.connection.send(
      .acknowledge(
        .init(
          sequence: try #require(frame.sequence), subscriptionID: try #require(lease.subscriptionID)
        )))
    let cleared = try #require(await secondMessages.next())
    #expect(cleared.kind == .textFrame)
    #expect(cleared.text == "")
    // A text mirror may not bypass mobile submit validation with raw input.
    second.connection.send(
      .input(.init(bytes: Data([3]), subscriptionID: try #require(lease.subscriptionID))))
    #expect(await secondMessages.next() == nil)
    #expect(source.input.isEmpty)
  }

  @Test(.timeLimit(.minutes(1))) func failedTakeoverCaptureKeepsExistingOwner() async throws {
    let source = Source()
    source.textUnavailable = true
    let suite = "MirrorFailedTakeoverTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let host = MirrorHost(
      source: source, defaults: defaults, enabled: true, loadIdentity: { Self.identity },
      saveIdentity: { _ in })
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    defer { host.stop() }
    try await MirrorTestPort.startHost(host)
    let first = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    let second = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer {
      first.connection.close()
      second.connection.close()
    }
    var firstMessages = first.messages.makeAsyncIterator()
    var secondMessages = second.messages.makeAsyncIterator()
    first.connection.send(
      .subscribe(.init(paneID: source.id, representation: .terminal, intent: .ifFree)))
    let firstLease = try #require(await firstMessages.next()?.subscriptionID)
    #expect(await firstMessages.next()?.kind == .frame)
    second.connection.send(.list)
    _ = await secondMessages.next()
    second.connection.send(
      .subscribe(.init(paneID: source.id, representation: .text, intent: .takeover)))
    #expect(await secondMessages.next() == nil)
    first.connection.send(.input(.init(bytes: Data([3]), subscriptionID: firstLease)))
    first.connection.send(.history(.init(historyID: nil, offset: nil, subscriptionID: firstLease)))
    #expect(await firstMessages.next()?.kind == .historyPage)
    #expect(source.input == Data([3]))
    #expect(host.subscriberCount == 1)
  }

  @Test(.timeLimit(.minutes(1))) func subscriptionIsExclusiveAndDiscoveryDoesNotReadTerminal()
    async throws
  {
    let source = Source()
    let suite = "MirrorHostTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let host = MirrorHost(
      source: source, defaults: defaults, enabled: true, loadIdentity: { Self.identity },
      saveIdentity: { _ in })
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    defer { host.stop() }
    try await MirrorTestPort.startHost(host)
    #expect(source.reads == 0)
    let first = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    let second = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer {
      first.connection.close()
      second.connection.close()
    }
    var firstMessages = first.messages.makeAsyncIterator()
    var secondMessages = second.messages.makeAsyncIterator()
    first.connection.send(.list)
    let list = try #require(await firstMessages.next())
    #expect(list.kind == .panes)
    #expect(source.reads == 0)
    first.connection.send(
      .subscribe(.init(paneID: source.id, representation: .terminal, intent: .ifFree)))
    let firstLease = try #require(await firstMessages.next()?.subscriptionID)
    let frame = try #require(await firstMessages.next())
    #expect(frame.kind == .frame)
    #expect(host.subscriberCount == 1)
    second.connection.send(
      .subscribe(.init(paneID: source.id, representation: .terminal, intent: .ifFree)))
    let failure = try #require(await secondMessages.next())
    #expect(failure.kind == .failure)
    #expect(failure.error?.hasPrefix("PANE_BUSY") == true)
    first.connection.send(.input(.init(bytes: Data([3]), subscriptionID: firstLease)))
    first.connection.send(.history(.init(historyID: nil, offset: nil, subscriptionID: firstLease)))
    let history = try #require(await firstMessages.next())
    #expect(history.kind == .historyPage)
    #expect(source.input == Data([3]))
    #expect(source.reads == 1)
    host.stop()
    #expect(host.subscriberCount == 0)
    #expect(!host.isRunning)
    #expect(source.panes().count == 1)
  }

  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      "revoke", "revoke-all", "stop", "disconnect-revoke", "disconnect-revoke-all", "disconnect-stop", "disconnect",
    ])
  func authorityRemovalCancelsPreparedProfile(mode: String) async throws {
    let suite = "MirrorCreateCancellation-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let host = MirrorHost(
      source: Source(), defaults: defaults, enabled: true, loadIdentity: { Self.identity },
      saveIdentity: { _ in })
    let profile = AgentProfile(name: "Reviewer", runtime: .codex)
    let target = TabResolvedTarget(
      worktreeID: "worktree-1", worktreeName: "Fixture", worktreePath: "/tmp/fixture",
      worktreeRootPath: "/tmp/fixture", worktreeKind: "git", tabID: "tab-1", tabTitle: "Fixture",
      tabSelected: true, paneID: UUID().uuidString, paneTitle: "Fixture", paneCWD: "/tmp/fixture",
      paneFocused: true)
    let started = AsyncStream.makeStream(of: Void.self)
    var preparation: CheckedContinuation<Void, Never>?
    var preparations = 0
    var issues = 0
    var launches = 0
    var cleanups = 0
    let handler = LifecycleCommandHandler(
      resolveCreateTarget: { _ in .success(target) },
      resolveCloseTarget: { _ in .success(.init(resource: .pane, target: target)) },
      createTab: { _, _ in nil }, createPane: { _, _ in nil }, profiles: { [profile] },
      prepareAgentProfile: { request in
        preparations += 1
        await withCheckedContinuation { continuation in
          preparation = continuation
          started.continuation.yield(())
        }
        // Preparation can complete successfully even after its caller was cancelled.
        return .success(request)
      },
      launchAgentProfile: { _ in
        launches += 1
        return .success(target)
      },
      cancelProfilePreparation: { _ in cleanups += 1 },
      issueDispatch: {
        issues += 1
        return .success(
          DispatchPendingRecord(id: "test-dispatch", createdAt: "2026-09-13T00:00:00Z"))
      },
      bindDispatch: { _, _ in .success(()) },
      closeTab: { _, _ in true }, closePane: { _, _ in true })
    let service = MirrorCommandService(router: CLICommandRouter(createHandler: handler))
    host.commandService = service
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    defer { host.stop() }
    try await MirrorTestPort.startHost(host)
    let peer = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer { peer.connection.close() }
    let request = MirrorCommandRequest(
      requestID: UUID(),
      request: .init(
        command: .create(
          .init(worktreeID: target.worktreeID, profileID: profile.id.uuidString, prompt: "Review")))
    )
    peer.connection.send(.command(.init(commandRequest: request)))
    var preparationEvents = started.stream.makeAsyncIterator()
    _ = await preparationEvents.next()
    if mode.hasPrefix("disconnect") {
      peer.connection.close()
      for await offline in Observations({ host.onlineDeviceIDs.isEmpty }) where offline { break }
    }
    if mode.hasSuffix("revoke") { host.revoke(Self.identity.devices[0].id) }
    if mode.hasSuffix("revoke-all") { host.revokeAllDevices() }
    if mode.hasSuffix("stop") { host.stop() }
    try #require(preparation != nil)
    preparation?.resume()
    preparation = nil
    // Await the original retained execution. A duplicate must never restart preparation.
    let response = await service.execute(request)
    let cancelled = mode != "disconnect"
    #expect(try response.response.decode(CommandResponse.self).ok == !cancelled)
    #expect(preparations == 1)
    #expect(issues == (cancelled ? 0 : 1))
    #expect(launches == (cancelled ? 0 : 1))
    #expect(cleanups == (cancelled ? 1 : 0))
    _ = await service.execute(request)
    #expect(preparations == 1)
    #expect(launches == (cancelled ? 0 : 1))
  }

  @Test(.timeLimit(.minutes(1)), arguments: ["takeover", "disconnect", "host-disconnect", "revoke", "stop"])
  func authorityLossCancelsDispatchWaitingForReadiness(mode: String) async throws {
    let source = Source()
    let suite = "MirrorDispatchCancellation-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let host = MirrorHost(
      source: source, defaults: defaults, enabled: true, loadIdentity: { Self.identity }, saveIdentity: { _ in })
    let target = TabResolvedTarget(
      worktreeID: "worktree-1", worktreeName: "Fixture", worktreePath: "/tmp/fixture",
      worktreeRootPath: "/tmp/fixture", worktreeKind: "git", tabID: "tab-1", tabTitle: "Fixture",
      tabSelected: true, paneID: source.id.uuidString, paneTitle: "Fixture", paneCWD: "/tmp/fixture", paneFocused: true)
    let agent = ActiveAgentEntry(
      id: source.id, worktreeID: target.worktreeID, worktreeName: "Fixture",
      workingDirectory: URL(fileURLWithPath: "/tmp/fixture"), tabID: TerminalTabID(rawValue: UUID()),
      paneTitle: "Fixture", surfaceID: source.id, paneIndex: 0, iconLookupToken: "claude", agent: .claude,
      rawState: .working, displayState: .working, lastChangedAt: Date())
    let ended = AgentSignal(
      kind: .turnEnded, source: .hook(runtime: .claude, event: "Stop"), confidence: .exact,
      timestamp: Date(), sessionID: nil, detail: nil, claimedOrigin: nil)
    let observed = AsyncStream.makeStream(of: Void.self)
    let clock = TestClock()
    var observations = 0
    var issues = 0
    var deliveries = 0
    let handler = AgentDispatchCommandHandler(
      resolveTarget: { _ in .success(target) },
      conditionSnapshot: { _ in
        observations += 1
        observed.continuation.yield(())
        // An old completion without current idle corroboration must wait.
        return AgentConditionSnapshot(
          agent: agent, signal: ended, revision: 1, isLive: true, signals: .empty)
      },
      issueDispatch: { _ in
        issues += 1
        return .failure(.bindingMissing)
      },
      deliverPrompt: { _, _ in
        deliveries += 1
        return true
      }, clock: clock)
    let service = MirrorCommandService(router: CLICommandRouter(agentsDispatchHandler: handler))
    host.commandService = service
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    defer { host.stop() }
    try await MirrorTestPort.startHost(host)
    let peer = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer { peer.connection.close() }
    var messages = peer.messages.makeAsyncIterator()
    peer.connection.send(.subscribe(.init(paneID: source.id, representation: .text, intent: .ifFree)))
    let lease = try #require(await messages.next()?.subscriptionID)
    #expect(await messages.next()?.kind == .textFrame)
    let request = MirrorCommandRequest(
      requestID: UUID(),
      request: .init(
        command: .agentsDispatch(.init(pane: source.id.uuidString, prompt: "Review"))))
    peer.connection.send(.command(.init(subscriptionID: lease, commandRequest: request)))
    var observationsIterator = observed.stream.makeAsyncIterator()
    _ = await observationsIterator.next()
    var replacement: Peer?
    defer { replacement?.connection.close() }
    switch mode {
    case "takeover":
      let next = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
      replacement = next
      var nextMessages = next.messages.makeAsyncIterator()
      next.connection.send(.subscribe(.init(paneID: source.id, representation: .text, intent: .takeover)))
      #expect(await nextMessages.next()?.kind == .subscribed)
    case "disconnect":
      peer.connection.close()
      for await offline in Observations({ host.onlineDeviceIDs.isEmpty }) where offline { break }
    case "host-disconnect": host.disconnect(subscriptionID: lease)
    case "revoke": host.revoke(Self.identity.devices[0].id)
    default: host.stop()
    }
    let response = await service.execute(request)
    #expect(try response.response.decode(CommandResponse.self).ok == false)
    #expect(issues == 0)
    #expect(deliveries == 0)
    let previousObservations = observations
    _ = await service.execute(request)
    #expect(observations == previousObservations)
    #expect(issues == 0 && deliveries == 0)
  }

  @Test(.timeLimit(.minutes(1)), arguments: [MirrorMessage.Representation.terminal, .text])
  func remoteScrollForcesFreshFrameAndDeduplicatesRequests(representation: MirrorMessage.Representation) async throws {
    let source = Source()
    let clock = TestClock()
    let host = MirrorHost(
      source: source, enabled: true, clock: clock, loadIdentity: { Self.identity }, saveIdentity: { _ in })
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    defer { host.stop() }
    try await MirrorTestPort.startHost(host)
    let peer = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer { peer.connection.close() }
    var messages = peer.messages.makeAsyncIterator()
    peer.connection.send(.list)
    #expect(await messages.next()?.capabilities?.contains("remote-scroll") == true)
    peer.connection.send(.subscribe(.init(paneID: source.id, representation: representation, intent: .ifFree)))
    let lease = try #require(await messages.next()?.subscriptionID)
    let initial = try #require(await messages.next())
    let initialSequence = try #require(initial.sequence)
    let request = MirrorMessage.ScrollPayload(requestID: UUID(), direction: .upward, subscriptionID: lease)
    peer.connection.send(.scroll(request))
    peer.connection.send(.scroll(request))
    let busyID = UUID()
    peer.connection.send(.scroll(.init(requestID: busyID, direction: .downward, subscriptionID: lease)))
    let busy = try #require(await messages.next())
    #expect(busy.error?.hasPrefix("SCROLL_BUSY:") == true)
    #expect(busy.scrollRequestID == busyID)
    #expect(busy.subscriptionID == lease)
    #expect(source.scrolls == [.upward])
    await clock.advance(by: .milliseconds(200))
    // Scroll completion must respect the original outstanding frame's ACK.
    peer.connection.send(.list)
    #expect(await messages.next()?.kind == .panes)
    peer.connection.send(.acknowledge(.init(sequence: initialSequence, subscriptionID: lease)))
    peer.connection.send(.list)
    #expect(await messages.next()?.kind == .panes)
    await clock.advance(by: .milliseconds(600))
    let changed = try #require(await messages.next())
    let result = try #require(await messages.next())
    #expect(changed.kind == initial.kind)
    #expect(changed.sequence == initialSequence + 1)
    #expect(changed.frame == initial.frame)
    #expect(changed.text == initial.text)
    #expect(result.kind == .scrollResult)
    #expect(result.sequence == changed.sequence)
    #expect(result.scrollRequestID == request.requestID)
    #expect(result.subscriptionID == lease)
    peer.connection.send(.scroll(request))
    let replay = try #require(await messages.next())
    #expect(replay.kind == .scrollResult)
    #expect(replay.sequence == result.sequence)
    #expect(source.scrolls == [.upward])
    peer.connection.send(.acknowledge(.init(sequence: try #require(changed.sequence), subscriptionID: lease)))
    let downID = UUID()
    peer.connection.send(.scroll(.init(requestID: downID, direction: .downward, subscriptionID: lease)))
    peer.connection.send(.list)
    #expect(await messages.next()?.kind == .panes)
    await clock.advance(by: .milliseconds(800))
    let downFrame = try #require(await messages.next())
    let downResult = try #require(await messages.next())
    #expect(downFrame.sequence == initialSequence + 2)
    #expect(downResult.scrollRequestID == downID)
    #expect(downResult.sequence == downFrame.sequence)
    #expect(source.scrolls == [.upward, .downward])
    #expect(source.input.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func unavailableScrollReturnsCorrelatedFailureWithoutClosingConnection(fails: Bool) async throws {
    let source = Source()
    source.supportsRemoteScroll = fails
    source.scrollUnavailable = fails
    let host = MirrorHost(source: source, enabled: true, loadIdentity: { Self.identity }, saveIdentity: { _ in })
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    defer { host.stop() }
    try await MirrorTestPort.startHost(host)
    let peer = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer { peer.connection.close() }
    var messages = peer.messages.makeAsyncIterator()
    peer.connection.send(.list)
    #expect(await messages.next()?.capabilities?.contains("remote-scroll") == fails)
    peer.connection.send(.subscribe(.init(paneID: source.id, representation: .text, intent: .ifFree)))
    let lease = try #require(await messages.next()?.subscriptionID)
    #expect(await messages.next()?.kind == .textFrame)
    let request = MirrorMessage.ScrollPayload(requestID: UUID(), direction: .upward, subscriptionID: lease)
    for _ in 0..<2 {
      peer.connection.send(.scroll(request))
      let failure = try #require(await messages.next())
      #expect(failure.error?.hasPrefix("SCROLL_UNAVAILABLE:") == true)
      #expect(failure.scrollRequestID == request.requestID)
      #expect(failure.subscriptionID == lease)
    }
    #expect(source.scrolls.count == (fails ? 1 : 0))
    peer.connection.send(.history(.init(historyID: nil, offset: nil, subscriptionID: lease)))
    #expect(await messages.next()?.lines == ["earlier", "now"])
    #expect(source.input.isEmpty)
  }

  @Test(.timeLimit(.minutes(1))) func scrollRejectsStaleLeaseBeforeSendingInput() async throws {
    let source = Source()
    let host = MirrorHost(source: source, enabled: true, loadIdentity: { Self.identity }, saveIdentity: { _ in })
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    defer { host.stop() }
    try await MirrorTestPort.startHost(host)
    let peer = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer { peer.connection.close() }
    var messages = peer.messages.makeAsyncIterator()
    peer.connection.send(.subscribe(.init(paneID: source.id, representation: .text, intent: .ifFree)))
    #expect(await messages.next()?.kind == .subscribed)
    #expect(await messages.next()?.kind == .textFrame)
    peer.connection.send(.scroll(.init(requestID: UUID(), direction: .upward, subscriptionID: UUID())))
    #expect(await messages.next() == nil)
    #expect(source.scrolls.isEmpty)
    #expect(source.input.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func viewportMetadataRequiresTerminalOptIn(optedIn: Bool) async throws {
    let source = Source()
    source.viewportText = "earlier"
    let clock = TestClock()
    let host = MirrorHost(
      source: source, enabled: true, clock: clock, loadIdentity: { Self.identity }, saveIdentity: { _ in })
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    defer { host.stop() }
    try await MirrorTestPort.startHost(host)
    let peer = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer { peer.connection.close() }
    var messages = peer.messages.makeAsyncIterator()
    peer.connection.send(.list)
    #expect(await messages.next()?.capabilities?.contains("viewport-text-v1") == true)
    peer.connection.send(
      .subscribe(.init(paneID: source.id, representation: .terminal, intent: .ifFree, includeViewportText: optedIn)))
    let lease = try #require(await messages.next()?.subscriptionID)
    if optedIn {
      let viewport = try #require(await messages.next())
      #expect(viewport.kind == .viewport)
      #expect(viewport.viewportText == "earlier")
      #expect(viewport.sequence == 1)
      #expect(viewport.subscriptionID == lease)
    }
    #expect(await messages.next()?.kind == .frame)
    peer.connection.send(.acknowledge(.init(sequence: 1, subscriptionID: lease)))
    peer.connection.send(.list)
    #expect(await messages.next()?.kind == .panes)
    source.viewportText = ""
    await clock.advance(by: .milliseconds(200))
    if optedIn {
      #expect(await messages.next()?.viewportText == "")
      #expect(await messages.next()?.sequence == 2)
      peer.connection.send(.acknowledge(.init(sequence: 2, subscriptionID: lease)))
      peer.connection.send(.list)
      #expect(await messages.next()?.kind == .panes)
      source.viewportText = nil
      await clock.advance(by: .milliseconds(200))
      let clear = try #require(await messages.next())
      #expect(clear.kind == .viewport)
      #expect(clear.viewportText == nil)
      #expect(clear.sequence == 3)
      #expect(await messages.next()?.sequence == 3)
    }
    // An old terminal client never receives the additive control, including
    // when only native scrollback changes and the active VT bytes stay equal.
    peer.connection.send(.list)
    #expect(await messages.next()?.kind == .panes)
  }

  @Test(.timeLimit(.minutes(1))) func textSubscriptionNeverReceivesViewportMetadata() async throws {
    let source = Source()
    source.viewportText = "earlier"
    let host = MirrorHost(source: source, enabled: true, loadIdentity: { Self.identity }, saveIdentity: { _ in })
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    defer { host.stop() }
    try await MirrorTestPort.startHost(host)
    let peer = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer { peer.connection.close() }
    var messages = peer.messages.makeAsyncIterator()
    peer.connection.send(
      .subscribe(.init(paneID: source.id, representation: .text, intent: .ifFree, includeViewportText: true)))
    #expect(await messages.next()?.kind == .subscribed)
    #expect(await messages.next()?.kind == .textFrame)
    peer.connection.send(.list)
    #expect(await messages.next()?.kind == .panes)
  }

  @Test(.timeLimit(.minutes(1)), arguments: [1, 20])
  func inconsistentCaptureRetriesAreBounded(failures: Int) async throws {
    let source = Source()
    source.unstableCaptures = failures
    let clock = TestClock()
    let host = MirrorHost(
      source: source, enabled: true, clock: clock, loadIdentity: { Self.identity }, saveIdentity: { _ in })
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    defer { host.stop() }
    try await MirrorTestPort.startHost(host)
    let peer = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer { peer.connection.close() }
    var messages = peer.messages.makeAsyncIterator()
    peer.connection.send(.subscribe(.init(paneID: source.id, representation: .terminal, intent: .ifFree)))
    #expect(await messages.next()?.kind == .subscribed)
    await clock.advance(by: .seconds(2))
    if failures == 1 {
      #expect(await messages.next()?.kind == .frame)
    } else {
      #expect(await messages.next() == nil)
      #expect(source.unstableCaptures == failures - 10)
    }
  }

  @Test(.timeLimit(.minutes(1))) func failedFrameSendDoesNotResurrectClosedLease() async throws {
    let source = Source()
    let clock = TestClock()
    let host = MirrorHost(
      source: source, enabled: true, clock: clock, loadIdentity: { Self.identity }, saveIdentity: { _ in })
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    defer { host.stop() }
    try await MirrorTestPort.startHost(host)
    let peer = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer { peer.connection.close() }
    var messages = peer.messages.makeAsyncIterator()
    peer.connection.send(.subscribe(.init(paneID: source.id, representation: .terminal, intent: .ifFree)))
    let lease = try #require(await messages.next()?.subscriptionID)
    #expect(await messages.next()?.sequence == 1)
    peer.connection.send(.acknowledge(.init(sequence: 1, subscriptionID: lease)))
    peer.connection.send(.list)
    #expect(await messages.next()?.kind == .panes)
    source.frameBytes = Data(repeating: 65, count: MirrorWire.maximumPayload)
    await clock.advance(by: .milliseconds(200))
    #expect(await messages.next() == nil)
    #expect(host.subscriberCount == 0)
    source.frameBytes = Data("thinking".utf8)
    let replacement = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer { replacement.connection.close() }
    var replacementMessages = replacement.messages.makeAsyncIterator()
    replacement.connection.send(.subscribe(.init(paneID: source.id, representation: .terminal, intent: .ifFree)))
    #expect(await replacementMessages.next()?.kind == .subscribed)
    #expect(await replacementMessages.next()?.kind == .frame)
    #expect(host.subscriberCount == 1)
  }

  @Test(.timeLimit(.minutes(1)), arguments: [MirrorMessage.Representation.terminal, .text], [false, true])
  func scrollStateRequiresOptInAndTracksBoundaryOnlyChanges(
    representation: MirrorMessage.Representation, optedIn: Bool
  ) async throws {
    let source = Source()
    source.scrollBounds = .init(atTop: false, atBottom: true)
    let clock = TestClock()
    let host = MirrorHost(
      source: source, enabled: true, clock: clock, loadIdentity: { Self.identity }, saveIdentity: { _ in })
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    defer { host.stop() }
    try await MirrorTestPort.startHost(host)
    let peer = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer { peer.connection.close() }
    var messages = peer.messages.makeAsyncIterator()
    peer.connection.send(.list)
    #expect(await messages.next()?.capabilities?.contains("scroll-state-v1") == true)
    peer.connection.send(
      .subscribe(
        .init(
          paneID: source.id, representation: representation, intent: .ifFree, includeScrollState: optedIn)))
    let lease = try #require(await messages.next()?.subscriptionID)
    if optedIn {
      let state = try #require(await messages.next())
      #expect(state.kind == .scrollState)
      #expect(state.scrollBounds == source.scrollBounds)
      #expect(state.sequence == 1)
      #expect(state.subscriptionID == lease)
    }
    let first = try #require(await messages.next())
    #expect(first.kind == (representation == .text ? .textFrame : .frame))
    peer.connection.send(.acknowledge(.init(sequence: 1, subscriptionID: lease)))
    peer.connection.send(.list)
    #expect(await messages.next()?.kind == .panes)
    source.scrollBounds = .init(atTop: true, atBottom: false)
    await clock.advance(by: .milliseconds(200))
    if optedIn {
      #expect(await messages.next()?.scrollBounds == source.scrollBounds)
      let changed = try #require(await messages.next())
      #expect(changed.sequence == 2)
      #expect(changed.frame == first.frame)
      #expect(changed.text == first.text)
      peer.connection.send(.acknowledge(.init(sequence: 2, subscriptionID: lease)))
      peer.connection.send(.list)
      #expect(await messages.next()?.kind == .panes)
      source.scrollBounds = nil
      await clock.advance(by: .milliseconds(200))
      let unknown = try #require(await messages.next())
      #expect(unknown.kind == .scrollState)
      #expect(unknown.scrollBounds == .init())
      #expect(unknown.sequence == 3)
      #expect(await messages.next()?.sequence == 3)
    }
    peer.connection.send(.list)
    #expect(await messages.next()?.kind == .panes)
  }

  @Test(.timeLimit(.minutes(1))) func sourceWithoutScrollStateIgnoresOptIn() async throws {
    let source = Source()
    source.supportsScrollState = false
    let host = MirrorHost(source: source, enabled: true, loadIdentity: { Self.identity }, saveIdentity: { _ in })
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    defer { host.stop() }
    try await MirrorTestPort.startHost(host)
    let peer = try await Peer(port: UInt16(host.port)!, key: host.pairingKey)
    defer { peer.connection.close() }
    var messages = peer.messages.makeAsyncIterator()
    peer.connection.send(.list)
    #expect(await messages.next()?.capabilities?.contains("scroll-state-v1") == false)
    peer.connection.send(
      .subscribe(
        .init(
          paneID: source.id, representation: .text, intent: .ifFree, includeScrollState: true)))
    #expect(await messages.next()?.kind == .subscribed)
    #expect(await messages.next()?.kind == .textFrame)
  }

  @MainActor private final class Source: MirrorPaneSource {
    let id = UUID()
    let otherID = UUID()
    var includesOtherPane = false
    var reads = 0
    var input = Data()
    var text = "thinking"
    var frameBytes = Data("thinking".utf8)
    var textUnavailable = false
    var supportsViewportText = true
    var supportsScrollState = true
    var scrollBounds: MirrorScrollBounds?
    var viewportText: String?
    var unstableCaptures = 0
    var supportsRemoteScroll = true
    var scrollUnavailable = false
    var scrolls: [MirrorMessage.ScrollDirection] = []
    func scroll(_ direction: MirrorMessage.ScrollDirection, to id: UUID) throws {
      #expect(id == self.id)
      scrolls.append(direction)
      if scrollUnavailable { throw MirrorProtocolError.invalidMessage }
    }
    func activeText(_ id: UUID) throws -> String {
      if textUnavailable { throw MirrorProtocolError.invalidMessage }
      reads += 1
      return text
    }
    func textSnapshot(_ id: UUID) throws -> MirrorTextSnapshot {
      .init(text: try activeText(id), scrollBounds: scrollBounds)
    }
    func panes() -> [MirrorPaneDescriptor] {
      let primary = MirrorPaneDescriptor(id: id, title: "Fixture", directory: "/", busy: false)
      return includesOtherPane
        ? [primary, MirrorPaneDescriptor(id: otherID, title: "Other", directory: "/", busy: false)] : [primary]
    }
    func snapshot(_ id: UUID) throws -> MirrorFrame {
      reads += 1
      if unstableCaptures > 0 {
        unstableCaptures -= 1
        throw MirrorPaneSourceError.captureChanged
      }
      return MirrorFrame(
        columns: 80, rows: 24, bytes: frameBytes, viewportText: viewportText, scrollBounds: scrollBounds)
    }
    func write(_ bytes: Data, to id: UUID) throws { input.append(bytes) }
    var supportsBoundedHistory: Bool { true }
    func boundedRetainedText(_ id: UUID) throws -> MirrorRetainedText {
      .init(text: "earlier\nnow", truncated: false)
    }
  }

  private static let identity = MirrorHostIdentity(
    id: UUID(),
    devices: [
      .init(id: UUID(), name: "Test device", key: Data(repeating: 7, count: 32), pairedAt: Date())
    ])

  @MainActor private final class Peer {
    let connection: MirrorConnection
    let messages: AsyncStream<MirrorMessage>
    init(port: UInt16, key: String) async throws {
      let stream = AsyncStream.makeStream(of: MirrorMessage.self)
      let ready = AsyncStream.makeStream(of: Bool.self)
      messages = stream.stream
      let device = MirrorHostTests.identity.devices[0]
      let peer = MirrorConnection(
        NWConnection(
          host: "127.0.0.1", port: .init(rawValue: port)!,
          using: try MirrorConnection.parameters(keys: [(device.id.uuidString, device.key)])))
      connection = peer
      peer.onMessage = { message in
        switch message {
        case .challenge(let challenge):
          peer.send(
            .authenticate(
              .init(
                deviceID: device.id,
                proof: MirrorAuthentication.proof(
                  key: device.key, host: challenge.hostID,
                  nonce: challenge.nonce, purpose: "device", identity: device.id.uuidString))))
        case .authenticated: ready.continuation.yield(true)
        default: stream.continuation.yield(message)
        }
      }
      peer.onClose = { _ in
        ready.continuation.yield(false)
        stream.continuation.finish()
      }
      peer.start()
      var readiness = ready.stream.makeAsyncIterator()
      try #require(await readiness.next() == true)
      ready.continuation.finish()
    }
  }
}
