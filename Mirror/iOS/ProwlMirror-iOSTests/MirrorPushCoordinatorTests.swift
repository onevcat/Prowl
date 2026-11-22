import CryptoKit
import Foundation
import Testing

@testable import ProwlMirror_iOS

/// In-memory token state and push keys, with the time and APNs under test control.
final class PushCoordinatorWorld: @unchecked Sendable {
  private let lock = NSLock()
  private var state = MirrorPushTokenState()
  private(set) var keys: [UUID: SymmetricKey] = [:]
  var apnsToken: String? = "aa11"
  var showsDetails = false
  var failsToSaveDetails = false
  var now = Date(timeIntervalSince1970: 1_000_000)
  var environment = MirrorAPNsEnvironment.development
  let gateway = FakeGateway()
  let attest = FakeAttest()
  let installation = MemoryStorage()
  let defaults = UserDefaults(suiteName: "push-coordinator-\(UUID().uuidString)")!
  /// While set, APNs registration waits until `releaseAPNs()`.
  var holdsAPNs = false
  private var apnsWaiter: CheckedContinuation<Void, Never>?

  var stored: MirrorPushTokenState { lock.withLock { state } }
  func record(_ hostID: UUID) -> MirrorPushTokenRecord? { stored.records[hostID] }
  var isWaitingForAPNs: Bool { lock.withLock { apnsWaiter != nil } }

  func releaseAPNs() {
    holdsAPNs = false
    lock.withLock { apnsWaiter.take() }?.resume()
  }

  @MainActor func coordinator(enabled: Bool = true) -> MirrorPushCoordinator {
    defaults.set(enabled, forKey: MirrorPushCoordinator.enabledKey)
    return MirrorPushCoordinator(
      defaults: defaults,
      gateway: MirrorPushGatewayClient(
        baseURL: URL(string: "https://gateway.test")!, attest: attest, storage: installation.storage,
        send: gateway.send),
      tokens: MirrorPushTokenStorage(
        load: { self.lock.withLock { self.state } },
        save: { new in self.lock.withLock { self.state = new } }),
      registerAPNs: {
        if self.holdsAPNs {
          await withCheckedContinuation { continuation in self.lock.withLock { self.apnsWaiter = continuation } }
        }
        return self.apnsToken
      },
      environment: { self.environment },
      saveKey: { key, id in self.lock.withLock { self.keys[id] = key } },
      removeKey: { id in _ = self.lock.withLock { self.keys.removeValue(forKey: id) } },
      now: { self.now },
      showsDetails: { self.showsDetails },
      saveShowsDetails: { value in
        if self.failsToSaveDetails { throw MirrorPushKeyStore.Failure(status: -1) }
        self.showsDetails = value
      })
  }
}

@MainActor
struct MirrorPushCoordinatorTests {
  private let world = PushCoordinatorWorld()
  private let credential = MirrorDeviceCredential(
    hostID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, deviceID: UUID(),
    key: Data(repeating: 7, count: 32))
  private let push: Set<String> = ["text-v1", "push-v1"]

  @Test func offSendsAndStoresNothing() async {
    #expect(await world.coordinator(enabled: false).registration(for: credential, capabilities: push) == nil)
    #expect(await world.coordinator().registration(for: credential, capabilities: ["text-v1"]) == nil)
    #expect(world.gateway.requests.isEmpty)
    #expect(world.keys.isEmpty)
  }

