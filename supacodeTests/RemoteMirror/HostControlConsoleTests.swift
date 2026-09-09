import Foundation
import Testing

@testable import supacode

@MainActor
struct HostControlConsoleTests {
  @Test func settingsRestoreWithoutLaunchingAnAgent() throws {
    let suite = "ConsoleSettings-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let profile = AgentProfile(name: "Codex", runtime: .codex)
    let first = HostControlConsole(manager: manager, profiles: [profile], defaults: defaults)
    #expect(!first.enabled)
    #expect(first.profile.executionMode == .standard)
    first.enabled = true
    first.directory = "/tmp/custom-console"
    first.profile.model = "test-model"
    first.profile.executionMode = .unrestricted
    let restored = HostControlConsole(manager: manager, profiles: [profile], defaults: defaults)
    #expect(restored.enabled)
    #expect(restored.directory == "/tmp/custom-console")
    #expect(restored.profile.model == "test-model")
    #expect(restored.profile.executionMode == .unrestricted)
    #expect(!restored.isStarting)
    #expect(restored.surface == nil)
  }

  @Test func controlContextIsDiscoverableWithoutAddingAFakeRepository() {
    let directory = URL(fileURLWithPath: "/tmp/control-test")
    let control = Worktree(
      id: HostControlConsole.worktreeID, name: "AI Control Console", detail: "",
      workingDirectory: directory, repositoryRootURL: directory)
    let contexts = ListRuntimeSnapshotBuilder.orderedWorktreeContexts(
      from: .init(), controlConsole: control)
    #expect(contexts.count == 1)
    #expect(contexts.first?.id == control.id)
    #expect(contexts.first?.path == directory.path)
    #expect(ListRuntimeSnapshotBuilder.orderedWorktreeContexts(from: .init()).isEmpty)
  }

  @Test func guideBindsEveryCommandToTheExplicitInstance() {
    let guide = URL(
      fileURLWithPath:
        "/Applications/Prowl Debug.app/Contents/Resources/docs/remote-mirror-control.md")
    let cli = URL(
      fileURLWithPath: "/Applications/Prowl Debug.app/Contents/Resources/prowl-cli/prowl")
    let prompt = HostControlConsole.prompt(guide: guide, cli: cli, socket: "/tmp/test-control.sock")
    #expect(prompt.contains(guide.path))
    #expect(prompt.contains("PROWL_CLI_SOCKET="))
    #expect(prompt.contains(AgentInvocation.shellQuote(cli.path)))
    #expect(prompt.contains("Never fall back"))
    #expect(!prompt.contains("CODEX_HOME"))
  }

  @Test func consoleTitleAndLaunchOptionsRemainExplicit() throws {
    let profile = AgentProfile(
      name: "Codex", runtime: .codex, model: "fixture-model", executionMode: .unrestricted)
    let plan = try AgentProfileLaunchPlanner.plan(
      for: profile, intent: .prompt("Read the guide"),
      homeBaseDirectory: URL(fileURLWithPath: "/tmp/profile-homes"))
    let request = AgentProfileLaunchRequest(
      plan: plan, placement: .tab(background: true),
      title: "AI Control Console", locksTitle: true)
    #expect(request.locksTitle)
    #expect(request.title == "AI Control Console")
    #expect(plan.terminalInput.contains("fixture-model"))
    #expect(plan.terminalInput.contains("--dangerously-bypass-approvals-and-sandbox"))
    #expect(plan.dedicatedHome == nil)
  }
}
