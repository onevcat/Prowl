import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import GhosttyKit
import Sharing
import Testing

@testable import supacode

@MainActor
@Suite("Agent account shown for a pane")
struct AgentAccountPaneLabelTests {
  /// A running pane keeps the environment it launched with.
  @Test(.dependencies) func paneKeepsItsAccountAfterTheSettingsChange() {
    let state = makeState(defaultAccount: "work")
    let surfaceID = UUID()
    state.agentAccountBySurface.updateValue("personal", forKey: surfaceID)

    #expect(state.resolvedAgentAccount == "work")
    #expect(state.agentAccount(forSurface: surfaceID) == "personal")
  }

  /// Recorded `nil` must stay distinguishable from "nothing recorded", or
  /// configuring an account later relabels panes still using `~/.claude`.
  @Test(.dependencies) func paneLaunchedWithoutAnAccountIsNotRelabelled() {
    let state = makeState(defaultAccount: "work")
    let surfaceID = UUID()
    state.agentAccountBySurface.updateValue(nil, forKey: surfaceID)

    #expect(state.agentAccount(forSurface: surfaceID) == nil)
  }

  @Test(.dependencies) func worktreeWithoutAPaneShowsWhatTheNextPaneWillUse() {
    let state = makeState(defaultAccount: "work")

    #expect(state.agentAccount(forSurface: nil) == "work")
    #expect(state.agentAccount(forSurface: UUID()) == "work")
  }

  @Test(.dependencies) func closingAPaneStopsReportingItsAccount() {
    let state = makeState(defaultAccount: "work")
    let surfaceID = UUID()
    state.agentAccountBySurface.updateValue(nil, forKey: surfaceID)

    state.forgetSurface(surfaceID)

    #expect(state.agentAccount(forSurface: surfaceID) == "work")
  }

  @Test(.dependencies) func launchEnvironmentCarriesTheAccountOverTheWorktreeVariables() throws {
    let account = "prowl-test-\(UUID().uuidString)"
    defer {
      try? FileManager.default.removeItem(at: SupacodePaths.agentAccountsDirectory.appending(path: account))
    }
    let state = makeState(defaultAccount: account)

    let launch = state.makeSurfaceLaunch()

    #expect(launch.account == account)
    #expect(launch.environment["PROWL_WORKTREE_PATH"] == "/tmp/repo/worktree")
    let claudeDirectory = try #require(launch.environment["CLAUDE_CONFIG_DIR"])
    let codexDirectory = try #require(launch.environment["CODEX_HOME"])
    #expect(claudeDirectory.hasSuffix("/accounts/\(account)/claude"))
    #expect(codexDirectory.hasSuffix("/accounts/\(account)/codex"))
    // `codex` refuses to start when its home does not exist.
    #expect(FileManager.default.fileExists(atPath: claudeDirectory))
    #expect(FileManager.default.fileExists(atPath: codexDirectory))
  }

  @Test(.dependencies) func launchWithoutAnAccountLeavesTheEnvironmentUntouched() {
    let state = makeState(defaultAccount: nil)

    let launch = state.makeSurfaceLaunch()

    #expect(launch.account == nil)
    #expect(launch.environment == state.worktree.scriptEnvironment)
  }

  private func makeState(defaultAccount: String?) -> WorktreeTerminalState {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.defaultAgentAccount = defaultAccount }
    return WorktreeTerminalState(
      runtime: GhosttyRuntime(),
      worktree: Worktree(
        id: "/tmp/repo/worktree",
        name: "worktree",
        detail: "",
        workingDirectory: URL(fileURLWithPath: "/tmp/repo/worktree"),
        repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
      )
    )
  }
}
