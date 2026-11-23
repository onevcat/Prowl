import Foundation
import Testing

@testable import ProwlMirror_iOS

@MainActor
struct MirrorSettingsMenuTests {
  private func hosts(_ count: Int) -> [MirrorHostRecord] {
    (0..<count).map {
      MirrorHostRecord(id: UUID(), address: "10.0.0.\($0)", port: 7880, hostID: nil, pairedAt: Date())
    }
  }

  @Test func listsEveryHostUpToTheLimit() {
    let all = hosts(MirrorSettingsMenu.listedHostLimit)
    #expect(MirrorSettingsMenu.listed(all, current: all[2]) == all)
  }

  @Test func keepsTheCurrentHostWhenTheListIsCut() {
    let all = hosts(8)
    let listed = MirrorSettingsMenu.listed(all, current: all[7])
    #expect(listed.count == MirrorSettingsMenu.listedHostLimit)
    #expect(listed.last == all[7])
    #expect(Array(listed.dropLast()) == Array(all.prefix(MirrorSettingsMenu.listedHostLimit - 1)))
  }

  @Test func cutListAlreadyHoldingTheCurrentHostStaysInOrder() {
    let all = hosts(8)
    #expect(MirrorSettingsMenu.listed(all, current: all[1]) == Array(all.prefix(MirrorSettingsMenu.listedHostLimit)))
  }
}
