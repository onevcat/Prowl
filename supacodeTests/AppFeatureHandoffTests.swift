import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct AppFeatureHandoffTests {
  private func makeTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "handoff-app-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.standardizedFileURL
  }

  private func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  private func uuid(_ value: UInt8) -> UUID {
    UUID(uuid: (value, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
  }

  private func makeWorkspaceState(root: URL) -> RepositoriesFeature.State {
    let root = root.standardizedFileURL
    let workspace = ProjectWorkspace(id: root.path(percentEncoded: false), title: "Checkout Flow")
    let repo = Repository(
      id: root.path(percentEncoded: false),
      rootURL: root,
      name: "Checkout Flow",
      worktrees: IdentifiedArray(uniqueElements: []),
      workspace: workspace
    )
    var state = RepositoriesFeature.State()
    state.repositories = [repo]
    state.repositoryRoots = [root]
    state.selection = .repository(repo.id)
    return state
  }

  private func makeGitWorktreeState(repositoryRoot: URL, worktreeRoot: URL) -> RepositoriesFeature.State {
    let repositoryRoot = repositoryRoot.standardizedFileURL
    let worktreeRoot = worktreeRoot.standardizedFileURL
    let worktree = Worktree(
      id: worktreeRoot.path(percentEncoded: false),
      name: "feature-handoff",
      detail: "feature-handoff",
      workingDirectory: worktreeRoot,
      repositoryRootURL: repositoryRoot
    )
    let repository = Repository(
      id: repositoryRoot.path(percentEncoded: false),
      rootURL: repositoryRoot,
      name: "App",
      worktrees: [worktree]
    )
    var state = RepositoriesFeature.State()
    state.repositories = [repository]
    state.repositoryRoots = [repositoryRoot]
    state.selection = .worktree(worktree.id)
    return state
  }

  // MARK: - Command palette item presence

  @Test func workspaceShowsHandoffCommands() throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let repositories = makeWorkspaceState(root: root)

    let items = CommandPaletteFeature.commandPaletteItems(from: repositories)
    let ids = items.map(\.id)

    #expect(ids.contains(CommandPaletteItemID.handOff))
  }

  @Test func regularGitWorktreeShowsHandoffCommands() {
    let repositories = makeGitWorktreeState(
      repositoryRoot: URL(fileURLWithPath: "/tmp/repo"),
      worktreeRoot: URL(fileURLWithPath: "/tmp/repo-feature")
    )

    let items = CommandPaletteFeature.commandPaletteItems(from: repositories)
    let ids = items.map(\.id)

    #expect(ids.contains(CommandPaletteItemID.handOff))
  }

  @Test func plainFolderShowsHandoffCommands() {
    let rootURL = URL(fileURLWithPath: "/tmp/plain-folder")
    let repo = Repository(
      id: rootURL.path,
      rootURL: rootURL,
      name: "Plain",
      kind: .plain,
      worktrees: IdentifiedArray(uniqueElements: [])
    )
    var repositories = RepositoriesFeature.State()
    repositories.repositories = [repo]
    repositories.selection = .repository(repo.id)

    let items = CommandPaletteFeature.commandPaletteItems(from: repositories)
    let ids = items.map(\.id)

    #expect(ids.contains(CommandPaletteItemID.handOff))
  }

  // MARK: - HUD presentation

  @Test(.dependencies) func openHandoffHudPresentsForDetectedAgent() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let state = AppFeature.State(
      repositories: makeWorkspaceState(root: root),
      settings: SettingsFeature.State()
    )
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.handoffSourceContext = { _ in
        HandoffSourceContext(
          sessionContext: HandoffStore.SessionContext(
            agent: "codex",
            paneID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9)).uuidString,
            paneTitle: "codex",
            source: "terminal-scrollback",
            confidence: "fallback",
            excerptText: nil
          ),
          observation: nil
        )
      }
    }
    store.exhaustivity = .off

    await store.send(.openHandoffHud) {
      let hud = try #require($0.handoffHud)
      #expect(hud.source.agentToken == "codex")
      #expect(hud.phase == .choosing)
    }

    await store.send(.handoffHud(.presented(.delegate(.dismiss)))) {
      $0.handoffHud = nil
    }
  }

  @Test(.dependencies) func openHandoffHudUsesCanvasFocusedWorktree() async throws {
    let repositoryRoot = URL(fileURLWithPath: "/tmp/canvas-handoff-repo")
    let worktreeRoot = URL(fileURLWithPath: "/tmp/canvas-handoff-worktree")
    var repositories = makeGitWorktreeState(repositoryRoot: repositoryRoot, worktreeRoot: worktreeRoot)
    let worktreeID = worktreeRoot.standardizedFileURL.path(percentEncoded: false)
    repositories.selection = .canvas
    let capturedWorktreeID = LockIsolated<Worktree.ID?>(nil)
    let paneID = uuid(9).uuidString
    let store = TestStore(
      initialState: AppFeature.State(
        repositories: repositories,
        settings: SettingsFeature.State()
      )
    ) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.canvasFocusedWorktreeID = { worktreeID }
      $0.terminalClient.handoffSourceContext = { id in
        capturedWorktreeID.setValue(id)
        return HandoffSourceContext(
          sessionContext: HandoffStore.SessionContext(
            agent: "codex",
            paneID: paneID,
            paneTitle: "codex",
            source: "terminal-scrollback",
            confidence: "fallback",
            excerptText: nil
          ),
          observation: nil
        )
      }
    }
    store.exhaustivity = .off

    await store.send(.openHandoffHud) {
      let hud = try #require($0.handoffHud)
      #expect(hud.worktree.id == worktreeID)
      #expect(hud.source.agentToken == "codex")
    }
    #expect(capturedWorktreeID.value == worktreeID)
  }

  @Test(.dependencies) func openHandoffHudWarnsWithoutDetectedAgent() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let state = AppFeature.State(
      repositories: makeWorkspaceState(root: root),
      settings: SettingsFeature.State()
    )
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.handoffSourceContext = { _ in nil }
    }
    store.exhaustivity = .off

    await store.send(.openHandoffHud)
    await store.receive(\.repositories.showToast) {
      guard case .warning(let message) = $0.repositories.statusToast else {
        Issue.record("Expected warning toast")
        return
      }
      #expect(message.contains("No agent detected"))
    }
    #expect(store.state.handoffHud == nil)
  }

  @Test(.dependencies) func agentRowHandOffPresentsHudForEntryPane() async throws {
    let repositoryRoot = try makeTempRoot()
    defer { remove(repositoryRoot) }
    let worktreeRoot = try makeTempRoot()
    defer { remove(worktreeRoot) }
    var repositories = makeGitWorktreeState(repositoryRoot: repositoryRoot, worktreeRoot: worktreeRoot)
    // Deselect: the context menu must not depend on the entry being selected.
    repositories.selection = nil
    let worktreeID = worktreeRoot.standardizedFileURL.path(percentEncoded: false)
    let surfaceID = uuid(7)
    let entry = activeAgentEntry(
      id: uuid(1),
      worktreeID: worktreeID,
      surfaceID: surfaceID,
      displayState: .working
    )
    repositories.activeAgents.entries = [entry]
    let state = AppFeature.State(
      repositories: repositories,
      settings: SettingsFeature.State()
    )

    let capturedSurface = LockIsolated<(Worktree.ID, UUID)?>(nil)
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.handoffSourceContextForSurface = { worktreeID, surfaceID in
        capturedSurface.setValue((worktreeID, surfaceID))
        return HandoffSourceContext(
          sessionContext: HandoffStore.SessionContext(
            agent: "codex",
            paneID: surfaceID.uuidString,
            paneTitle: "codex",
            source: "terminal-scrollback",
            confidence: "fallback",
            excerptText: nil
          ),
          observation: nil
        )
      }
    }
    store.exhaustivity = .off

    await store.send(.repositories(.activeAgents(.handOffTapped(entry.id)))) {
      let hud = try #require($0.handoffHud)
      #expect(hud.source.agentToken == "codex")
      #expect(hud.worktree.id == worktreeID)
      #expect(hud.phase == .choosing)
    }
    // The source is captured from the entry's own pane, not the focused one.
    #expect(capturedSurface.value?.0 == worktreeID)
    #expect(capturedSurface.value?.1 == surfaceID)
  }

  @Test(.dependencies) func agentRowHandOffWarnsWithoutDetectedAgent() async throws {
    let repositoryRoot = try makeTempRoot()
    defer { remove(repositoryRoot) }
    let worktreeRoot = try makeTempRoot()
    defer { remove(worktreeRoot) }
    var repositories = makeGitWorktreeState(repositoryRoot: repositoryRoot, worktreeRoot: worktreeRoot)
    let worktreeID = worktreeRoot.standardizedFileURL.path(percentEncoded: false)
    let entry = activeAgentEntry(
      id: uuid(1),
      worktreeID: worktreeID,
      surfaceID: uuid(7),
      displayState: .working
    )
    repositories.activeAgents.entries = [entry]
    let state = AppFeature.State(
      repositories: repositories,
      settings: SettingsFeature.State()
    )

    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.handoffSourceContextForSurface = { _, _ in nil }
    }
    store.exhaustivity = .off

    await store.send(.repositories(.activeAgents(.handOffTapped(entry.id))))
    await store.receive(\.repositories.showToast) {
      guard case .warning(let message) = $0.repositories.statusToast else {
        Issue.record("Expected warning toast")
        return
      }
      #expect(message.contains("No agent detected"))
    }
    #expect(store.state.handoffHud == nil)
  }

  // MARK: - Palette delegate opens the HUD; the HUD asks the live agent

  @Test(.dependencies) func paletteHandOffInjectsRequestAndObservesCliCompletion() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }

    let sourceSurfaceID = uuid(4)
    let state = AppFeature.State(
      repositories: makeWorkspaceState(root: root),
      settings: SettingsFeature.State()
    )
    let injected = LockIsolated<[String]>([])
    let focused = LockIsolated<[(Worktree.ID, UUID)]>([])
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.date.now = Date(timeIntervalSince1970: 1_760_000_000)
      $0.uuid = .incrementing
      $0.terminalClient.sendTextToSurface = { _, _, text in
        injected.withValue { $0.append(text) }
        return true
      }
      $0.terminalClient.focusSurface = { worktreeID, surfaceID in
        focused.withValue { $0.append((worktreeID, surfaceID)) }
        return true
      }
      $0.terminalClient.handoffSourceContext = { _ in
        HandoffSourceContext(
          sessionContext: HandoffStore.SessionContext(
            agent: "codex",
            paneID: sourceSurfaceID.uuidString,
            paneTitle: "codex",
            source: "terminal-scrollback",
            confidence: "fallback",
            excerptText: ""
          ),
          observation: AgentLaunchObservation(model: "gpt-5.4", executionMode: .unrestricted)
        )
      }
    }
    store.exhaustivity = .off

    await store.send(.commandPalette(.delegate(.handOff)))
    let hud = try #require(store.state.handoffHud)
    #expect(hud.source.agentToken == "codex")
    let claudeIndex = try #require(hud.targets.firstIndex { $0.agent == .claude })

    await store.send(.handoffHud(.presented(.setSelectedIndex(claudeIndex))))
    await store.send(.handoffHud(.presented(.confirmSelection)))

    // The HUD asked the live agent to hand off itself — nothing launched yet.
    #expect(injected.value.first?.contains("prowl handoff to claude --brief -") == true)
    guard case .running(let run)? = store.state.handoffHud?.phase, run.stage == .requesting else {
      Issue.record("Expected requesting stage, got \(String(describing: store.state.handoffHud?.phase))")
      return
    }
    let requestID = try #require(run.requestID)

    // The agent ran the CLI; the socket handler announces the completion and
    // the app routes it into the HUD, which finishes and focuses the receiver.
    let launchedPaneID = uuid(11)
    await store.send(
      .handoffCliCompleted(
        HandoffCLICompletion(
          action: .toAgent,
          sourcePaneID: sourceSurfaceID.uuidString,
          toAgent: "claude",
          briefing: .inline,
          launched: HandoffLaunchedPane(
            worktreeID: root.path(percentEncoded: false),
            worktreeName: "Checkout Flow",
            tabID: uuid(12).uuidString,
            paneID: launchedPaneID.uuidString,
            paneTitle: "claude"
          ),
          requestID: requestID
        )
      )
    )
    await store.receive(\.handoffHud.presented.cliCompleted)
    await store.finish()

    guard case .finished(.handedOff(let name))? = store.state.handoffHud?.phase else {
      Issue.record("Expected handed-off outcome, got \(String(describing: store.state.handoffHud?.phase))")
      return
    }
    #expect(name == "Claude Code")
    #expect(focused.value.first?.1 == launchedPaneID)
  }

  @Test(.dependencies) func paletteHandOffAttributesFocusedAgent() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let claudeSurfaceID = uuid(4)
    let state = AppFeature.State(
      repositories: makeWorkspaceState(root: root),
      settings: SettingsFeature.State()
    )
    let store = TestStore(initialState: state) {
      AppFeature()
    } withDependencies: {
      $0.terminalClient.handoffSourceContext = { _ in
        HandoffSourceContext(
          sessionContext: HandoffStore.SessionContext(
            agent: "claude",
            paneID: claudeSurfaceID.uuidString,
            paneTitle: "claude",
            source: "terminal-scrollback",
            confidence: "fallback",
            excerptText: "focused claude context"
          ),
          observation: nil
        )
      }
    }
    store.exhaustivity = .off

    // The HUD source is the focused pane's agent, not any sibling pane.
    await store.send(.commandPalette(.delegate(.handOff)))
    let hud = try #require(store.state.handoffHud)
    #expect(hud.source.agentToken == "claude")
    #expect(hud.source.sessionContext?.excerptText == "focused claude context")
    let claudeTarget = try #require(hud.targets.first { $0.agent == .claude })
    #expect(claudeTarget.isCurrentAgent)
  }

  private func activeAgentEntry(
    id: UUID,
    worktreeID: Worktree.ID,
    tabID: TerminalTabID = TerminalTabID(rawValue: UUID()),
    surfaceID: UUID,
    displayState: AgentDisplayState,
    agent: DetectedAgent = .codex
  ) -> ActiveAgentEntry {
    ActiveAgentEntry(
      id: id,
      worktreeID: worktreeID,
      worktreeName: "Checkout Flow",
      workingDirectory: nil,
      tabID: tabID,
      paneTitle: agent.rawValue,
      surfaceID: surfaceID,
      paneIndex: 1,
      iconLookupToken: agent.iconLookupToken,
      agent: agent,
      rawState: displayState == .working ? .working : .idle,
      displayState: displayState,
      lastChangedAt: Date(timeIntervalSince1970: 1_760_000_000)
    )
  }
}
