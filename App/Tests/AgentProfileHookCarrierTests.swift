import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct AgentProfileHookCarrierTests {
  @Test func managedHookValuesUseChildOnlyCarriersAndNeverTerminalInput() throws {
    let base = makePlan(
      invocation: AgentInvocation(executable: "claude", arguments: ["-p", "Prompt"]),
      prompt: "Prompt"
    )
    let preparedInvocation = AgentHookPreparedInvocation(
      invocation: AgentInvocation(executable: "claude", arguments: ["-p", "--settings", "{}", "Prompt"]),
      argumentValues: [2: #"{"secret":"hook-json"}"#]
    )
    let token = "token-should-never-be-typed"
    let socket = "/tmp/prowl custom.sock"
    let prepared = base.applyingManagedHook(
      preparedInvocation,
      resources: AgentHookResources(
        bundledCLIPath: "/Applications/Prowl Debug.app/Contents/Resources/prowl-cli/prowl",
        socketPath: socket
      ),
      launchCWD: URL(filePath: "/tmp/Project Space/界", directoryHint: .isDirectory),
      token: token,
      coveredEvents: [.needsInput, .sessionStart, .turnEnded]
    )

    #expect(prepared.hookRegistration?.token == token)
    #expect(
      prepared.hookRegistration?.launchCWD.path(percentEncoded: false).trimmingCharacters(
        in: CharacterSet(charactersIn: "/"))
        == "tmp/Project Space/界"
    )
    #expect(prepared.terminalInput.contains("\"$PROWL_LAUNCH_HOOK_ARG_0\""))
    #expect(prepared.terminalInput.contains("-u PROWL_LAUNCH_HOOK_TOKEN"))
    #expect(prepared.terminalInput.contains("-u PROWL_LAUNCH_HOOK_SOCKET"))
    #expect(prepared.terminalInput.contains("PROWL_AGENT_HOOK_TOKEN=\"$PROWL_LAUNCH_HOOK_TOKEN\""))
    #expect(prepared.terminalInput.contains("PROWL_CLI_SOCKET=\"$PROWL_LAUNCH_HOOK_SOCKET\""))
    #expect(!prepared.terminalInput.contains(token))
    #expect(!prepared.terminalInput.contains(socket))
    #expect(!prepared.terminalInput.contains("hook-json"))
    #expect(!prepared.terminalInput.contains("Prompt"))
  }

  /// OpenCode's plugin rides `OPENCODE_CONFIG_CONTENT`; the JSON reaches only the launched
  /// child through a carrier the typed command references by name, and the carrier itself is
  /// removed from that child like every other one.
  @Test func managedHookEnvironmentValuesUseChildOnlyCarriers() throws {
    let base = makePlan(
      invocation: AgentInvocation(executable: "opencode", arguments: ["--prompt", "Prompt"]),
      prompt: "Prompt"
    )
    let content =
      #"{"plugin":["file:///Applications/Prowl.app/Contents/Resources/agent-hooks/opencode/prowl-hooks.ts"]}"#
    let prepared = base.applyingManagedHook(
      AgentHookPreparedInvocation(
        invocation: base.invocation,
        argumentValues: [:],
        environmentValues: ["OPENCODE_CONFIG_CONTENT": content]
      ),
      resources: AgentHookResources(bundledCLIPath: "/bundle/prowl", socketPath: "/tmp/prowl.sock"),
      launchCWD: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      token: "opaque-token",
      coveredEvents: [.needsInput, .turnEnded]
    )

    #expect(prepared.environmentCarriers == ["PROWL_LAUNCH_HOOK_ENV_0"])
    #expect(prepared.surfaceEnvironment["PROWL_LAUNCH_HOOK_ENV_0"] == content)
    #expect(prepared.terminalInput.contains("OPENCODE_CONFIG_CONTENT=\"$PROWL_LAUNCH_HOOK_ENV_0\""))
    #expect(prepared.terminalInput.contains("-u PROWL_LAUNCH_HOOK_ENV_0"))
    #expect(!prepared.terminalInput.contains("prowl-hooks.ts"))
    #expect(prepared.invocation.arguments == ["--prompt", "Prompt"])
    // A Profile's own override of the same variable is typed first, so `env(1)` lets the
    // merged content win.
    let overridden = AgentProfileLaunchPlan(
      profileID: base.profileID,
      profileName: base.profileName,
      runtime: base.runtime,
      invocation: base.invocation,
      commandEnvironmentTokens: ["OPENCODE_CONFIG_CONTENT=\"$PROWL_ENV_OPENCODE_CONFIG_CONTENT\""],
      placement: base.placement,
      splitDirection: base.splitDirection,
      surfaceEnvironment: base.surfaceEnvironment.merging(
        ["PROWL_ENV_OPENCODE_CONFIG_CONTENT": "{}"], uniquingKeysWith: { $1 }),
      dedicatedHome: nil
    ).applyingManagedHook(
      AgentHookPreparedInvocation(
        invocation: base.invocation, argumentValues: [:], environmentValues: ["OPENCODE_CONFIG_CONTENT": content]),
      resources: AgentHookResources(bundledCLIPath: "/bundle/prowl", socketPath: "/tmp/prowl.sock"),
      launchCWD: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      token: "opaque-token",
      coveredEvents: [.turnEnded]
    )
    let tokens = overridden.commandEnvironmentTokens
    let overrideIndex = try #require(
      tokens.firstIndex(of: "OPENCODE_CONFIG_CONTENT=\"$PROWL_ENV_OPENCODE_CONFIG_CONTENT\""))
    let managedIndex = try #require(tokens.firstIndex(of: "OPENCODE_CONFIG_CONTENT=\"$PROWL_LAUNCH_HOOK_ENV_0\""))
    #expect(overrideIndex < managedIndex)
  }

  @Test func forwardingLocatorIsAChildOnlyCarrierAndRecordContentsStayOutOfEnvironment() {
    let base = makePlan(invocation: AgentInvocation(executable: "codex", arguments: []))
    let record = CodexForwardingRecord(
      locator: URL(filePath: "/tmp/private/session/opaque.json", directoryHint: .notDirectory)
    )
    let prepared = base.applyingManagedHook(
      AgentHookPreparedInvocation(
        invocation: AgentInvocation(executable: "codex", arguments: ["-c", "notify=[]"]),
        argumentValues: [1: #"notify=["/bundle/prowl","agents","_hook","codex","agent-turn-complete"]"#]
      ),
      resources: AgentHookResources(bundledCLIPath: "/bundle/prowl", socketPath: "/tmp/prowl.sock"),
      launchCWD: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      token: "opaque-token",
      coveredEvents: [.turnEnded],
      forwardingRecord: record
    )

    #expect(
      prepared.surfaceEnvironment[AgentProfileLaunchPlanner.hookForwardCarrierName]
        == record.locator.path(percentEncoded: false)
    )
    #expect(
      prepared.commandEnvironmentTokens.contains(
        "PROWL_AGENT_HOOK_FORWARD_RECORD=\"$PROWL_LAUNCH_HOOK_FORWARD\""
      )
    )
    #expect(!prepared.terminalInput.contains(record.locator.path(percentEncoded: false)))
    #expect(!prepared.surfaceEnvironment.values.contains("/tmp/user-notifier-secret"))
  }

  @Test func attachingDispatchAfterPreflightKeepsOnePreparedHookPlan() throws {
    let base = makePlan(
      invocation: AgentInvocation(executable: "codex", arguments: ["User prompt"]),
      prompt: "User prompt"
    )
    let hooked = base.applyingManagedHook(
      AgentHookPreparedInvocation(
        invocation: AgentInvocation(executable: "codex", arguments: ["-c", "notify=[]", "User prompt"]),
        argumentValues: [1: "notify=[]"]
      ),
      resources: AgentHookResources(bundledCLIPath: "/bundle/prowl", socketPath: "/tmp/prowl.sock"),
      launchCWD: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      token: "token",
      coveredEvents: [.turnEnded]
    )
    let paired = try hooked.attachingDispatch(id: "dispatch-123", userPrompt: "User prompt")

    #expect(paired.hookRegistration == hooked.hookRegistration)
    #expect(paired.surfaceEnvironment[AgentProfileLaunchPlanner.dispatchCarrierName] == "dispatch-123")
    #expect(
      paired.surfaceEnvironment[AgentProfileLaunchPlanner.promptCarrierName]?
        .contains("Prowl dispatch completion protocol v1") == true
    )
    #expect(paired.invocation.arguments.last == paired.surfaceEnvironment[AgentProfileLaunchPlanner.promptCarrierName])
  }

  private func makePlan(
    invocation: AgentInvocation,
    prompt: String? = nil
  ) -> AgentProfileLaunchPlan {
    var environment: [String: String] = [:]
    if let prompt { environment[AgentProfileLaunchPlanner.promptCarrierName] = prompt }
    return AgentProfileLaunchPlan(
      profileID: UUID(),
      profileName: "Test",
      runtime: invocation.executable == "codex" ? .codex : .claude,
      invocation: invocation,
      commandEnvironmentTokens: [],
      placement: .tab,
      splitDirection: .right,
      surfaceEnvironment: environment,
      dedicatedHome: nil
    )
  }
}

