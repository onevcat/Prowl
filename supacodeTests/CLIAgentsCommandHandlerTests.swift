import Foundation
import IdentifiedCollections
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct CLIAgentsCommandHandlerTests {

  @Test func buildsAgentsPayloadFromActiveEntriesAndTerminalSnapshot() async throws {
    let fixture = makePayloadFixture()
    let handler = AgentsCommandHandler {
      fixture.snapshot
    }

    let response = await handler.handle(
      envelope: CommandEnvelope(output: .json, command: .agents(AgentsInput()))
    )

    #expect(response.ok)
    #expect(response.command == "agents")
    #expect(response.schemaVersion == "prowl.cli.agents.v1")

    let payload = try #require(try response.data?.decode(as: AgentsCommandPayload.self))
    #expect(payload.count == 2)
    #expect(payload.agents.map(\.id) == [fixture.tabPaneID.uuidString, fixture.otherPaneID.uuidString])

    let agent = payload.agents[0]
    #expect(agent.type == "omp")
    #expect(agent.name == "omp")
    #expect(agent.status == .blocked)
    // The reducer entry may intentionally lag raw-state-only terminal polls so
    // the sidebar does not re-render. CLI snapshots must use the live terminal
    // raw state instead of that UI-deduplicated value.
    #expect(agent.rawState == "working")
    #expect(agent.detectionReason == "omp.askPrompt")
    #expect(agent.lastChangedAt == "2026-09-21T14:00:00Z")
    #expect(agent.project.name == "Prowl")
    #expect(agent.project.branch == "feature/agents")
    #expect(agent.project.path == "/tmp/project-repo")
    #expect(agent.worktree.id == fixture.tabWorktree.id)
    #expect(agent.worktree.name == "main")
    #expect(agent.worktree.path == "/tmp/tab-repo")
    #expect(agent.tab.id == fixture.tabID.uuidString)
    #expect(agent.tab.title == "issue 330")
    #expect(agent.tab.selected)
    #expect(agent.pane.id == fixture.tabPaneID.uuidString)
    #expect(agent.pane.handle == nil)
    #expect(agent.pane.index == 2)
    #expect(agent.pane.title == "omp")
    #expect(agent.pane.cwd == "/tmp/project-repo/Sources")
    #expect(agent.pane.focused)
    #expect(agent.session?.id == "019f4f1b-3650-7661-a56d-351f02f01139")
    #expect(agent.session?.path == "/tmp/omp-session.jsonl")
    #expect(agent.session?.confidence == "high")
    #expect(agent.session?.source == "transcript_match")
    #expect(agent.signals?.channels == [])

    let idleAgent = payload.agents[1]
    #expect(idleAgent.status == .idle)
    #expect(idleAgent.detectionReason == nil)
    #expect(idleAgent.project.name == "Tab Repo")
    #expect(idleAgent.project.branch == "main")
    #expect(idleAgent.pane.focused == false)
    let rawPayload = try #require(response.data?.bytes)
    let rawPayloadString = try #require(String(bytes: rawPayload, encoding: .utf8))
    #expect(!rawPayloadString.contains("\"handle\""))
    #expect(rawPayloadString.contains("\"detection_reason\":\"omp.askPrompt\""))
  }

  @Test func includesPaneHandlesOnlyInTextPayload() async throws {
    let fixture = makePayloadFixture()
    let handler = AgentsCommandHandler {
      fixture.snapshot
    }

    let response = await handler.handle(
      envelope: CommandEnvelope(output: .text, command: .agents(AgentsInput()))
    )
    let payload = try #require(try response.data?.decode(as: AgentsCommandPayload.self))

    #expect(payload.agents[0].id == fixture.tabPaneID.uuidString)
    #expect(payload.agents[0].pane.id == fixture.tabPaneID.uuidString)
    #expect(payload.agents[0].pane.handle == 12)
    #expect(payload.agents[1].pane.handle == 11)
  }

  @Test func returnsAgentsFailedWhenSnapshotProviderThrows() async {
    struct DummyError: Error {}

    let handler = AgentsCommandHandler {
      throw DummyError()
    }

    let response = await handler.handle(
      envelope: CommandEnvelope(output: .json, command: .agents(AgentsInput()))
    )

    #expect(response.ok == false)
    #expect(response.command == "agents")
    #expect(response.schemaVersion == "prowl.cli.agents.v1")
    #expect(response.error?.code == CLIErrorCode.agentsFailed)
  }

  private func makeWorktree(repoRoot: String, path: String, branch: String) -> Worktree {
    Worktree(
      id: path,
      name: branch,
      detail: branch,
      workingDirectory: URL(fileURLWithPath: path),
      repositoryRootURL: URL(fileURLWithPath: repoRoot)
    )
  }

  private func makeRepository(
    id: String,
    name: String,
    kind: Repository.Kind = .git,
    worktrees: IdentifiedArrayOf<Worktree>
  ) -> Repository {
    Repository(
      id: id,
      rootURL: URL(fileURLWithPath: id),
      name: name,
      kind: kind,
      worktrees: worktrees
    )
  }

  private func makePayloadFixture() -> PayloadFixture {
    let tabPaneID = UUID(uuidString: "6E1A2A10-D99F-4E3F-920C-D93AA3C05764")!
    let otherPaneID = UUID(uuidString: "EF65FF31-1B72-40B2-80DA-3AA87B7B6858")!
    let tabID = UUID(uuidString: "2FC00CF0-3974-4E1B-BEF8-7A08A8E3B7C0")!
    let tabWorktree = makeWorktree(repoRoot: "/tmp/tab-repo", path: "/tmp/tab-repo", branch: "main")
    let projectWorktree = makeWorktree(
      repoRoot: "/tmp/project-repo", path: "/tmp/project-repo", branch: "feature/agents")
    let tabRepo = makeRepository(id: "/tmp/tab-repo", name: "Tab Repo", worktrees: [tabWorktree])
    let projectRepo = makeRepository(id: "/tmp/project-repo", name: "Project Repo", worktrees: [projectWorktree])
    var repositoriesState = RepositoriesFeature.State()
    repositoriesState.repositories = [tabRepo, projectRepo]
    repositoriesState.repositoryCustomTitles = [projectRepo.id: "Prowl"]
    repositoriesState.activeAgents.entries = [
      makeAgentEntry(
        AgentEntryInput(
          paneID: tabPaneID,
          tabID: tabID,
          worktree: tabWorktree,
          workingDirectory: URL(fileURLWithPath: "/tmp/project-repo/Sources"),
          paneIndex: 2,
          iconLookupToken: "omp",
          agent: .omp,
          session: AgentSession(
            id: "019f4f1b-3650-7661-a56d-351f02f01139",
            transcriptPath: URL(fileURLWithPath: "/tmp/omp-session.jsonl"),
            source: .transcriptMatch,
            confidence: .high
          ),
          rawState: .blocked,
          displayState: .blocked,
          lastChangedAt: Date(timeIntervalSince1970: 1_789_999_200)
        )),
      makeAgentEntry(
        AgentEntryInput(
          paneID: otherPaneID,
          tabID: tabID,
          worktree: tabWorktree,
          workingDirectory: nil,
          paneIndex: 1,
          iconLookupToken: DetectedAgent.codex.iconLookupToken,
          agent: .codex,
          rawState: .idle,
          displayState: .idle,
          lastChangedAt: Date(timeIntervalSince1970: 1_789_999_260)
        )),
    ]

    return PayloadFixture(
      tabPaneID: tabPaneID,
      otherPaneID: otherPaneID,
      tabID: tabID,
      tabWorktree: tabWorktree,
      snapshot: AgentsRuntimeSnapshot(
        repositoriesState: repositoriesState,
        listSnapshot: makeListSnapshot(
          tabPaneID: tabPaneID,
          otherPaneID: otherPaneID,
          tabID: tabID,
          tabWorktree: tabWorktree
        ),
        screenDetectionsBySurfaceID: [
          tabPaneID: AgentScreenDetection(
            state: .working,
            reason: .matched(AgentScreenRuleID("omp.askPrompt"))
          )
        ]
      )
    )
  }

  private func makeAgentEntry(_ input: AgentEntryInput) -> ActiveAgentEntry {
    ActiveAgentEntry(
      id: input.paneID,
      worktreeID: input.worktree.id,
      worktreeName: input.worktree.name,
      workingDirectory: input.workingDirectory,
      tabID: TerminalTabID(rawValue: input.tabID),
      paneTitle: "issue 330",
      surfaceID: input.paneID,
      paneIndex: input.paneIndex,
      iconLookupToken: input.iconLookupToken,
      agent: input.agent,
      session: input.session,
      rawState: input.rawState,
      displayState: input.displayState,
      lastChangedAt: input.lastChangedAt
    )
  }

  private func makeListSnapshot(
    tabPaneID: UUID,
    otherPaneID: UUID,
    tabID: UUID,
    tabWorktree: Worktree
  ) -> ListRuntimeSnapshot {
    ListRuntimeSnapshot(
      worktrees: [
        .init(
          id: tabWorktree.id,
          name: tabWorktree.name,
          path: tabWorktree.workingDirectory.path(percentEncoded: false),
          rootPath: tabWorktree.repositoryRootURL.path(percentEncoded: false),
          kind: .git,
          taskStatus: .running,
          tabs: [
            .init(
              id: tabID,
              handle: 10,
              title: "issue 330",
              selected: true,
              focusedPaneID: tabPaneID,
              panes: [
                .init(id: otherPaneID, handle: 11, title: "zsh", cwd: "/tmp/tab-repo"),
                .init(id: tabPaneID, handle: 12, title: "omp", cwd: "/tmp/project-repo/Sources"),
              ]
            )
          ]
        )
      ],
      focusedWorktreeID: tabWorktree.id
    )
  }

  private struct PayloadFixture {
    let tabPaneID: UUID
    let otherPaneID: UUID
    let tabID: UUID
    let tabWorktree: Worktree
    let snapshot: AgentsRuntimeSnapshot
  }

  private struct AgentEntryInput {
    let paneID: UUID
    let tabID: UUID
    let worktree: Worktree
    let workingDirectory: URL?
    let paneIndex: Int
    let iconLookupToken: String
    let agent: DetectedAgent
    var session: AgentSession?
    let rawState: AgentRawState
    let displayState: AgentDisplayState
    let lastChangedAt: Date
  }
}
