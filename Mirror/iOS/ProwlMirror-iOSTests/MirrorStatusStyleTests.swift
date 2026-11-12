import SwiftUI
import Testing

@testable import ProwlMirror_iOS

@MainActor
struct MirrorStatusStyleTests {
  @Test func disconnectedStatesAreRedWhileProgressIsNeutral() {
    for status: MirrorSession.Status in [
      .disconnected, .hostStopped, .paneClosed, .takenOver, .incompatible,
    ] {
      #expect(status.displayColor == .red)
    }
    for status: MirrorSession.Status in [.connecting, .choosingPane, .subscribing] {
      #expect(status.displayColor == .secondary)
    }
    #expect(MirrorSession.Status.live.displayColor == .green)
  }

  /// With the key bar the person answers on the phone, so the strip does not send them to the Mac.
  @Test func theBlockedStripNamesTheMacOnlyWithoutKeys() {
    #expect(
      MirrorBlockedStrip.text(kind: "permission", answersWithKeys: true)
        == "Blocked · Waiting for a permission decision")
    #expect(
      MirrorBlockedStrip.text(kind: "permission", answersWithKeys: false)
        == "Blocked · Waiting for a permission decision on the Mac")
    #expect(MirrorBlockedStrip.text(kind: nil, answersWithKeys: true) == "Blocked · Waiting for you")
    #expect(MirrorBlockedStrip.text(kind: "other", answersWithKeys: false) == "Blocked · Waiting for you on the Mac")
  }
}
