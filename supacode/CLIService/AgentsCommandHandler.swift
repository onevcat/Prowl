import Foundation
import ProwlCLIShared

struct AgentsRuntimeSnapshot {
  let repositoriesState: RepositoriesFeature.State
  let listSnapshot: ListRuntimeSnapshot
  /// Live detector results keyed by pane. Reducer entries intentionally skip
  /// raw-state-only changes to avoid invalidating the sidebar, so CLI snapshots
  /// must source state and reason from terminal state instead.
  let screenDetectionsBySurfaceID: [UUID: AgentScreenDetection]
  let signalsBySurfaceID: [UUID: AgentSignalsPayload]

  init(
    repositoriesState: RepositoriesFeature.State,
    listSnapshot: ListRuntimeSnapshot,
    screenDetectionsBySurfaceID: [UUID: AgentScreenDetection],
    signalsBySurfaceID: [UUID: AgentSignalsPayload] = [:]
  ) {
    self.repositoriesState = repositoriesState
    self.listSnapshot = listSnapshot
    self.screenDetectionsBySurfaceID = screenDetectionsBySurfaceID
    self.signalsBySurfaceID = signalsBySurfaceID
  }
}

final class AgentsCommandHandler: CommandHandler {
  typealias SnapshotProvider = @MainActor () throws -> AgentsRuntimeSnapshot

  private struct TerminalAgentContext {
    let worktree: ListRuntimeSnapshot.Worktree
    let tab: ListRuntimeSnapshot.Tab
    let pane: ListRuntimeSnapshot.Pane
    let focused: Bool
  }

  private let snapshotProvider: SnapshotProvider
  private let dateFormatter: ISO8601DateFormatter

  init(snapshotProvider: @escaping SnapshotProvider) {
    self.snapshotProvider = snapshotProvider
    self.dateFormatter = ISO8601DateFormatter()
    self.dateFormatter.formatOptions = [.withInternetDateTime]
    self.dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
  }

  // swiftlint:disable:next async_without_await
  func handle(envelope: CommandEnvelope) async -> CommandResponse {
    do {
      let snapshot = try snapshotProvider()
      let payload = makePayload(from: snapshot, includeHandles: envelope.output == .text)
      return try CommandResponse(
        ok: true,
        command: "agents",
        schemaVersion: "prowl.cli.agents.v1",
        data: RawJSON(encoding: payload)
      )
    } catch {
      return CommandResponse(
        ok: false,
        command: "agents",
        schemaVersion: "prowl.cli.agents.v1",
        error: CommandError(
          code: CLIErrorCode.agentsFailed,
          message: "Failed to list agents."
        )
      )
    }
  }

  private func makePayload(
    from snapshot: AgentsRuntimeSnapshot,
    includeHandles: Bool
  ) -> AgentsCommandPayload {
    let repositoriesState = snapshot.repositoriesState
    let metadata = SidebarListView.activeAgentWorktreeMetadata(
      repositories: repositoriesState.repositories,
      customTitles: repositoriesState.repositoryCustomTitles
    )
    let terminalContexts = makeTerminalContexts(from: snapshot.listSnapshot)
    let worktreeContexts = Dictionary(
      ListRuntimeSnapshotBuilder
        .orderedWorktreeContexts(from: repositoriesState)
        .map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )

    let agents = repositoriesState.activeAgents.entries.compactMap { entry -> AgentsCommandAgent? in
      guard let terminalContext = terminalContexts[entry.surfaceID] else {
        return nil
      }
      let display = SidebarListView.activeAgentRowDisplay(
        for: entry,
        repositories: repositoriesState.repositories,
        metadata: metadata
      )
      let projectPath = projectPath(
        for: entry, repositoriesState: repositoriesState, worktreeContexts: worktreeContexts)

      let screenDetection = snapshot.screenDetectionsBySurfaceID[entry.surfaceID]
      return AgentsCommandAgent(
        id: entry.surfaceID.uuidString,
        type: entry.agent.rawValue,
        name: entry.displayName,
        status: AgentsCommandStatus(rawValue: entry.displayState.rawValue) ?? .idle,
        rawState: (screenDetection?.state ?? entry.rawState).rawValue,
        detectionReason: screenDetection?.reason.identifier,
        lastChangedAt: dateFormatter.string(from: entry.lastChangedAt),
        project: AgentsCommandProject(
          name: display.repositoryName,
          branch: display.branchName,
          path: projectPath
        ),
        worktree: AgentsCommandWorktree(
          id: terminalContext.worktree.id,
          name: terminalContext.worktree.name,
          path: terminalContext.worktree.path,
          rootPath: terminalContext.worktree.rootPath,
          kind: terminalContext.worktree.kind.rawValue
        ),
        tab: AgentsCommandTab(
          id: terminalContext.tab.id.uuidString,
          title: terminalContext.tab.title,
          selected: terminalContext.tab.selected
        ),
        pane: AgentsCommandPane(
          id: terminalContext.pane.id.uuidString,
          handle: includeHandles ? terminalContext.pane.handle : nil,
          index: entry.paneIndex,
          title: terminalContext.pane.title,
          cwd: terminalContext.pane.cwd,
          focused: terminalContext.focused
        ),
        session: entry.session.map {
          AgentsCommandSession(
            id: $0.id,
            path: $0.transcriptPath?.path,
            confidence: $0.confidence.rawValue,
            source: $0.source.rawValue
          )
        },
        signals: snapshot.signalsBySurfaceID[entry.surfaceID] ?? .empty
      )
    }

    return AgentsCommandPayload(count: agents.count, agents: agents)
  }

  private func makeTerminalContexts(from snapshot: ListRuntimeSnapshot) -> [UUID: TerminalAgentContext] {
    var contexts: [UUID: TerminalAgentContext] = [:]
    for worktree in snapshot.worktrees {
      for tab in worktree.tabs {
        for pane in tab.panes {
          contexts[pane.id] = TerminalAgentContext(
            worktree: worktree,
            tab: tab,
            pane: pane,
            focused: worktree.id == snapshot.focusedWorktreeID && tab.selected && tab.focusedPaneID == pane.id
          )
        }
      }
    }
    return contexts
  }

  private func projectPath(
    for entry: ActiveAgentEntry,
    repositoriesState: RepositoriesFeature.State,
    worktreeContexts: [Worktree.ID: ListRuntimeSnapshotBuilder.WorktreeContext]
  ) -> String {
    if let workingDirectory = entry.workingDirectory,
      let key = SidebarListView.resolveWorktreeID(
        forWorkingDirectory: workingDirectory,
        in: repositoriesState.repositories
      ),
      let context = worktreeContexts[key]
    {
      return context.path
    }
    if let workingDirectory = entry.workingDirectory {
      return workingDirectory.path(percentEncoded: false)
    }
    return worktreeContexts[entry.worktreeID]?.path ?? entry.worktreeName
  }
}
