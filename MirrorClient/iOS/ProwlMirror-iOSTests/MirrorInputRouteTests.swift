import Foundation
import Testing
@testable import ProwlMirror_iOS

struct MirrorInputRouteTests {
  @Test func usesAgentDispatchOrIdleShellAndPreservesText() throws {
    let pane = UUID()
    #expect(try MirrorInputRoute.command(listing: listing(pane, agent: .string("claude"), status: .string("running")),
      paneID: pane, text: "first\nsecond") == .agentsDispatch(.init(pane: pane.uuidString, prompt: "first\nsecond")))
    #expect(try MirrorInputRoute.command(listing: listing(pane, agent: .null, status: .string("idle")),
      paneID: pane, text: "echo hello") == .send(.init(pane: pane, text: "echo hello")))
  }

  @Test func missingRunningOrUnknownShellCannotSend() {
    let pane = UUID()
    for state in [MirrorJSON.null, .string("running")] {
      #expect(throws: (any Error).self) {
        try MirrorInputRoute.command(listing: listing(pane, agent: .null, status: state), paneID: pane, text: "hello")
      }
    }
    #expect(throws: (any Error).self) {
      try MirrorInputRoute.command(listing: listing(pane, agent: .null, status: .string("idle")), paneID: UUID(), text: "hi")
    }
  }

  private func listing(_ pane: UUID, agent: MirrorJSON, status: MirrorJSON) -> MirrorJSON {
    .object(["ok": .bool(true), "data": .object(["items": .array([
      .object(["pane": .object(["id": .string(pane.uuidString), "agent": agent]), "task": .object(["status": status])])
    ])])])
  }
}