  @Test func firstConnectionSavesTheKeyCreatesATokenAndRegisters() async throws {
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    let message = await world.coordinator().registration(for: credential, capabilities: push)

    guard case .pushRegister(let payload) = message else {
      Issue.record("Expected pushRegister, got \(String(describing: message))")
      return
    }
    #expect(payload == .init(pushToken: "push-1", kinds: ["blocked", "done"]))
    // The same key as the Host's wire vector.
    let key = try #require(world.keys[credential.hostID])
    #expect(
      key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        == "1e7f1b8f0c110534f475d3c51bdf3c98a0fb10d5ad60aa72cc4add9f1c702aa1")
    #expect(
      world.record(credential.hostID)
        == .init(
          pushToken: "push-1", apnsToken: "aa11", environment: "development", deviceID: credential.deviceID,
          checkedAt: world.now))
    let body = try #require(world.gateway.requests.last?.httpBody)
    #expect(try JSONDecoder().decode([String: String].self, from: body) == ["apnsToken": "aa11", "environment": "development"])
  }

  @Test func aFreshTokenIsReusedWithoutTheGateway() async {
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    let coordinator = world.coordinator()
    _ = await coordinator.registration(for: credential, capabilities: push)
    let requests = world.gateway.requests.count
    world.now.addTimeInterval(60 * 60)

    guard case .pushRegister(let payload) = await coordinator.registration(for: credential, capabilities: push) else {
      Issue.record("Expected pushRegister")
      return
    }
    #expect(payload.pushToken == "push-1")
    #expect(world.gateway.requests.count == requests)
  }

  @Test func aDayLaterOrANewAPNsTokenIsCheckedWithPut() async throws {
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    world.gateway.answer("PUT /v1/tokens/push-1", 204)
    world.gateway.answer("PUT /v1/tokens/push-1", 204)
    let coordinator = world.coordinator()
    _ = await coordinator.registration(for: credential, capabilities: push)

    world.now.addTimeInterval(MirrorPushCoordinator.checkInterval)
    _ = await coordinator.registration(for: credential, capabilities: push)
    #expect(world.gateway.routes().last == "PUT /v1/tokens/push-1")
    #expect(world.record(credential.hostID)?.checkedAt == world.now)

    world.apnsToken = "bb22"
    guard case .pushRegister(let payload) = await coordinator.registration(for: credential, capabilities: push) else {
      Issue.record("Expected pushRegister")
      return
    }
    #expect(payload.pushToken == "push-1")
    let body = try #require(world.gateway.requests.last?.httpBody)
    #expect(try JSONDecoder().decode([String: String].self, from: body) == ["apnsToken": "bb22"])
    #expect(world.record(credential.hostID)?.apnsToken == "bb22")
  }

  @Test func aTokenTheGatewayDeletedIsReplaced() async {
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    world.gateway.answer("PUT /v1/tokens/push-1", 404)
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-2"}"#)
    let coordinator = world.coordinator()
    _ = await coordinator.registration(for: credential, capabilities: push)
    world.now.addTimeInterval(MirrorPushCoordinator.checkInterval + 1)

    guard case .pushRegister(let payload) = await coordinator.registration(for: credential, capabilities: push) else {
      Issue.record("Expected pushRegister")
      return
    }
    #expect(payload.pushToken == "push-2")
    #expect(world.record(credential.hostID)?.pushToken == "push-2")
  }

  @Test func withoutAnAPNsTokenOrAGatewayTokenNothingIsSent() async {
    world.apnsToken = nil
    #expect(await world.coordinator().registration(for: credential, capabilities: push) == nil)
    #expect(world.gateway.requests.isEmpty)

    world.apnsToken = "aa11"
    world.gateway.answer("POST /v1/tokens", 409)
    #expect(await world.coordinator().registration(for: credential, capabilities: push) == nil)
    #expect(world.record(credential.hostID) == nil)
  }

  @Test func registersOnlyTheChosenKindsAndUnregistersWhenNoneIsLeft() async {
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    world.gateway.answer("DELETE /v1/tokens/push-1", 204)
    let coordinator = world.coordinator()
    coordinator.setKinds([.done], for: credential.hostID)
    guard case .pushRegister(let payload) = await coordinator.registration(for: credential, capabilities: push) else {
      Issue.record("Expected pushRegister")
      return
    }
    #expect(payload.kinds == ["done"])

    coordinator.setKinds([], for: credential.hostID)
    guard case .pushUnregister = await coordinator.registration(for: credential, capabilities: push) else {
      Issue.record("Expected pushUnregister")
      return
    }
    #expect(world.record(credential.hostID) == nil)
    #expect(world.keys[credential.hostID] == nil)
    #expect(await eventually { world.gateway.routes().contains("DELETE /v1/tokens/push-1") && world.stored.revoking.isEmpty })
  }

  @Test func settingsSurviveARestart() {
    let first = world.coordinator(enabled: false)
    first.setEnabled(true)
    first.setKinds([.blocked], for: credential.hostID)

    let second = MirrorPushCoordinator(defaults: world.defaults)
    #expect(second.isEnabled)
    #expect(second.kinds(for: credential.hostID) == [.blocked])
    #expect(second.kinds(for: UUID()) == Set(MirrorPushKind.allCases))
  }

  @Test func aFailedDeletionIsRetriedAfterARestartEvenForAForgottenHost() async {
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    world.gateway.answer("DELETE /v1/tokens/push-1", 500)
    world.gateway.answer("DELETE /v1/tokens/push-1", 204)
    let coordinator = world.coordinator()
    _ = await coordinator.registration(for: credential, capabilities: push)
    coordinator.received(.init(pushEnabled: true, pushAllowedByMac: true, registered: true), hostID: credential.hostID)

    await coordinator.removeRegistration(for: credential.hostID, deviceID: credential.deviceID)
    #expect(world.record(credential.hostID) == nil)
    #expect(world.stored.revoking == ["push-1"])
    #expect(world.keys[credential.hostID] == nil)
    #expect(coordinator.statuses[credential.hostID] == nil)

    // A new launch, with notifications off: the deletion is still tried, nothing else.
    let relaunched = world.coordinator(enabled: false)
    await relaunched.appBecameActive()
    #expect(world.stored.revoking.isEmpty)
    #expect(world.gateway.routes().filter { $0 == "DELETE /v1/tokens/push-1" }.count == 2)
    #expect(!world.gateway.routes().contains("PUT /v1/tokens/push-1"))
  }

  @Test(.timeLimit(.minutes(1))) func turningOffWhileWaitingForAPNsContactsNoGateway() async {
    world.holdsAPNs = true
    let coordinator = world.coordinator()
    let registering = Task { await coordinator.registration(for: credential, capabilities: push) }
    #expect(await eventually { world.isWaitingForAPNs })

    coordinator.setEnabled(false)
    world.releaseAPNs()
    #expect(await registering.value == nil)
    #expect(!world.gateway.routes().contains("POST /v1/tokens"))
    #expect(world.record(credential.hostID) == nil)
  }

  @Test(.timeLimit(.minutes(1))) func aTokenCreatedAfterTurningOffIsRevokedAndNotRegistered() async {
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    world.gateway.answer("DELETE /v1/tokens/push-1", 204)
    world.gateway.hold("POST /v1/tokens")
    let coordinator = world.coordinator()
    let registering = Task { await coordinator.registration(for: credential, capabilities: push) }
    #expect(await eventually { world.gateway.isWaiting("POST /v1/tokens") })

    coordinator.setEnabled(false)
    world.gateway.release("POST /v1/tokens")
    #expect(await registering.value == nil)
    #expect(world.record(credential.hostID) == nil)
    #expect(await eventually { world.gateway.routes().contains("DELETE /v1/tokens/push-1") && world.stored.revoking.isEmpty })
  }

  @Test(.timeLimit(.minutes(1))) func offThenOnDoesNotReuseATokenBeingDeleted() async {
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    world.gateway.answer("DELETE /v1/tokens/push-1", 204)
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-2"}"#)
    let coordinator = world.coordinator()
    _ = await coordinator.registration(for: credential, capabilities: push)
    world.gateway.hold("DELETE /v1/tokens/push-1")

    coordinator.setEnabled(false)
    coordinator.setEnabled(true)
    #expect(await eventually { world.gateway.isWaiting("DELETE /v1/tokens/push-1") })
    let registering = Task { await coordinator.registration(for: credential, capabilities: push) }
    world.gateway.release("DELETE /v1/tokens/push-1")
    guard case .pushRegister(let payload) = await registering.value else {
      Issue.record("Expected pushRegister")
      return
    }
    #expect(payload.pushToken == "push-2")
    #expect(world.record(credential.hostID)?.pushToken == "push-2")
  }

  @Test(.timeLimit(.minutes(1))) func anOlderRegistrationDoesNotSendStaleKindsButKeepsItsToken() async {
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    world.gateway.hold("POST /v1/tokens")
    let coordinator = world.coordinator()
    let registering = Task { await coordinator.registration(for: credential, capabilities: push) }
    #expect(await eventually { world.gateway.isWaiting("POST /v1/tokens") })

    coordinator.setKinds([.done], for: credential.hostID)
    world.gateway.release("POST /v1/tokens")
    #expect(await registering.value == nil)
    #expect(world.record(credential.hostID)?.pushToken == "push-1")
    #expect(world.stored.revoking.isEmpty)
  }

  @Test(.timeLimit(.minutes(1))) func aQueuedRequestDoesNotLeaveAfterTurningOff() async {
    let other = MirrorDeviceCredential(hostID: UUID(), deviceID: UUID(), key: Data(repeating: 9, count: 32))
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    world.gateway.answer("DELETE /v1/tokens/push-1", 204)
    world.gateway.hold("POST /v1/tokens")
    let coordinator = world.coordinator()
    let first = Task { await coordinator.registration(for: credential, capabilities: push) }
    #expect(await eventually { world.gateway.isWaiting("POST /v1/tokens") })
    let second = Task { await coordinator.registration(for: other, capabilities: push) }
    for _ in 0..<200 { await Task.yield() }

    coordinator.setEnabled(false)
    world.gateway.release("POST /v1/tokens")
    #expect(await first.value == nil)
    #expect(await second.value == nil)
    #expect(await eventually { world.stored.revoking.isEmpty })
    // The second Host's request was queued before off and never left: challenges went to the
    // installation, the first Host's token, and its deletion only.
    #expect(world.gateway.routes().filter { $0 == "POST /v1/tokens" }.count == 1)
    #expect(world.gateway.routes().filter { $0 == "POST /v1/challenge" }.count == 3)
    #expect(world.gateway.routes().contains("DELETE /v1/tokens/push-1"))
  }

  @Test func anotherPairingOfTheSameHostTakesOverAndForgettingTheOldOneKeepsIt() async {
    let otherAddress = MirrorDeviceCredential(hostID: credential.hostID, deviceID: UUID(), key: Data(repeating: 3, count: 32))
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-2"}"#)
    world.gateway.answer("DELETE /v1/tokens/push-1", 204)
    let coordinator = world.coordinator()
    _ = await coordinator.registration(for: credential, capabilities: push)

    guard case .pushRegister(let payload) = await coordinator.registration(for: otherAddress, capabilities: push) else {
      Issue.record("Expected pushRegister")
      return
    }
    #expect(payload.pushToken == "push-2")
    #expect(world.record(credential.hostID)?.deviceID == otherAddress.deviceID)
    #expect(world.keys[credential.hostID] == MirrorPushCrypto.key(deviceSecret: otherAddress.key, hostID: credential.hostID))
    #expect(await eventually { world.gateway.routes().contains("DELETE /v1/tokens/push-1") && world.stored.revoking.isEmpty })

    await coordinator.removeRegistration(for: credential.hostID, deviceID: credential.deviceID)
    #expect(world.record(credential.hostID)?.pushToken == "push-2")
    #expect(world.keys[credential.hostID] != nil)
  }

  @Test func anotherBuildEnvironmentGetsItsOwnToken() async {
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-2"}"#)
    world.gateway.answer("DELETE /v1/tokens/push-1", 204)
    let coordinator = world.coordinator()
    _ = await coordinator.registration(for: credential, capabilities: push)

    world.environment = .production
    guard case .pushRegister(let payload) = await coordinator.registration(for: credential, capabilities: push) else {
      Issue.record("Expected pushRegister")
      return
    }
    #expect(payload.pushToken == "push-2")
    #expect(world.record(credential.hostID)?.environment == "production")
    #expect(!world.gateway.routes().contains("PUT /v1/tokens/push-1"))
    #expect(await eventually { world.gateway.routes().contains("DELETE /v1/tokens/push-1") })
  }

  @Test func aNewAPNsTokenMovesTheTokensOfEveryHost() async throws {
    let other = MirrorDeviceCredential(hostID: UUID(), deviceID: UUID(), key: Data(repeating: 9, count: 32))
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-2"}"#)
    world.gateway.answer("PUT /v1/tokens/push-1", 204)
    world.gateway.answer("PUT /v1/tokens/push-2", 204)
    let coordinator = world.coordinator()
    _ = await coordinator.registration(for: credential, capabilities: push)
    _ = await coordinator.registration(for: other, capabilities: push)

    world.apnsToken = "bb22"
    await coordinator.appBecameActive()
    #expect(world.gateway.routes().contains("PUT /v1/tokens/push-1"))
    #expect(world.gateway.routes().contains("PUT /v1/tokens/push-2"))
    #expect(world.record(credential.hostID)?.apnsToken == "bb22")
    #expect(world.record(other.hostID)?.apnsToken == "bb22")
  }

  @Test func aTokenOfAnEarlierInstallationIsReplaced() async {
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    world.gateway.answer("PUT /v1/tokens/push-1", 403, #"{"error":"not-owner"}"#)
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-2"}"#)
    let coordinator = world.coordinator()
    _ = await coordinator.registration(for: credential, capabilities: push)
    world.now.addTimeInterval(MirrorPushCoordinator.checkInterval + 1)

    guard case .pushRegister(let payload) = await coordinator.registration(for: credential, capabilities: push) else {
      Issue.record("Expected pushRegister")
      return
    }
    #expect(payload.pushToken == "push-2")
  }

  @Test func showDetailsIsSavedWhereTheExtensionReadsIt() {
    world.showsDetails = true
    let coordinator = world.coordinator()
    #expect(coordinator.showsDetails)
    coordinator.setShowsDetails(false)
    #expect(!world.showsDetails && !coordinator.showsDetails)

    world.failsToSaveDetails = true
    coordinator.setShowsDetails(true)
    #expect(!coordinator.showsDetails)
  }

  @Test func keepsTheHostsAnswer() {
    let coordinator = world.coordinator()
    let status = MirrorMessage.PushStatusPayload(pushEnabled: true, pushAllowedByMac: false, registered: true)
    coordinator.received(status, hostID: credential.hostID)
    #expect(coordinator.statuses[credential.hostID] == status)
  }
}

