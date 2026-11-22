import Foundation
import Testing

@testable import ProwlMirror_iOS

struct MirrorPushTokenLedgerTests {
  private let hostID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
  private let deviceID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
  private let checked = Date(timeIntervalSince1970: 1_000_000)

  private func record(_ pushToken: String, apns: String = "aa11", environment: String = "development")
    -> MirrorPushTokenRecord
  {
    .init(pushToken: pushToken, apnsToken: apns, environment: environment, deviceID: deviceID, checkedAt: checked)
  }

  @Test func readsKeychainDataOfEarlierBuilds() throws {
    // The shape that P3d saved in the Keychain account `push-tokens`.
    let stored = """
      {"records":["11111111-2222-3333-4444-555555555555",{"pushToken":"push-1","apnsToken":"aa11",\
      "environment":"development","deviceID":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","checkedAt":-977307200}],\
      "revoking":["push-0"]}
      """
    let ledger = try JSONDecoder().decode(MirrorPushTokenLedger.self, from: Data(stored.utf8))
    #expect(ledger == MirrorPushTokenLedger(records: [hostID: record("push-1")], revoking: ["push-0"]))
    let again = try JSONDecoder().decode(MirrorPushTokenLedger.self, from: JSONEncoder().encode(ledger))
    #expect(again == ledger)
  }

  @Test func aTokenIsOnlyUsedByItsPairingAndBuild() {
    let ledger = MirrorPushTokenLedger(records: [hostID: record("push-1")])
    #expect(ledger.record(for: hostID, deviceID: deviceID, environment: "development")?.pushToken == "push-1")
    #expect(ledger.record(for: hostID, deviceID: UUID(), environment: "development") == nil)
    #expect(ledger.record(for: hostID, deviceID: deviceID, environment: "production") == nil)
    #expect(ledger.record(for: UUID(), deviceID: deviceID, environment: "development") == nil)
  }

  @Test func aTokenIsFreshForADayAndOneAPNsToken() {
    let token = record("push-1")
    #expect(token.isFresh(apnsToken: "aa11", at: checked.addingTimeInterval(MirrorPushTokenRecord.checkInterval - 1)))
    #expect(!token.isFresh(apnsToken: "aa11", at: checked.addingTimeInterval(MirrorPushTokenRecord.checkInterval)))
    #expect(!token.isFresh(apnsToken: "bb22", at: checked))
  }

  @Test func listsTokensOfAnotherAPNsTokenOrBuild() {
    let other = UUID()
    let third = UUID()
    let ledger = MirrorPushTokenLedger(records: [
      hostID: record("push-1"), other: record("push-2", apns: "bb22"), third: record("push-3", environment: "production"),
    ])
    let outdated = ledger.outdated(apnsToken: "aa11", environment: "development")
    #expect(Set(outdated.map(\.hostID)) == [other, third])
  }

  @Test func revokingQueuesTheTokenOnce() {
    var ledger = MirrorPushTokenLedger(records: [hostID: record("push-1")])
    let first = ledger.revoke(hostID)
    let second = ledger.revoke(hostID)
    #expect(first && !second)
    #expect(ledger.records.isEmpty && ledger.revoking == ["push-1"])
    ledger.deleted("push-1")
    #expect(ledger.revoking.isEmpty)
  }

  @Test func aReplacedTokenIsLeftAlone() {
    var ledger = MirrorPushTokenLedger(records: [hostID: record("push-2")])
    let retired = ledger.retire(hostID, "push-1")
    #expect(!retired)
    ledger.drop(hostID, "push-1")
    ledger.confirm(hostID, "push-1", apnsToken: "bb22", at: checked.addingTimeInterval(60))
    #expect(ledger == MirrorPushTokenLedger(records: [hostID: record("push-2")]))
  }

  @Test func retireDropAndConfirmChangeTheOwner() {
    var ledger = MirrorPushTokenLedger(records: [hostID: record("push-1")])
    let later = checked.addingTimeInterval(60)
    ledger.confirm(hostID, "push-1", apnsToken: "bb22", at: later)
    #expect(ledger.records[hostID] == record("push-1").moved(to: "bb22", at: later))

    ledger.drop(hostID, "push-1")
    #expect(ledger.records.isEmpty && ledger.revoking.isEmpty)

    ledger = MirrorPushTokenLedger(records: [hostID: record("push-1")])
    let retired = ledger.retire(hostID, "push-1")
    #expect(retired && ledger.records.isEmpty && ledger.revoking == ["push-1"])
  }

  @Test func aCommittedTokenQueuesTheOneItReplaces() {
    var ledger = MirrorPushTokenLedger()
    let first = ledger.commit(record("push-1"), for: hostID)
    let same = ledger.commit(record("push-1"), for: hostID)
    #expect(!first && !same && ledger.revoking.isEmpty)
    let replaced = ledger.commit(record("push-2"), for: hostID)
    #expect(replaced && ledger.records[hostID]?.pushToken == "push-2" && ledger.revoking == ["push-1"])

    ledger.abandon("push-3")
    #expect(ledger.revoking == ["push-1", "push-3"])
  }
}
