import Clocks
import Foundation
import Network
import Observation
import Testing

@testable import supacode

@MainActor
struct MirrorDevicePairingTests {
  @Test(.timeLimit(.minutes(1))) func pairingPersistsReconnectsAndRevokesOnlyItsDevice()
    async throws
  {
    let vault = Vault()
    let source = Source()
    let suite = "MirrorDevicePairingTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let host = MirrorHost(
      source: source, defaults: defaults, enabled: true,
      loadIdentity: { vault.identity }, saveIdentity: { vault.identity = $0 })
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    host.start()
    defer { host.stop() }
    try await listening(host)
    #expect(host.pairingKey.isEmpty)
    host.addDevice()
    try await listening(host)
    let first = Client(port: UInt16(host.port)!, code: host.pairingKey) {
      #expect(host.isRunning && !host.isStarting)
    }
    defer { first.peer.close() }
    try await first.start(stage: "first pairing")
    #expect(host.devices.count == 1)
    #expect(host.pairingKey.isEmpty)
    #expect(first.saved?.pairingKey.isEmpty == true)
    let firstCredential = try #require(first.saved?.credential)
    first.peer.send(.subscribe(.init(paneID: source.id, representation: .text, intent: .ifFree)))
    var firstMessages = first.messages.makeAsyncIterator()
    #expect(await firstMessages.next()?.kind == .subscribed)
    #expect(await firstMessages.next()?.text == "current")
    host.addDevice()
    try await listening(host)
    let second = Client(port: UInt16(host.port)!, code: host.pairingKey) {
      #expect(host.isRunning && !host.isStarting)
    }
    defer { second.peer.close() }
    try await second.start(stage: "second pairing")
    #expect(host.devices.count == 2)
    #expect(host.subscriberCount == 1)
    #expect(!first.closed)
    let identity = try #require(vault.identity?.id)
    host.stop()
    host.start()
    try await listening(host)
    #expect(vault.identity?.id == identity)
    #expect(host.pairingKey.isEmpty)
    let resumed = Client(port: UInt16(host.port)!, credential: firstCredential)
    defer { resumed.peer.close() }
    try await resumed.start(stage: "first device after Host restart")
    let secondCredential = try #require(second.saved?.credential)
    let other = Client(port: UInt16(host.port)!, credential: secondCredential)
    defer { other.peer.close() }
    try await other.start(stage: "second device after Host restart")
    host.revoke(firstCredential.deviceID)
    for await closed in Observations({ resumed.closed }) where closed { break }
    #expect(!other.closed)
    #expect(host.devices.count == 1)
    other.peer.send(.list)
    var otherMessages = other.messages.makeAsyncIterator()
    #expect(await otherMessages.next()?.kind == .panes)
    #expect(vault.identity?.devices.contains(where: { $0.id == firstCredential.deviceID }) == false)
  }

  @Test(.timeLimit(.minutes(1))) func pairingConnectionCannotListAndWindowExpires() async throws {
    let clock = TestClock()
    let vault = Vault()
    let source = Source()
    let suite = "MirrorDevicePairingTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let host = MirrorHost(
      source: source, defaults: defaults, enabled: true, clock: clock,
      loadIdentity: { vault.identity }, saveIdentity: { vault.identity = $0 })
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    host.start()
    defer { host.stop() }
    try await listening(host)
    host.addDevice()
    try await listening(host)
    let peer = MirrorConnection(
      NWConnection(
        host: "127.0.0.1", port: .init(rawValue: UInt16(host.port)!)!,
        using: try MirrorConnection.parameters(pairingKey: host.pairingKey)))
    let closed = AsyncStream.makeStream(of: Bool.self)
    var receivedPanes = false
    peer.onMessage = { message in
      if case .challenge = message { peer.send(.list) }
      if case .panes = message { receivedPanes = true }
    }
    peer.onClose = { _ in closed.continuation.yield(true) }
    peer.start()
    defer {
      peer.close()
      closed.continuation.finish()
    }
    var closures = closed.stream.makeAsyncIterator()
    #expect(await closures.next() == true)
    #expect(!receivedPanes)
    #expect(source.reads == 0)
    await clock.advance(by: .seconds(60))
    #expect(host.pairingKey.isEmpty)
    #expect(host.devices.isEmpty)
  }

  @Test func proofBindsNonceIdentityHostAndPurpose() throws {
    let key = try MirrorAuthentication.randomKey()
    let host = UUID()
    let nonce = try MirrorAuthentication.randomKey()
    let proof = MirrorAuthentication.proof(
      key: key, host: host, nonce: nonce, purpose: "device", identity: "A")
    #expect(
      MirrorAuthentication.verify(
        proof, key: key, challenge: .init(hostID: host, nonce: nonce), purpose: "device",
        identity: "A"))
    #expect(
      !MirrorAuthentication.verify(
        proof, key: key, challenge: .init(hostID: host, nonce: nonce), purpose: "device",
        identity: "B"))
    #expect(
      !MirrorAuthentication.verify(
        proof, key: key, challenge: .init(hostID: UUID(), nonce: nonce), purpose: "device",
        identity: "A"))
    #expect(
      !MirrorAuthentication.verify(
        proof, key: key, challenge: .init(hostID: host, nonce: nonce), purpose: "pair",
        identity: "A"))
    #expect(
      !MirrorAuthentication.verify(
        proof, key: key, challenge: .init(hostID: host, nonce: Data(repeating: 0, count: 32)),
        purpose: "device",
        identity: "A"))
  }

  private func listening(_ host: MirrorHost) async throws {
    for await done in Observations({ !host.isStarting || host.error != nil }) where done { break }
    try #require(host.error == nil)
    try #require(host.isRunning)
  }
  private final class Vault { var identity: MirrorHostIdentity? }
  private final class Source: MirrorPaneSource {
    let id = UUID()
    var reads = 0
    func panes() -> [MirrorPaneDescriptor] {
      [.init(id: id, title: "test", directory: "/", busy: false)]
    }
    func snapshot(_ id: UUID) throws -> MirrorFrame { .init(columns: 80, rows: 24, bytes: Data()) }
    func activeText(_ id: UUID) throws -> String {
      reads += 1
      return "current"
    }
    func write(_ bytes: Data, to id: UUID) throws {}
  }
  @Observable final class Client {
    var saved: MirrorSavedConnection?
    var closed = false
    var ready = false
    var reason: String?
    @ObservationIgnored var peer: MirrorRemoteConnection!
    let messages: AsyncStream<MirrorMessage>
    init(
      port: UInt16, code: String = "", credential: MirrorDeviceCredential? = nil,
      onPersist: @escaping () -> Void = {}
    ) {
      let events = AsyncStream.makeStream(of: MirrorMessage.self)
      messages = events.stream
      peer = MirrorRemoteConnection(
        configuration: .init(
          address: "127.0.0.1", port: port, pairingKey: code, credential: credential),
        restore: { _ in nil },
        persist: { [weak self] in
          self?.saved = $0
          onPersist()
        })
      peer.onReady = { [weak self] in self?.ready = true }
      peer.onMessage = { events.continuation.yield($0) }
      peer.onClose = { [weak self] reason in
        self?.closed = true
        self?.reason = reason
        events.continuation.finish()
      }
    }
    func start(stage: String) async throws {
      peer.start()
      for await done in Observations({ self.ready || self.closed }) where done { break }
      try #require(
        ready,
        "Authentication failed during \(stage) (credential saved: \(saved?.credential != nil)): \(reason ?? "unknown")"
      )
    }
  }
}