@MainActor
struct MirrorPushStatusTextTests {
  private let world = PushCoordinatorWorld()
  private let hostID = UUID()

  @Test func describesEachState() {
    let push = world.coordinator()
    #expect(MirrorPushStatusText.summary(push: push, hostID: hostID, supportsPush: nil) == "Not connected yet")
    #expect(MirrorPushStatusText.summary(push: push, hostID: hostID, supportsPush: false) == "Update Prowl on the Mac")
    push.received(.init(pushEnabled: true, pushAllowedByMac: true, registered: true), hostID: hostID)
    #expect(MirrorPushStatusText.summary(push: push, hostID: hostID, supportsPush: true) == "On")
    push.received(.init(pushEnabled: false, pushAllowedByMac: true, registered: true), hostID: hostID)
    #expect(MirrorPushStatusText.summary(push: push, hostID: hostID, supportsPush: true) == "Off on the Mac")
    #expect(
      MirrorPushStatusText.detail(push: push, hostID: hostID, supportsPush: true)
        == "Turn on Send Notifications to Paired Devices in Remote Mirror settings on the Mac.")
    push.received(.init(pushEnabled: true, pushAllowedByMac: false, registered: true), hostID: hostID)
    #expect(MirrorPushStatusText.summary(push: push, hostID: hostID, supportsPush: true) == "Off on the Mac")
    push.setKinds([], for: hostID)
    #expect(MirrorPushStatusText.summary(push: push, hostID: hostID, supportsPush: true) == "Off")
  }
}

