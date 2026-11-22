import CryptoKit
import Foundation
import Testing

@testable import ProwlMirror_iOS

/// In-memory token records and push keys, with the time under test control.
final class PushCoordinatorWorld: @unchecked Sendable {
  private let lock = NSLock()
  private var records: [UUID: MirrorPushTokenRecord] = [:]
  private(set) var keys: [UUID: SymmetricKey] = [:]
  var apnsToken: String? = "aa11"
  var now = Date(timeIntervalSince1970: 1_000_000)
  let gateway = FakeGateway()
  let attest = FakeAttest()
  let defaults = UserDefaults(suiteName: "push-coordinator-\(UUID().uuidString)")!

  func record(_ hostID: UUID) -> MirrorPushTokenRecord? { lock.withLock { records[hostID] } }

  @MainActor func coordinator(enabled: Bool = true) -> MirrorPushCoordinator {
    defaults.set(enabled, forKey: MirrorPushCoordinator.enabledKey)
    return MirrorPushCoordinator(
      defaults: defaults,
      gateway: MirrorPushGatewayClient(
        baseURL: URL(string: "https://gateway.test")!, attest: attest, storage: MemoryStorage().storage,
        send: gateway.send),
      tokens: MirrorPushTokenStorage(
        load: { id in self.lock.withLock { self.records[id] } },
        save: { record, id in self.lock.withLock { self.records[id] = record } }),
      registerAPNs: { self.apnsToken },
      environment: { .development },
      saveKey: { key, id in self.lock.withLock { self.keys[id] = key } },
      removeKey: { id in _ = self.lock.withLock { self.keys.removeValue(forKey: id) } },
      now: { self.now })
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
    #expect(world.record(credential.hostID) == .init(pushToken: "push-1", apnsToken: "aa11", checkedAt: world.now))
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
    #expect(world.gateway.routes().last == "DELETE /v1/tokens/push-1")
    #expect(world.record(credential.hostID) == nil)
    #expect(world.keys[credential.hostID] == nil)
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

  @Test func removingARegistrationDeletesTheTokenAndTheKey() async {
    world.gateway.answer("POST /v1/tokens", 201, #"{"pushToken":"push-1"}"#)
    world.gateway.answer("DELETE /v1/tokens/push-1", 500)
    world.gateway.answer("DELETE /v1/tokens/push-1", 204)
    let coordinator = world.coordinator()
    _ = await coordinator.registration(for: credential, capabilities: push)
    coordinator.received(.init(pushEnabled: true, pushAllowedByMac: true, registered: true), hostID: credential.hostID)

    // An unreachable gateway keeps the record, so the next call tries again.
    await coordinator.removeRegistration(for: credential.hostID)
    #expect(world.record(credential.hostID) != nil)
    #expect(world.keys[credential.hostID] == nil)
    #expect(coordinator.statuses[credential.hostID] == nil)

    await coordinator.removeRegistration(for: credential.hostID)
    #expect(world.record(credential.hostID) == nil)
    #expect(world.gateway.routes().filter { $0 == "DELETE /v1/tokens/push-1" }.count == 2)
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
