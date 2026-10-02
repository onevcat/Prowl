import Foundation
import Testing

@testable import Prowl

struct AgentRuntimeAdapterTests {
  private struct CatalogExpectation {
    let runtime: AgentProfileRuntime
    let agent: DetectedAgent
    let executable: String
    let arguments: [String]
  }

  private struct IntentExpectation {
    let runtime: AgentProfileRuntime
    let promptedArguments: [String]
    let headlessArguments: [String]
  }

  @Test func profileRuntimeCatalogCoversEveryLaunchableCLI() throws {
    let expected = [
      CatalogExpectation(runtime: .claude, agent: .claude, executable: "claude", arguments: []),
      CatalogExpectation(runtime: .codex, agent: .codex, executable: "codex", arguments: []),
      CatalogExpectation(runtime: .gemini, agent: .gemini, executable: "gemini", arguments: []),
      CatalogExpectation(runtime: .cursor, agent: .cursor, executable: "cursor-agent", arguments: []),
      CatalogExpectation(
        runtime: .cline, agent: .cline, executable: "cline",
        arguments: ["--auto-approve", "false", "--tui"]),
      CatalogExpectation(runtime: .opencode, agent: .opencode, executable: "opencode", arguments: []),
      CatalogExpectation(runtime: .copilot, agent: .copilot, executable: "copilot", arguments: []),
      CatalogExpectation(runtime: .kimi, agent: .kimi, executable: "kimi", arguments: []),
      CatalogExpectation(runtime: .droid, agent: .droid, executable: "droid", arguments: []),
      CatalogExpectation(runtime: .amp, agent: .amp, executable: "amp", arguments: []),
      CatalogExpectation(runtime: .qoder, agent: .qoder, executable: "qodercli", arguments: []),
      CatalogExpectation(runtime: .qwen, agent: .qwen, executable: "qwen", arguments: []),
      CatalogExpectation(
        runtime: .grok, agent: .grok, executable: "grok",
        arguments: ["--permission-mode", "default"]),
      CatalogExpectation(runtime: .pi, agent: .pi, executable: "pi", arguments: []),
      CatalogExpectation(
        runtime: .omp, agent: .omp, executable: "omp",
        arguments: ["--approval-mode", "always-ask"]),
    ]

    #expect(AgentProfileRuntime.allCases.count == expected.count)
    for expectation in expected {
      let invocation = try AgentRuntimeAdapterRegistry.makeStartInvocation(
        AgentStartRequest(runtime: expectation.runtime, intent: .interactive)
      )
      #expect(expectation.runtime.agent == expectation.agent)
      #expect(invocation.executable == expectation.executable)
      #expect(invocation.arguments == expectation.arguments)
    }
    #expect(AgentRuntimeAdapterRegistry.launchableAgents == DetectedAgent.allCases)
  }