/// A workflow `launch` role (docs-ai 063 B3, decision W6): the kickoff prompt replaces the
/// placeholder the frozen plan was compiled with, and `PROWL_WORKFLOW_*` reach only the child
/// through carriers the typed command names — the token is never spelled in the pane.
struct AgentProfileWorkflowCarrierTests {
  @Test func workflowValuesUseChildOnlyCarriersAndReplaceThePromptWithoutTheDispatchProtocol() throws {
    let base = AgentProfileLaunchPlan(
      profileID: UUID(),
      profileName: "Reviewer",
      runtime: .codex,
      invocation: AgentInvocation(executable: "codex", arguments: ["placeholder"]),
      commandEnvironmentTokens: ["CODEX_HOME=/tmp/home"],
      placement: .split,
      splitDirection: .right,
      surfaceEnvironment: [AgentProfileLaunchPlanner.promptCarrierName: "placeholder"],
      dedicatedHome: nil
    )
    let hooked = base.applyingManagedHook(
      AgentHookPreparedInvocation(
        invocation: AgentInvocation(executable: "codex", arguments: ["-c", "notify=[]", "placeholder"]),
        argumentValues: [1: "notify=[]"]
      ),
      resources: AgentHookResources(bundledCLIPath: "/bundle/prowl", socketPath: "/tmp/prowl.sock"),
      launchCWD: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      token: "hook-token",
      coveredEvents: [.turnEnded]
    )
    let prompt = "Review the brief.\n\n---\nProwl workflow completion protocol v1:\nprowl workflow deliver -\n"
    let attached = try hooked.attachingWorkflow(
      prompt: prompt,
      environment: [
        "PROWL_WORKFLOW_TOKEN": "secret-token",
        "PROWL_WORKFLOW_RUN": "run-1",
        "PROWL_WORKFLOW_ROLE": "reviewer",
      ]
    )

    #expect(attached.hookRegistration == hooked.hookRegistration)
    #expect(attached.invocation.arguments.last == prompt)
    #expect(attached.surfaceEnvironment[AgentProfileLaunchPlanner.promptCarrierName] == prompt)
    #expect(attached.surfaceEnvironment[AgentProfileLaunchPlanner.dispatchCarrierName] == nil)
    #expect(!prompt.contains("dispatch completion protocol"))
    let input = attached.terminalInput
    #expect(input.contains("PROWL_WORKFLOW_ROLE=\"$PROWL_LAUNCH_WORKFLOW_0\""))
    #expect(input.contains("PROWL_WORKFLOW_RUN=\"$PROWL_LAUNCH_WORKFLOW_1\""))
    #expect(input.contains("PROWL_WORKFLOW_TOKEN=\"$PROWL_LAUNCH_WORKFLOW_2\""))
    #expect(input.contains("-u PROWL_LAUNCH_WORKFLOW_0"))
    #expect(input.contains("-u PROWL_LAUNCH_WORKFLOW_2"))
    #expect(input.contains("-u PROWL_LAUNCH_HOOK_TOKEN"))
    #expect(input.contains("CODEX_HOME=/tmp/home"))
    #expect(!input.contains("secret-token"))
    #expect(!input.contains("hook-token"))
    #expect(!input.contains("Review the brief"))
    #expect(attached.surfaceEnvironment["PROWL_LAUNCH_WORKFLOW_2"] == "secret-token")
  }

