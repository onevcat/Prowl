import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct AgentReadCommandHandlerTests {
  @Test func blockedSnapshotWithoutSessionPreservesBlockerAndReportsPending() async throws {
    let handler = AgentReadCommandHandler(
      snapshotProvider: { _ in
        .success(self.makeSnapshot(status: .blocked, blockerText: "Do you want to proceed?\n❯ 1. Yes\n  2. No"))
      },
      resultProvider: { _, _, _ in
        Issue.record("Unexpected transcript read")
        return .failure(.incomplete)
      }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(output: .json, command: .agentsRead(AgentReadInput(pane: "p7")))
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: AgentReadCommandPayload.self))
    #expect(payload.agent.status == .blocked)
    #expect(payload.blocker?.text.contains("1. Yes") == true)
    #expect(payload.result.state == .pending)
    #expect(payload.result.error == nil)
  }

  @Test func idleSnapshotWithoutSessionReportsUnavailable() async throws {
    let handler = AgentReadCommandHandler(
      snapshotProvider: { _ in .success(self.makeSnapshot(status: .idle)) },
      resultProvider: { _, _, _ in
        Issue.record("Unexpected transcript read")
        return .failure(.incomplete)
      }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(output: .json, command: .agentsRead(AgentReadInput(pane: "p7")))
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: AgentReadCommandPayload.self))
    #expect(payload.result.state == .unavailable)
    #expect(payload.result.error?.code == CLIErrorCode.sessionUnresolved)
  }

  @Test func resultOnlyFailsWithResultNotFoundForLiveAgentWithoutSession() async {
    let handler = AgentReadCommandHandler(
      snapshotProvider: { _ in .success(self.makeSnapshot(status: .working)) },
      resultProvider: { _, _, _ in
        Issue.record("Unexpected transcript read")
        return .failure(.incomplete)
      }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .text,
        command: .agentsRead(AgentReadInput(pane: "p7", resultOnly: true))
      )
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.resultNotFound)
  }

  @Test func workingSnapshotMapsMissingTrustedHistoryToPending() async throws {
    let handler = AgentReadCommandHandler(
      snapshotProvider: { _ in .success(self.makeSnapshot(status: .working, session: self.makeSession())) },
      resultProvider: { _, _, _ in .failure(.missing) }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(output: .json, command: .agentsRead(AgentReadInput(pane: "p7")))
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: AgentReadCommandPayload.self))
    #expect(payload.result.state == .pending)
    #expect(payload.result.text == nil)
    #expect(payload.result.error == nil)
  }

  @Test func resultOnlyTurnsUnavailableSnapshotResultIntoCommandFailure() async {
    let handler = AgentReadCommandHandler(
      snapshotProvider: { _ in .success(self.makeSnapshot(status: .idle)) },
      resultProvider: { _, _, _ in
        Issue.record("Unexpected transcript read")
        return .failure(.incomplete)
      }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .text,
        command: .agentsRead(AgentReadInput(pane: "p7", resultOnly: true))
      )
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.sessionUnresolved)
  }

  @Test func resultOnlySucceedsForCompleteTrustedResult() async throws {
    let handler = AgentReadCommandHandler(
      snapshotProvider: { _ in .success(self.makeSnapshot(status: .done, session: self.makeSession())) },
      resultProvider: { _, _, _ in .complete("Final result") }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .text,
        command: .agentsRead(AgentReadInput(pane: "p7", resultOnly: true))
      )
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: AgentReadCommandPayload.self))
    #expect(payload.outputMode == .resultOnly)
    #expect(payload.result.state == .complete)
    #expect(payload.result.text == "Final result")
  }

  @Test func liveWorkingOrBlockedAgentReportsPendingEvenWithAnEarlierCompleteTurn() async throws {
    for status in [AgentsCommandStatus.working, .blocked] {
      let handler = AgentReadCommandHandler(
        snapshotProvider: { _ in .success(self.makeSnapshot(status: status, session: self.makeSession())) },
        resultProvider: { _, _, _ in
          Issue.record("A live working/blocked agent must not read the transcript")
          return .complete("Answer from the previous turn")
        }
      )

      let response = await handler.handle(
        envelope: CommandEnvelope(output: .json, command: .agentsRead(AgentReadInput(pane: "p7")))
      )

      #expect(response.ok)
      let payload = try #require(try response.data?.decode(as: AgentReadCommandPayload.self))
      #expect(payload.agent.status == status)
      #expect(payload.result.state == .pending)
      #expect(payload.result.text == nil)
      #expect(payload.result.error == nil)
    }
  }

  @Test func resultOnlyFailsWhileTheAgentIsStillWorking() async {
    let handler = AgentReadCommandHandler(
      snapshotProvider: { _ in .success(self.makeSnapshot(status: .working, session: self.makeSession())) },
      resultProvider: { _, _, _ in .complete("Answer from the previous turn") }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .text,
        command: .agentsRead(AgentReadInput(pane: "p7", resultOnly: true))
      )
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.resultNotFound)
  }

  private func makeSnapshot(
    status: AgentsCommandStatus,
    blockerText: String? = nil,
    session: AgentSession? = nil
  ) -> AgentReadRuntimeSnapshot {
    AgentReadRuntimeSnapshot(
      target: ReadTarget(
        worktree: ReadTargetWorktree(
          id: "/tmp/project", name: "main", path: "/tmp/project", rootPath: "/tmp/project", kind: "git"
        ),
        tab: ReadTargetTab(id: "2FC00CF0-3974-4E1B-BEF8-7A08A8E3B7C0", title: "Agent", selected: true),
        pane: ReadTargetPane(
          id: "6E1A2A10-D99F-4E3F-920C-D93AA3C05764", title: "Claude", cwd: "/tmp/project", focused: false
        )
      ),
      agent: .claude,
      status: status,
      rawState: status == .done ? "idle" : status.rawValue,
      detectionReason: "claude.blockedPrompt",
      lastChangedAt: "2026-08-11T12:00:00Z",
      blockerText: blockerText,
      transcriptSession: session
    )
  }

  private func makeSession() -> AgentSession {
    AgentSession(
      id: "019f4f1b-3650-7661-a56d-351f02f01139",
      transcriptPath: URL(fileURLWithPath: "/tmp/session.jsonl"),
      source: .openFile,
      confidence: .exact
    )
  }
}
