import Clocks
import Foundation
import Network
import Observation
import Security
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
    defer { host.stop() }
    try await MirrorTestPort.startHost(host)
    #expect(host.pairingKey.isEmpty)
    host.addDevice()
    try await listening(host)
    let first = Client(port: UInt16(host.port)!, code: host.pairingKey) {
      #expect(host.isRunning && !host.isStarting)
    }
    defer { first.peer.close() }
    try await first.start(stage: "first pairing")
    #expect(host.devices.count == 1)
    #expect(host.lastPairedDevice?.id == host.devices.first?.id)
    #expect(host.pairingKey.isEmpty)
    #expect(first.saved?.pairingKey.isEmpty == true)
    let firstCredential = try #require(first.saved?.credential)
    first.peer.send(.subscribe(.init(paneID: source.id, representation: .text, intent: .ifFree)))
    var firstMessages = first.messages.makeAsyncIterator()
    #expect(await firstMessages.next()?.kind == .subscribed)
    #expect(await firstMessages.next()?.text == "current")
    #expect(host.mirroredPanes(for: firstCredential.deviceID).map(\.id) == [source.id])
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
    #expect(host.mirroredPanes(for: firstCredential.deviceID).isEmpty)
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
    // A revoked credential is rejected during the TLS handshake and must fail at once, in plain words.
    try await listening(host)
    let rejected = Client(port: UInt16(host.port)!, credential: firstCredential)
    defer { rejected.peer.close() }
    rejected.peer.start()
    for await closed in Observations({ rejected.closed }) where closed { break }
    #expect(!rejected.ready)
    guard case .handshakeRejected = rejected.peer.failure else {
      Issue.record("Expected a TLS rejection, got \(String(describing: rejected.peer.failure))")
      return
    }
    #expect(rejected.reason?.contains("no longer recognizes") == true)
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
    defer { host.stop() }
    try await MirrorTestPort.startHost(host)
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

  @Test(.timeLimit(.minutes(1))) func cancelPairingClosesWindowWithoutStoppingHost() async throws {
    let vault = Vault()
    let suite = "MirrorCancelPairingTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let host = MirrorHost(
      source: Source(), defaults: defaults, enabled: true,
      loadIdentity: { vault.identity }, saveIdentity: { vault.identity = $0 })
    host.address = "127.0.0.1"
    host.port = String(try MirrorTestPort.unusedPort())
    defer { host.stop() }
    try await MirrorTestPort.startHost(host)
    host.addDevice()
    try await listening(host)
    #expect(!host.pairingKey.isEmpty)
    host.cancelPairing()
    try await listening(host)
    #expect(host.isRunning)
    #expect(host.pairingKey.isEmpty)
    #expect(host.pairingExpiresAt == nil)
  }

  @Test func knownHostStoreImportsLegacyRecordsOnceAfterExplicitRequest() throws {
    let suite = "MirrorKnownHostStoreTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var reads = 0
    let credential = MirrorDeviceCredential(hostID: UUID(), deviceID: UUID(), key: Data(repeating: 1, count: 32))
    let legacy = MirrorSavedConnection(address: "192.0.2.1", port: 7880, pairingKey: "", credential: credential)
    let store = MirrorKnownHostStore(
      defaults: defaults,
      importLegacy: {
        reads += 1
        return [legacy]
      }, removeCredential: { _ in })
    #expect(store.hosts.isEmpty)
    #expect(reads == 0)
    store.importLegacyIfNeeded()
    store.importLegacyIfNeeded()
    #expect(reads == 1)
    #expect(store.hosts.map(\.endpointID) == ["192.0.2.1:7880"])
    #expect(store.hosts.first?.hostID == credential.hostID)
    let reloaded = MirrorKnownHostStore(
      defaults: defaults,
      importLegacy: {
        reads += 1
        return []
      }, removeCredential: { _ in })
    #expect(reloaded.hasImportedLegacy)
    #expect(reloaded.hosts.map(\.endpointID) == ["192.0.2.1:7880"])
    reloaded.importLegacyIfNeeded()
    #expect(reads == 1)
  }

  @Test func knownHostStoreRetriesFailedImportAndMergesEnrollment() throws {
    let suite = "MirrorKnownHostStoreTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var reads = 0
    let credential = MirrorDeviceCredential(hostID: UUID(), deviceID: UUID(), key: Data(repeating: 1, count: 32))
    let enrolled = MirrorSavedConnection(address: "mini.local", port: 7880, pairingKey: "", credential: credential)
    let store = MirrorKnownHostStore(
      defaults: defaults,
      importLegacy: {
        reads += 1
        if reads == 1 {
          throw MirrorCredentialVault.Failure(status: errSecInteractionNotAllowed, operation: .readHost)
        }
        return [enrolled]
      }, removeCredential: { _ in })
    store.importLegacyIfNeeded()
    #expect(!store.hasImportedLegacy)
    #expect(store.notice != nil)
    store.recordEnrollment(enrolled)
    #expect(store.isKnown(address: "mini.local", port: 7880))
    #expect(store.hosts.first?.pairedAt != nil)
    store.importLegacyIfNeeded()
    #expect(store.hasImportedLegacy)
    #expect(store.notice == nil)
    #expect(store.hosts.count == 1)
    #expect(store.hosts.first?.pairedAt != nil)
    store.recordConnection(address: "mini.local", port: 7880, hostID: credential.hostID)
    #expect(store.hosts.first?.lastConnectedAt != nil)
    #expect(store.hosts.first?.hostID == credential.hostID)
  }

  @Test func knownHostStoreRenamesAndForgetsWithCredentialRemoval() throws {
    let suite = "MirrorKnownHostStoreTests-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var removed: [String] = []
    var removalFails = true
    let store = MirrorKnownHostStore(
      defaults: defaults, importLegacy: { [] },
      removeCredential: { connection in
        if removalFails { throw MirrorCredentialVault.Failure(status: errSecIO, operation: .removeHost) }
        removed.append(connection.endpointID)
      })
    let credential = MirrorDeviceCredential(hostID: UUID(), deviceID: UUID(), key: Data(repeating: 1, count: 32))
    store.recordEnrollment(.init(address: "192.0.2.1", port: 7880, pairingKey: "", credential: credential))
    store.recordEnrollment(.init(address: "192.0.2.2", port: 7880, pairingKey: "", credential: credential))
    store.rename("192.0.2.2:7880", alias: "  Studio  ")
    #expect(store.hosts.map(\.displayName) == ["192.0.2.1:7880", "Studio"])
    store.rename("192.0.2.2:7880", alias: " ")
    #expect(store.hosts.map(\.displayName) == ["192.0.2.1:7880", "192.0.2.2:7880"])
    store.forget("192.0.2.1:7880")
    #expect(store.hosts.count == 2)
    #expect(store.notice != nil)
    removalFails = false
    store.forget("192.0.2.1:7880")
    #expect(removed == ["192.0.2.1:7880"])
    #expect(store.hosts.map(\.endpointID) == ["192.0.2.2:7880"])
    #expect(store.notice == nil)
    let reloaded = MirrorKnownHostStore(defaults: defaults, importLegacy: { [] }, removeCredential: { _ in })
    #expect(reloaded.hosts.map(\.endpointID) == ["192.0.2.2:7880"])
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["PROWL_RUN_KEYCHAIN_TESTS"] == "1"))
  func savedHostsRoundTripThroughKeychain() throws {
    let service = "com.onevcat.prowl.tests.mirror-\(UUID())"
    let credential = MirrorDeviceCredential(hostID: UUID(), deviceID: UUID(), key: Data(repeating: 1, count: 32))
    let first = MirrorSavedConnection(address: "192.0.2.1", port: 7880, pairingKey: "", credential: credential)
    let second = MirrorSavedConnection(address: "192.0.2.2", port: 7880, pairingKey: "", credential: credential)
    let accounts = ["host:" + first.endpointID, "host:" + second.endpointID, "last-verified-host"]
    defer { for account in accounts { try? MirrorSavedConnection.remove(account: account, service: service) } }
    try first.save(account: accounts[0], service: service)
    try second.save(account: accounts[1], service: service)
    try second.save(account: accounts[2], service: service)
    #expect(try MirrorSavedConnection.loadAll(service: service) == [first, second])
    let corruptQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: accounts[0],
    ]
    #expect(
      SecItemUpdate(
        corruptQuery as CFDictionary,
        [kSecValueData as String: Data("invalid".utf8)] as CFDictionary
      ) == errSecSuccess)
    #expect(try MirrorSavedConnection.loadAll(service: service) == [second])
    for account in accounts.prefix(2) { try MirrorSavedConnection.remove(account: account, service: service) }
    #expect(try MirrorSavedConnection.loadAll(service: service).isEmpty)
    try MirrorSavedConnection.remove(account: accounts[2], service: service)
  }

  @Test func savedHostQueriesReadOnlyEndpointAccountsOneAtATime() throws {
    let credential = MirrorDeviceCredential(hostID: UUID(), deviceID: UUID(), key: Data(repeating: 1, count: 32))
    let saved = MirrorSavedConnection(address: "192.0.2.1", port: 7880, pairingKey: "", credential: credential)
    let bytes = try JSONEncoder().encode(saved)
    var accountsRead: [String] = []
    let result = try MirrorSavedConnection.loadAll { query, output in
      let query = query as NSDictionary
      if query[kSecMatchLimit] as? String == kSecMatchLimitAll as String {
        #expect(query[kSecReturnData] == nil)
        output?.pointee =
          [
            [kSecAttrAccount as String: "host:" + saved.endpointID],
            [kSecAttrAccount as String: "last-verified-host"],
          ] as CFArray
      } else {
        #expect(query[kSecMatchLimit] as? String == kSecMatchLimitOne as String)
        #expect(query[kSecReturnData] as? Bool == true)
        accountsRead.append(query[kSecAttrAccount] as? String ?? "")
        output?.pointee = bytes as CFData
      }
      return errSecSuccess
    }
    #expect(result == [saved])
    #expect(accountsRead == ["host:" + saved.endpointID])
  }

  @Test func keychainFailureKeepsStatusOutOfUserMessage() {
    let error = MirrorCredentialVault.Failure(status: errSecParam, operation: .readHost)
    #expect(error.status == errSecParam)
    #expect(error.localizedDescription == "Could not read saved Host access. Try connecting again.")
    let hostError = MirrorCredentialVault.Failure(status: errSecAuthFailed, operation: .saveIdentity)
    #expect(hostError.localizedDescription == "Could not save this Mac’s Host identity. Try again.")
  }

  @Test func savedHostsExcludeUnpairedAndDeduplicateEndpoints() {
    let credential = MirrorDeviceCredential(hostID: UUID(), deviceID: UUID(), key: Data(repeating: 1, count: 32))
    let first = MirrorSavedConnection(address: "192.0.2.1", port: 7880, pairingKey: "", credential: credential)
    let second = MirrorSavedConnection(address: "192.0.2.2", port: 7880, pairingKey: "", credential: credential)
    let unpaired = MirrorSavedConnection(address: "192.0.2.3", port: 7880, pairingKey: "temporary")
    #expect(MirrorSavedConnection.verifiedHosts(from: [second, first, first, unpaired]) == [first, second])
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
