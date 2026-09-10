import Foundation
import Testing

@testable import supacode

@MainActor
struct HostControlConsoleTests {
  @Test func changingExecutableSwitchesToDefaultAndRestoresWithoutRewriting() throws {
    let suite = "ConsoleExecutable-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let profile = AgentProfile(name: "Codex", runtime: .codex)
    let console = HostControlConsole(manager: manager, profiles: [profile], defaults: defaults)
    console.selectPreset(.codex)
    console.command = "codex --yolo --model custom"
    #expect(console.preset == .codex)
    console.command = "ai cx"
    #expect(console.preset == .custom)
    #expect(console.command == "ai cx")
    let saved: [String: Any] = [
      "enabled": true, "profileID": profile.id.uuidString, "runtime": "codex",
      "bypass": false, "directory": "", "preset": "codex", "command": "ai cx",
    ]
    defaults.set(try JSONSerialization.data(withJSONObject: saved), forKey: "remoteMirrorControlConsole")
    let restored = HostControlConsole(manager: manager, profiles: [profile], defaults: defaults)
    #expect(restored.preset == .custom)
    #expect(restored.command == "ai cx")
    #expect(ConsoleAgentPreset.claude.matching(command: "cfuse --cc") == .custom)
    #expect(ConsoleAgentPreset.codex.matching(command: "/custom/bin/codex --yolo") == .custom)
  }

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
    first.command = "codex --yolo --model test-model"
    let restored = HostControlConsole(manager: manager, profiles: [profile], defaults: defaults)
    #expect(restored.enabled)
    #expect(restored.directory == "/tmp/custom-console")
    #expect(restored.profile.model == "test-model")
    #expect(restored.profile.executionMode == .unrestricted)
    #expect(restored.command == "codex --yolo --model test-model")
    #expect(!restored.isStarting)
    #expect(restored.surface == nil)
  }

  @Test func oldProfileIDRestoresByRuntimeWithoutAStaleError() throws {
    let suite = "ConsoleMigration-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let old: [String: Any] = [
      "enabled": true, "profileID": UUID().uuidString, "runtime": "codex",
      "model": "saved-model", "bypass": true, "directory": "/tmp/console",
    ]
    defaults.set(
      try JSONSerialization.data(withJSONObject: old), forKey: "remoteMirrorControlConsole")
    let profile = AgentProfile(name: "Codex", runtime: .codex)
    let console = HostControlConsole(
      manager: WorktreeTerminalManager(runtime: GhosttyRuntime()), profiles: [profile],
      defaults: defaults)
    #expect(console.profile.id == profile.id)
    #expect(console.command == "codex --yolo --model 'saved-model'")
    #expect(console.error == nil)
    #expect(console.configurationNotice == nil)
    #expect(console.enabled)
    #expect(console.directory == "/tmp/console")
    console.selectPreset(.claude)
    #expect(console.command == "claude --dangerously-skip-permissions")
    console.selectPreset(.custom)
    #expect(console.command.isEmpty)
    console.command = "pi --model test"
    let restored = HostControlConsole(
      manager: WorktreeTerminalManager(runtime: GhosttyRuntime()), profiles: [profile],
      defaults: defaults)
    #expect(restored.preset == .custom)
    #expect(restored.command == "pi --model test")
  }

  @Test func corruptSettingsAreANoticeAndEditingClearsIt() throws {
    let suite = "ConsoleInvalid-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data("invalid".utf8), forKey: "remoteMirrorControlConsole")
    let console = HostControlConsole(
      manager: WorktreeTerminalManager(runtime: GhosttyRuntime()), profiles: [], defaults: defaults)
    #expect(console.error == nil)
    #expect(console.configurationNotice != nil)
    console.command = "codex --yolo"
    #expect(console.configurationNotice == nil)
  }

  @Test func commandUsesLiteralArgumentsAndOnePromptCarrier() throws {
    let invocation = try ConsoleAgentPreset.invocation(
      command: "'/tmp/Agent CLI' --model 'model name' '$(touch nope)'", prompt: "Guide\nsecond line"
    )
    #expect(invocation.executable == "/tmp/Agent CLI")
    #expect(
      invocation.arguments == ["--model", "model name", "$(touch nope)", "Guide\nsecond line"])
    let profile = AgentProfile(name: "Codex", runtime: .codex, model: "must-not-duplicate")
    let plan = try ConsoleAgentPreset.codex.plan(
      profile: profile, invocation: invocation, prompt: "Guide\nsecond line")
    #expect(plan.invocation == invocation)
    #expect(!plan.terminalInput.contains("must-not-duplicate"))
    #expect(plan.terminalInput.contains("'$(touch nope)'"))
    #expect(plan.terminalInput.contains("\"$PROWL_LAUNCH_PROMPT\""))
    #expect(!plan.terminalInput.contains("Guide\nsecond line"))
    for invalid in ["", "   ", "codex\nwhoami", "codex\0"] {
      #expect(throws: (any Error).self) {
        try ConsoleAgentPreset.invocation(command: invalid, prompt: "Guide")
      }
    }
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
