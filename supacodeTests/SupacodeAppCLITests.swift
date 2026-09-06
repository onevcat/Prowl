import ComposableArchitecture
import Foundation
import GhosttyKit
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct SupacodeAppCLITests {
  @Test func cliRouterWiresAgentsKeyAndReadHandlersInsteadOfStubHandlers() async {
    let store = Store(initialState: AppFeature.State()) {
      AppFeature()
    }
    let terminalManager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let router = SupacodeApp.makeCLICommandRouter(appStore: store, terminalManager: terminalManager)

    let agentsResponse = await router.route(
      CommandEnvelope(output: .json, command: .agents(AgentsInput()))
    )
    let agentReadResponse = await router.route(
      CommandEnvelope(output: .json, command: .agentsRead(AgentReadInput(pane: "p7")))
    )
    let keyResponse = await router.route(
      CommandEnvelope(output: .json, command: .key(KeyInput(rawToken: "enter", token: "enter")))
    )
    let readResponse = await router.route(
      CommandEnvelope(output: .json, command: .read(ReadInput()))
    )

    #expect(agentsResponse.command == "agents")
    #expect(agentReadResponse.command == "agents.read")
    #expect(keyResponse.command == "key")
    #expect(readResponse.command == "read")
    #expect(agentsResponse.error?.code != "NOT_IMPLEMENTED")
    #expect(agentReadResponse.error?.code != "NOT_IMPLEMENTED")
    #expect(keyResponse.error?.code != "NOT_IMPLEMENTED")
    #expect(readResponse.error?.code != "NOT_IMPLEMENTED")
  }

  @Test func cliRouterWiresCallerAttributedAgentSignalIntoTerminalObserver() async throws {
    let store = Store(initialState: AppFeature.State()) {
      AppFeature()
    }
    let terminalManager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = Worktree(
      id: "/tmp/app-cli-signal",
      name: "app-cli-signal",
      detail: "",
      workingDirectory: URL(fileURLWithPath: "/tmp/app-cli-signal"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/app-cli-signal")
    )
    let state = terminalManager.state(for: worktree)
    let tabID = try #require(state.createTab())
    let surfaceID = try #require(state.focusedSurfaceId(in: tabID))
    var observer = terminalManager.observeAgentState(surfaceID: surfaceID).makeAsyncIterator()
    _ = try await observer.next()
    let router = SupacodeApp.makeCLICommandRouter(
      appStore: store,
      terminalManager: terminalManager,
      agentSignalCallerResolver: { processID in
        #expect(processID == 42)
        return CallerPane(worktreeID: worktree.id, surfaceID: surfaceID)
      }
    )

    let response = await router.route(
      CommandEnvelope(
        output: .json,
        command: .agentsSignal(AgentSignalInput(event: .needsInput, detail: "Approval required"))
      ),
      context: CLICommandContext(callerProcessID: 42)
    )

    #expect(response.ok)
    guard case .signal(let signal) = try await observer.next() else {
      Issue.record("Expected signal on terminal observer")
      return
    }
    #expect(signal.kind == .needsInput)
    #expect(signal.detail == "Approval required")
    #expect(signal.source == .cooperativeCLI)
  }

  @Test func resolveCLITerminalWorktreeBuildsSyntheticRunnableFolderWorktree() {
    let repository = Repository(
      id: "/Users/test/PlainFolder",
      rootURL: URL(fileURLWithPath: "/Users/test/PlainFolder", isDirectory: true),
      name: "PlainFolder",
      kind: .plain,
      worktrees: []
    )

    let resolved = SupacodeApp.resolveCLITerminalWorktree(
      id: repository.id,
      repositories: [repository]
    )

    #expect(resolved?.id == repository.id)
    #expect(resolved?.name == "PlainFolder")
    #expect(
      resolved?.workingDirectory.standardizedFileURL.path(percentEncoded: false)
        == URL(fileURLWithPath: "/Users/test/PlainFolder", isDirectory: true)
        .standardizedFileURL.path(percentEncoded: false)
    )
  }

  @Test func handoffSaveUsesNonMainWorktreePath() async throws {
    let base = FileManager.default.temporaryDirectory
      .appending(path: "app-cli-handoff-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let repositoryRoot = base.appending(path: "Prowl", directoryHint: .isDirectory)
    let worktreeRoot = base.appending(path: "Prowl-feature", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: repositoryRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let worktree = Worktree(
      id: worktreeRoot.path(percentEncoded: false),
      name: "feature",
      detail: "feature",
      workingDirectory: worktreeRoot,
      repositoryRootURL: repositoryRoot
    )
    let repository = Repository(
      id: repositoryRoot.path(percentEncoded: false),
      rootURL: repositoryRoot,
      name: "Prowl",
      worktrees: [worktree]
    )
    var repositories = RepositoriesFeature.State()
    repositories.repositories = [repository]
    repositories.selection = .worktree(worktree.id)
    let store = Store(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    }
    let terminalManager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let terminalState = terminalManager.state(for: worktree)
    _ = try #require(terminalState.createTab())
    let router = SupacodeApp.makeCLICommandRouter(appStore: store, terminalManager: terminalManager)

    let response = await router.route(
      CommandEnvelope(
        output: .json,
        command: .handoff(
          HandoffInput(action: .save, selector: .worktree(worktree.id), contextOnly: true)
        )
      )
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: HandoffCommandPayload.self))
    #expect(
      payload.artifactPath
        == worktreeRoot.standardizedFileURL.appending(path: ".prowl/handoff/current.md")
        .path(percentEncoded: false)
    )
    #expect(payload.briefing == "none")
  }
}