struct MirrorNotificationRouterTests {
  private let hostID = UUID()
  private let paneID = UUID()

  @Test func readsTheTargetOfAnOpenedNotificationOnly() {
    let target = MirrorNotificationRouter.target(of: ["hostID": hostID.uuidString, "paneID": paneID.uuidString])
    #expect(target?.hostID == hostID && target?.paneID == paneID)
    #expect(MirrorNotificationRouter.target(of: ["sealed": "x"]) == nil)
    #expect(MirrorNotificationRouter.target(of: ["hostID": hostID.uuidString, "paneID": "nope"]) == nil)
  }

  @Test @MainActor func onlyTheLatestTapIsCleared() {
    let router = MirrorNotificationRouter()
    let first = MirrorNotificationRouter.Target(hostID: hostID, paneID: paneID)
    let second = MirrorNotificationRouter.Target(hostID: hostID, paneID: paneID)
    #expect(first != second)
    router.pending = second
    router.finish(first)
    #expect(router.pending == second)
    let record = UUID()
    #expect(!router.owns(first, selectedHostID: record, hostRecordID: record))
    #expect(router.owns(second, selectedHostID: record, hostRecordID: record))
    #expect(!router.owns(second, selectedHostID: UUID(), hostRecordID: record))
    router.finish(second)
    #expect(router.pending == nil)
  }