  @Test func attachingWorkflowRequiresAPromptedPlanAndRejectsNUL() {
    let unprompted = AgentProfileLaunchPlan(
      profileID: UUID(), profileName: "Plain", runtime: .claude,
      invocation: AgentInvocation(executable: "claude", arguments: []),
      commandEnvironmentTokens: [], placement: .tab, splitDirection: .right, surfaceEnvironment: [:],
      dedicatedHome: nil)
    #expect(throws: AgentProfileLaunchPlanError.dispatchRequiresPrompt) {
      try unprompted.attachingWorkflow(prompt: "x", environment: [:])
    }
    let prompted = AgentProfileLaunchPlan(
      profileID: UUID(), profileName: "Prompted", runtime: .claude,
      invocation: AgentInvocation(executable: "claude", arguments: ["placeholder"]),
      commandEnvironmentTokens: [], placement: .tab, splitDirection: .right,
      surfaceEnvironment: [AgentProfileLaunchPlanner.promptCarrierName: "placeholder"], dedicatedHome: nil)
    #expect(throws: AgentProfileLaunchPlanError.promptContainsNUL) {
      try prompted.attachingWorkflow(prompt: "a\0b", environment: [:])
    }
    #expect(throws: AgentProfileLaunchPlanError.promptContainsNUL) {
      try prompted.attachingWorkflow(prompt: "ok", environment: ["PROWL_WORKFLOW_TOKEN": "t\0"])
    }
  }
}
