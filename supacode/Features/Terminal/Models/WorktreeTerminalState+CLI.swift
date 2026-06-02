import Foundation
import GhosttyKit

struct CLIWorktreeTerminalSnapshot: Sendable {
  let tabs: [CLITerminalTabSnapshot]
  let taskStatus: ListCommandTask.Status?
}

struct CLITerminalTabSnapshot: Sendable {
  let id: UUID
  let title: String
  let selected: Bool
  let focusedPaneID: UUID?
  let panes: [CLITerminalPaneSnapshot]
}

struct CLITerminalPaneSnapshot: Sendable {
  let id: UUID
  let title: String
  let cwd: String?
}

extension WorktreeTerminalState {
  func makeCLIListSnapshot() -> CLIWorktreeTerminalSnapshot {
    let selectedTabID = tabManager.selectedTabId

    let tabs: [CLITerminalTabSnapshot] = tabManager.tabs.map { tab in
      let paneIDs = trees[tab.id]?.leaves().map(\.id) ?? []
      let panes = paneIDs.map { paneID in
        let cwd = inheritedSurfaceConfig(
          fromSurfaceId: paneID,
          context: GHOSTTY_SURFACE_CONTEXT_TAB
        ).workingDirectory?.path(percentEncoded: false)

        let title = paneTitle(surfaceID: paneID, tabID: tab.id, fallbackTabTitle: tab.displayTitle)
        return CLITerminalPaneSnapshot(id: paneID, title: title, cwd: cwd)
      }

      return CLITerminalTabSnapshot(
        id: tab.id.rawValue,
        title: tab.displayTitle,
        selected: tab.id == selectedTabID,
        focusedPaneID: focusedSurfaceIdByTab[tab.id],
        panes: panes
      )
    }

    return CLIWorktreeTerminalSnapshot(
      tabs: tabs,
      taskStatus: taskStatus == .running ? .running : .idle
    )
  }

  func paneTitle(surfaceID: UUID, tabID: TerminalTabID, fallbackTabTitle: String) -> String {
    let rawTitle = surfaces[surfaceID]?.bridge.state.title?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )

    if let rawTitle, let displayTitle = userFacingTitle(from: rawTitle, tabId: tabID) {
      return displayTitle
    }

    return fallbackTabTitle
  }
}

// MARK: - CLI Command Finished Waiting

extension WorktreeTerminalState {
  /// Returns an `AsyncStream` that yields exactly once when the command finishes
  /// on the given surface. The caller should race this against a timeout.
  func waitForCommandFinished(surfaceID: UUID) -> AsyncStream<(exitCode: Int?, durationMs: Int)> {
    // Cancel any existing waiter for this surface.
    commandFinishedWaiters[surfaceID]?.finish()
    commandFinishedWaiters.removeValue(forKey: surfaceID)

    return AsyncStream { continuation in
      commandFinishedWaiters[surfaceID] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor in
          self?.commandFinishedWaiters.removeValue(forKey: surfaceID)
        }
      }
    }
  }
}

// MARK: - CLI Send Snapshot

struct CLISendTabSnapshot {
  let focusedPaneID: UUID?
  let panes: [TargetResolutionSnapshot.Pane]
}

extension WorktreeTerminalState {
  func makeCLISendSnapshot(for tabId: TerminalTabID) -> CLISendTabSnapshot? {
    let paneIDs = trees[tabId]?.leaves().map(\.id) ?? []
    guard !paneIDs.isEmpty else { return nil }

    let focusedPaneID = focusedSurfaceIdByTab[tabId]
    let panes: [TargetResolutionSnapshot.Pane] = paneIDs.compactMap { paneID in
      guard let surfaceView = surfaces[paneID] else { return nil }
      let cwd = inheritedSurfaceConfig(
        fromSurfaceId: paneID,
        context: GHOSTTY_SURFACE_CONTEXT_TAB
      ).workingDirectory?.path(percentEncoded: false)
      let title = paneTitle(surfaceID: paneID, tabID: tabId, fallbackTabTitle: "")
      return TargetResolutionSnapshot.Pane(
        id: paneID,
        title: title,
        cwd: cwd,
        isFocusedInTab: paneID == focusedPaneID,
        surfaceView: surfaceView
      )
    }

    return CLISendTabSnapshot(focusedPaneID: focusedPaneID, panes: panes)
  }
}

nonisolated func makeCommandInput(script: String) -> String? {
  let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }
  return trimmed + "\n"
}

nonisolated func makeBlockingScriptInput(script: String) -> String? {
  guard let input = makeCommandInput(script: script) else { return nil }
  return input + "exit\n"
}
