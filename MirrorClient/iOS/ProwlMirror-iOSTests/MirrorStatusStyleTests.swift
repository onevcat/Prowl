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
}
