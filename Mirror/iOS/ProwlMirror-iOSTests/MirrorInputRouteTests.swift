import Foundation
import Testing
@testable import ProwlMirror_iOS

struct MirrorInputRouteTests {
  @Test func usesAgentDispatchOrShellAndPreservesText() throws {
    let pane = UUID()
    #expect(try MirrorInputRoute.command(listing: listing(pane, agent: .string("claude"), status: .string("running")),
      paneID: pane, text: "first\nsecond") == .agentsInput(.init(pane: pane.uuidString, prompt: "first\nsecond")))
    #expect(try MirrorInputRoute.command(listing: listing(pane, agent: .null, status: .string("idle")),
      paneID: pane, text: "echo hello") == .send(.init(pane: pane, text: "echo hello")))
  }

  /// `task.status` is the worktree's, so another tab's command must not block a shell pane; the
  /// Host checks the pane's own prompt (089 follow-up).
  @Test func shellRoutesToSendWhateverTheWorktreeRuns() throws {
    let pane = UUID()
    for state in [MirrorJSON.null, .string("running"), .string("idle")] {
      #expect(
        try MirrorInputRoute.command(listing: listing(pane, agent: .null, status: state), paneID: pane, text: "ls")
          == .send(.init(pane: pane, text: "ls")))
    }
  }

  @Test func missingPaneCannotSend() {
    #expect(throws: (any Error).self) {
      try MirrorInputRoute.command(listing: listing(UUID(), agent: .null, status: .string("idle")), paneID: UUID(), text: "hi")
    }
  }

  private func listing(_ pane: UUID, agent: MirrorJSON, status: MirrorJSON) -> MirrorJSON {
    .object(["ok": .bool(true), "data": .object(["items": .array([
      .object(["pane": .object(["id": .string(pane.uuidString), "agent": agent]), "task": .object(["status": status])])
    ])])])
  }
}