  @Test func opensTheConnectedAddressOfAHostPairedTwice() {
    let lan = MirrorHostRecord(
      id: UUID(), address: "192.168.1.2", port: 7880, hostID: hostID, pairedAt: .distantPast,
      lastConnectedAt: Date(timeIntervalSince1970: 10))
    let name = MirrorHostRecord(
      id: UUID(), address: "mac", port: 7880, hostID: hostID, pairedAt: .distantPast,
      lastConnectedAt: Date(timeIntervalSince1970: 20))
    let unrelated = MirrorHostRecord(id: UUID(), address: "x", port: 1, hostID: UUID(), pairedAt: .distantPast)
    let target = MirrorNotificationRouter.Target(hostID: hostID, paneID: paneID)
    let hosts = [unrelated, lan, name]

    #expect(MirrorNotificationRouter.entry(for: target, among: hosts, selectedID: lan.id, isConnected: { _ in false }) == lan)
    #expect(
      MirrorNotificationRouter.entry(for: target, among: hosts, selectedID: unrelated.id, isConnected: { $0 == lan }) == lan)
    #expect(MirrorNotificationRouter.entry(for: target, among: hosts, selectedID: nil, isConnected: { _ in false }) == name)
    #expect(MirrorNotificationRouter.entry(for: .init(hostID: UUID(), paneID: paneID), among: hosts, selectedID: nil, isConnected: { _ in true }) == nil)
  }

  @Test func routesToThePaneWhileTheHostListsIt() {
    let host = MirrorHostRecord(
      id: UUID(), address: "mac", port: 7880, hostID: hostID, pairedAt: Date(timeIntervalSince1970: 0))
    let pane = MirrorPaneDescriptor(id: paneID, title: "Claude Code · main", directory: "/repo", busy: false)
    let target = MirrorNotificationRouter.Target(hostID: hostID, paneID: paneID)

    #expect(MirrorNotificationRouter.route(for: target, host: host, panes: [pane])?.pane.id == paneID)
    #expect(MirrorNotificationRouter.route(for: target, host: host, panes: []) == nil)
    var other = host
    other.hostID = UUID()
    #expect(MirrorNotificationRouter.route(for: target, host: other, panes: [pane]) == nil)
  }
}
