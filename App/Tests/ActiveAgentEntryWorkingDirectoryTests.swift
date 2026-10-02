import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import supacode

@MainActor
struct ActiveAgentEntryWorkingDirectoryTests {
  @Test func grokAliasUsesGrokIcon() throws {
    let job = ForegroundJob(
      processGroupID: 42,
      processes: [
        ForegroundProcess(
          pid: 100,
          name: "agent",
          argv0: "agent",
          cmdline: "/Users/me/.grok/bin/agent --always-approve"
        )
      ]
    )
    let identified = try #require(identifyAgentInJob(job))
    let fixture = makeState(launchDirectory: URL(fileURLWithPath: "/tmp/repo/worktree", isDirectory: true))

    let entry = try #require(
      fixture.state.activeAgentEntry(
        surfaceID: fixture.surface.id,
        tabId: fixture.tabId,
        state: PaneAgentState(
          detectedAgent: identified.agent,
          iconLookupToken: identified.iconLookupToken,
          state: .working
        )
      )
    )

    #expect(identified.name == "agent")
    #expect(entry.iconLookupToken == "grok")
    #expect(entry.iconSource?.assetName == "Grok")
  }

  @Test func activeAgentEntryUsesCachedPWD() throws {
    let launchDirectory = URL(fileURLWithPath: "/tmp/repo/worktree", isDirectory: true)
    let reportedDirectory = URL(fileURLWithPath: "/tmp/repo/worktree/Sources", isDirectory: true)
    let fixture = makeState(launchDirectory: launchDirectory)
    fixture.surface.bridge.state.pwd = reportedDirectory.path(percentEncoded: false)

    let entry = try #require(
      fixture.state.activeAgentEntry(
        surfaceID: fixture.surface.id,
        tabId: fixture.tabId,
        state: PaneAgentState(detectedAgent: .claude, state: .working)
      )
    )

    #expect(
      entry.workingDirectory?.path(percentEncoded: false)
        == reportedDirectory.path(percentEncoded: false)
    )
  }

  @Test func activeAgentEntryFallsBackToSurfaceLaunchDirectory() throws {
    let launchDirectory = URL(fileURLWithPath: "/tmp/repo/worktree", isDirectory: true)
    let fixture = makeState(launchDirectory: launchDirectory)

    let entry = try #require(
      fixture.state.activeAgentEntry(
        surfaceID: fixture.surface.id,
        tabId: fixture.tabId,
        state: PaneAgentState(detectedAgent: .claude, state: .working)
      )
    )

    #expect(
      entry.workingDirectory?.path(percentEncoded: false)
        == launchDirectory.path(percentEncoded: false)
    )
  }

  private struct Fixture {
    let state: WorktreeTerminalState
    let tabId: TerminalTabID
    let surface: GhosttySurfaceView
  }

  private func makeState(launchDirectory: URL) -> Fixture {
    let state = WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: Worktree(
        id: "/tmp/repo/worktree",
        name: "worktree",
        detail: "",
        workingDirectory: URL(fileURLWithPath: "/tmp/repo/worktree"),
        repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
      )
    )
    let surface = GhosttySurfaceView(
      runtime: state.runtime,
      workingDirectory: launchDirectory,
      fontSize: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
    let tabId = state.tabManager.createTab(title: "worktree 1", icon: "terminal")
    state.surfaces[surface.id] = surface
    state.trees[tabId] = SplitTree<GhosttySurfaceView>(view: surface)
    state.focusedSurfaceIdByTab[tabId] = surface.id
    return Fixture(state: state, tabId: tabId, surface: surface)
  }
}