  @Test func promptedAndHeadlessStartsUseRuntimeSpecificCLISemantics() throws {
    let expected = [
      IntentExpectation(
        runtime: .claude, promptedArguments: ["Review this."], headlessArguments: ["-p", "Review this."]),
      IntentExpectation(
        runtime: .codex, promptedArguments: ["Review this."], headlessArguments: ["exec", "Review this."]),
      IntentExpectation(
        runtime: .gemini, promptedArguments: ["--prompt-interactive", "Review this."],
        headlessArguments: ["--prompt", "Review this."]),
      IntentExpectation(
        runtime: .cursor, promptedArguments: ["Review this."], headlessArguments: ["--print", "Review this."]),
      IntentExpectation(
        runtime: .cline,
        promptedArguments: ["--auto-approve", "false", "--tui", "Review this."],
        headlessArguments: ["--auto-approve", "false", "Review this."]),
      IntentExpectation(
        runtime: .opencode, promptedArguments: ["--prompt", "Review this."],
        headlessArguments: ["run", "Review this."]),
      IntentExpectation(
        runtime: .copilot, promptedArguments: ["--interactive", "Review this."],
        headlessArguments: ["--prompt", "Review this."]),
      IntentExpectation(
        runtime: .kimi, promptedArguments: ["--prompt", "Review this."],
        headlessArguments: ["--print", "--prompt", "Review this."]),
      IntentExpectation(
        runtime: .droid, promptedArguments: ["Review this."], headlessArguments: ["exec", "Review this."]),
      IntentExpectation(
        runtime: .qoder, promptedArguments: ["--prompt-interactive", "Review this."],
        headlessArguments: ["--print", "Review this."]),
      IntentExpectation(
        runtime: .qwen, promptedArguments: ["--prompt-interactive", "Review this."],
        headlessArguments: ["--prompt", "Review this."]),
      IntentExpectation(
        runtime: .grok,
        promptedArguments: ["--permission-mode", "default", "Review this."],
        headlessArguments: ["--permission-mode", "default", "--single", "Review this."]),
      IntentExpectation(
        runtime: .pi, promptedArguments: ["Review this."], headlessArguments: ["--print", "Review this."]),
      IntentExpectation(
        runtime: .omp,
        promptedArguments: ["--approval-mode", "always-ask", "Review this."],
        headlessArguments: ["--approval-mode", "always-ask", "--print", "Review this."]),
    ]

    for expectation in expected {
      let prompted = try AgentRuntimeAdapterRegistry.makeStartInvocation(
        AgentStartRequest(runtime: expectation.runtime, intent: .prompt("Review this."))
      )
      let headless = try AgentRuntimeAdapterRegistry.makeStartInvocation(
        AgentStartRequest(runtime: expectation.runtime, intent: .headless("Review this."))
      )
      #expect(prompted.arguments == expectation.promptedArguments)
      #expect(headless.arguments == expectation.headlessArguments)
    }

    #expect(
      throws: AgentRuntimeError.unsupportedStartIntent(.amp, .prompt("Review this."))
    ) {
      try AgentRuntimeAdapterRegistry.makeStartInvocation(
        AgentStartRequest(runtime: .amp, intent: .prompt("Review this."))
      )
    }
    let ampHeadless = try AgentRuntimeAdapterRegistry.makeStartInvocation(
      AgentStartRequest(runtime: .amp, intent: .headless("Review this."))
    )
    #expect(ampHeadless.arguments == ["--execute", "Review this."])
  }

  @Test func profileOptionsAreCapabilityGated() throws {
    let noModel: Set<AgentProfileRuntime> = [.droid, .amp]
    let noReasoning: Set<AgentProfileRuntime> = [.gemini, .cursor, .kimi, .droid]
    let executionModeSelection: Set<AgentProfileRuntime> = [
      .claude, .codex, .gemini, .cursor, .cline, .opencode, .copilot, .kimi, .qoder, .qwen, .grok,
      .omp,
    ]
    let isolated: Set<AgentProfileRuntime> = [
      .claude, .codex, .gemini, .cline, .copilot, .qoder, .qwen, .pi, .omp,
    ]

    for runtime in AgentProfileRuntime.allCases {
      let adapter = try #require(AgentRuntimeAdapterRegistry.profileAdapter(for: runtime))
      #expect(adapter.supportsModelSelection == !noModel.contains(runtime))
      #expect(adapter.supportsReasoningEffort == !noReasoning.contains(runtime))
      #expect(
        adapter.executionModeOptions
          == (executionModeSelection.contains(runtime) ? [.standard, .unrestricted] : [])
      )
      #expect(adapter.supportsAccountIsolation == isolated.contains(runtime))
    }
  }

  @Test func expandedRuntimeOptionsRenderOnlyVerifiedFields() throws {
    let configuration = AgentLaunchConfiguration(
      model: "model-x",
      executionMode: .unrestricted,
      reasoningEffort: "high"
    )
    let expected: [(AgentProfileRuntime, [String])] = [
      (.gemini, ["--model", "model-x", "--approval-mode", "yolo", "--sandbox=false"]),
      (.cursor, ["--model", "model-x", "--yolo", "--sandbox", "disabled"]),
      (.cline, ["--model", "model-x", "--thinking", "high", "--auto-approve", "true", "--tui"]),
      (.opencode, ["--model", "model-x", "--variant", "high", "--auto"]),
      (.copilot, ["--model", "model-x", "--reasoning-effort", "high", "--allow-all"]),
      (.kimi, ["--model", "model-x", "--yolo"]),
      (.droid, []),
      (.amp, ["--effort", "high"]),
      (.qoder, ["--model", "model-x", "--reasoning-effort", "high", "--dangerously-skip-permissions"]),
      (.qwen, ["--model", "model-x", "--reasoning-effort", "high", "--approval-mode", "yolo", "--sandbox=false"]),
      (
        .grok,
        [
          "--model", "model-x", "--reasoning-effort", "high", "--permission-mode", "bypassPermissions",
          "--sandbox", "off",
        ]
      ),
      (.pi, ["--model", "model-x", "--thinking", "high"]),
      (.omp, ["--model", "model-x", "--thinking", "high", "--approval-mode", "yolo"]),
    ]

    for (runtime, arguments) in expected {
      let invocation = try AgentRuntimeAdapterRegistry.makeStartInvocation(
        AgentStartRequest(runtime: runtime, intent: .interactive, configuration: configuration)
      )
      #expect(invocation.arguments == arguments)
    }
  }

  @Test func guardedModesOverrideUnsafeRuntimeDefaults() throws {
    let expected: [(AgentProfileRuntime, [String])] = [
      (.cline, ["--auto-approve", "false", "--tui"]),
      (.grok, ["--permission-mode", "default"]),
      (.omp, ["--approval-mode", "always-ask"]),
    ]

    for (runtime, arguments) in expected {
      let invocation = try AgentRuntimeAdapterRegistry.makeStartInvocation(
        AgentStartRequest(runtime: runtime, intent: .interactive)
      )
      #expect(invocation.arguments == arguments)
    }
  }

  @Test func launchObservationUsesTheLastOccurrenceOfAnOption() {
    let cline = AgentRuntimeAdapterRegistry.observe(
      runtime: .cline,
      arguments: ["cline", "--auto-approve", "false", "--auto-approve", "true"]
    )
    #expect(cline.executionMode == .unrestricted)

    let omp = AgentRuntimeAdapterRegistry.observe(
      runtime: .omp,
      arguments: ["omp", "--approval-mode", "always-ask", "--approval-mode=yolo"]
    )
    #expect(omp.executionMode == .unrestricted)
  }

  @Test func codexStartBuildsUnrestrictedInvocation() throws {
    let invocation = try AgentRuntimeAdapterRegistry.makeStartInvocation(
      AgentStartRequest(
        agent: .codex,
        intent: .prompt("Continue the handoff."),
        configuration: AgentLaunchConfiguration(model: "gpt-5.4", executionMode: .unrestricted)
      )
    )

    #expect(invocation.executable == "codex")
    #expect(
      invocation.arguments
        == ["--model", "gpt-5.4", "--dangerously-bypass-approvals-and-sandbox", "Continue the handoff."]
    )
  }

  @Test func interactiveStartRendersNoPromptArgument() throws {
    let codex = try AgentRuntimeAdapterRegistry.makeStartInvocation(
      AgentStartRequest(agent: .codex, intent: .interactive)
    )
    #expect(codex.executable == "codex")
    #expect(codex.arguments.isEmpty)

    let claude = try AgentRuntimeAdapterRegistry.makeStartInvocation(
      AgentStartRequest(
        agent: .claude,
        intent: .interactive,
        configuration: AgentLaunchConfiguration(model: "claude-opus-5")
      )
    )
    #expect(claude.executable == "claude")
    #expect(claude.arguments == ["--model", "claude-opus-5"])
  }

  @Test func headlessStartRendersOneShotExecutionMode() throws {
    let codex = try AgentRuntimeAdapterRegistry.makeStartInvocation(
      AgentStartRequest(agent: .codex, intent: .headless("Summarize the repo."))
    )
    #expect(codex.arguments == ["exec", "Summarize the repo."])

    let claude = try AgentRuntimeAdapterRegistry.makeStartInvocation(
      AgentStartRequest(agent: .claude, intent: .headless("Summarize the repo."))
    )
    #expect(claude.arguments == ["-p", "Summarize the repo."])
  }

  @Test func reasoningEffortMapsToRuntimeSpecificOptions() throws {
    let claude = try AgentRuntimeAdapterRegistry.makeStartInvocation(
      AgentStartRequest(
        agent: .claude,
        intent: .interactive,
        configuration: AgentLaunchConfiguration(reasoningEffort: "high")
      )
    )
    #expect(claude.arguments == ["--effort", "high"])

    let codex = try AgentRuntimeAdapterRegistry.makeStartInvocation(
      AgentStartRequest(
        agent: .codex,
        intent: .interactive,
        configuration: AgentLaunchConfiguration(reasoningEffort: "xhigh")
      )
    )
    #expect(codex.arguments == ["-c", "model_reasoning_effort=xhigh"])
  }

  @Test func extraArgumentsAppendAfterAdapterOptionsBeforePrompt() throws {
    let invocation = try AgentRuntimeAdapterRegistry.makeStartInvocation(
      AgentStartRequest(
        agent: .codex,
        intent: .prompt("Go."),
        configuration: AgentLaunchConfiguration(
          model: "gpt-5.4",
          extraArguments: ["--search", "--cd", "/tmp/with space"]
        )
      )
    )
    #expect(
      invocation.arguments == ["--model", "gpt-5.4", "--search", "--cd", "/tmp/with space", "Go."]
    )
  }

  @Test func accountIsolationCapabilityIsDeclaredPerAdapter() {
    let codex = AgentRuntimeAdapterRegistry.adapter(for: .codex)
    #expect(codex?.supportsAccountIsolation == true)
    #expect(codex?.accountHomeEnvironmentVariable == "CODEX_HOME")

    let claude = AgentRuntimeAdapterRegistry.adapter(for: .claude)
    #expect(claude?.supportsAccountIsolation == true)
    #expect(claude?.accountHomeEnvironmentVariable == "CLAUDE_CONFIG_DIR")
    #expect(claude?.reasoningEffortSuggestions.contains("high") == true)
  }

  @Test func runtimeSuggestionsMatchCurrentCapabilities() {
    let codex = AgentRuntimeAdapterRegistry.adapter(for: .codex)
    #expect(
      codex?.modelSuggestions
        == ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
    )
    #expect(codex?.reasoningEffortSuggestions == ["low", "medium", "high", "xhigh", "max"])

    let claude = AgentRuntimeAdapterRegistry.adapter(for: .claude)
    #expect(
      claude?.modelSuggestions == [
        "claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5", "claude-haiku-4-5-20251001",
        "claude-fable-5", "claude-opus-5",
      ]
    )
    #expect(claude?.reasoningEffortSuggestions == ["low", "medium", "high", "xhigh", "max"])
  }

  @Test func launchConfigurationDecodesLegacyPayloadWithoutNewFields() throws {
    let legacy = Data(#"{"model":"gpt-5.4","executionMode":"standard"}"#.utf8)
    let configuration = try JSONDecoder().decode(AgentLaunchConfiguration.self, from: legacy)
    #expect(configuration.model == "gpt-5.4")
    #expect(configuration.reasoningEffort == nil)
    #expect(configuration.extraArguments.isEmpty)
  }

  @Test func observedLaunchOnlyClaimsExplicitUnrestrictedMode() {
    let codex = AgentRuntimeAdapterRegistry.observe(
      agent: .codex,
      arguments: ["codex", "--model", "gpt-5.4", "--dangerously-bypass-approvals-and-sandbox"]
    )
    #expect(codex.model == "gpt-5.4")
    #expect(codex.executionMode == .unrestricted)

    let yolo = AgentRuntimeAdapterRegistry.observe(agent: .codex, arguments: ["codex", "--yolo"])
    #expect(yolo.executionMode == .unrestricted)

    let claude = AgentRuntimeAdapterRegistry.observe(
      agent: .claude,
      arguments: ["claude", "--allow-dangerously-skip-permissions"]
    )
    #expect(claude.executionMode == nil)
  }

  @Test func inheritedConfigurationCarriesOnlyPortableSourceIntent() {
    let observation = AgentLaunchObservation(model: "gpt-5.4", executionMode: .unrestricted)

    let claude = AgentRuntimeAdapterRegistry.inheritedConfiguration(
      from: .codex,
      observation: observation,
      to: .claude
    )
    #expect(claude.model == nil)
    #expect(claude.executionMode == .unrestricted)

    let codex = AgentRuntimeAdapterRegistry.inheritedConfiguration(
      from: .codex,
      observation: observation,
      to: .codex
    )
    #expect(codex.model == "gpt-5.4")
    #expect(codex.executionMode == .unrestricted)
  }

  @Test func terminalInputQuotesEveryArgument() {
    let invocation = AgentInvocation(
      executable: "codex",
      arguments: ["exec", "resume", "session id", "Write 'current.md'\nwithout shell injection."]
    )

    #expect(
      invocation.terminalInput
        == "'codex' 'exec' 'resume' 'session id' 'Write '\"'\"'current.md'\"'\"'\nwithout shell injection.'"
    )
  }

}
