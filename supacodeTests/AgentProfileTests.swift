import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct AgentProfileTests {
  private struct HomeRelocationExpectation {
    let runtime: AgentProfileRuntime
    let environmentName: String?
    let relativeArguments: [String]
    let sessionRootComponent: String
  }

  private func profile(
    id: UUID = UUID(),
    name: String = "Codex · Work",
    isEnabled: Bool = true,
    runtime: AgentProfileRuntime = .codex
  ) -> AgentProfile {
    AgentProfile(id: id, name: name, isEnabled: isEnabled, runtime: runtime)
  }

  // MARK: - Normalization

  @Test func normalizationDropsBlankNamesAndDuplicateIDs() {
    let id = UUID()
    let profiles = [
      profile(id: id, name: "  Codex · Work  "),
      profile(id: id, name: "Duplicate of first"),
      profile(name: "   "),
      profile(name: "Claude · Review", runtime: .claude),
    ]

    let normalized = AgentProfile.normalizedProfiles(profiles)

    #expect(normalized.count == 2)
    #expect(normalized[0].id == id)
    #expect(normalized[0].name == "Codex · Work")
    #expect(normalized[1].name == "Claude · Review")
  }

  @Test func decodeFillsDefaultsForMissingFields() throws {
    let id = UUID()
    let legacy = Data(#"{"id":"\#(id.uuidString)","name":"Codex","runtime":"codex"}"#.utf8)

    let decoded = try JSONDecoder().decode(AgentProfile.self, from: legacy)

    #expect(decoded.id == id)
    #expect(decoded.isEnabled)
    #expect(decoded.model == nil)
    #expect(decoded.reasoningEffort == nil)
    #expect(decoded.icon == nil)
    #expect(decoded.executionMode == .standard)
    #expect(decoded.placement == .tab)
    #expect(decoded.splitDirection == .right)
    #expect(decoded.extraArguments.isEmpty)
    #expect(decoded.environmentOverrides.isEmpty)
    #expect(!decoded.bindsDedicatedHome)
  }

  @Test func encodingRoundTripPreservesEnvironmentOverrides() throws {
    var profile = profile(name: "Codex · DeepSeek")
    profile.environmentOverrides = [
      AgentProfileEnvironmentOverride(name: "OPENAI_BASE_URL", value: "https://api.deepseek.com/v1")
    ]

    let decoded = try JSONDecoder().decode(AgentProfile.self, from: JSONEncoder().encode(profile))

    #expect(decoded.environmentOverrides == profile.environmentOverrides)
  }

  @Test func encodingRoundTripPreservesProfileIcon() throws {
    let profile = AgentProfile(name: "Codex · Work", runtime: .codex, icon: "wand.and.stars")

    let decoded = try JSONDecoder().decode(AgentProfile.self, from: JSONEncoder().encode(profile))

    #expect(decoded.icon == "wand.and.stars")
  }

  @Test func profileIconUsesCustomSymbolThenRuntimeBrandFallback() throws {
    let custom = AgentProfile(name: "Codex · Work", runtime: .codex, icon: "wand.and.stars")
    #expect(
      AgentProfileIconResolver.source(for: custom.iconSource)
        == TabIconSource(systemSymbol: "wand.and.stars")
    )

    let fallback = AgentProfile(name: "Claude Code", runtime: .claude)
    let expected = try #require(CommandIconMap.iconForFirstToken(fallback.runtime.agent.iconLookupToken))
    #expect(AgentProfileIconResolver.source(for: fallback.iconSource) == expected)

    let omp = AgentProfile(name: "Oh My Pi", runtime: .omp)
    let ompExpected = try #require(CommandIconMap.iconForFirstToken("omp"))
    #expect(AgentProfileIconResolver.source(for: omp.iconSource) == ompExpected)
  }

  @Test func everyRuntimeRoundTripsWithIndependentPiAndOMPAgents() throws {
    for runtime in AgentProfileRuntime.allCases {
      let encoded = try JSONEncoder().encode(AgentProfile(name: runtime.rawValue, runtime: runtime))
      let decoded = try JSONDecoder().decode(AgentProfile.self, from: encoded)
      #expect(decoded.runtime == runtime)
    }
    #expect(AgentProfileRuntime.pi.agent == .pi)
    #expect(AgentProfileRuntime.omp.agent == .omp)
  }

  // MARK: - Recommendation

  @Test func recommendationPrefersDesignationOverMemoryAndOrder() {
    let designated = profile(name: "Designated")
    let remembered = profile(name: "Remembered")
    let first = profile(name: "First")
    let profiles = [first, remembered, designated]

    let recommended = AgentProfileRecommendation.recommendedProfile(
      profiles: profiles,
      designatedID: designated.id,
      lastLaunchedID: remembered.id
    )

    #expect(recommended?.id == designated.id)
  }

  @Test func recommendationFallsThroughDisabledDesignationToMemory() {
    let designated = profile(name: "Designated", isEnabled: false)
    let remembered = profile(name: "Remembered")
    let profiles = [profile(name: "First"), remembered, designated]

    let recommended = AgentProfileRecommendation.recommendedProfile(
      profiles: profiles,
      designatedID: designated.id,
      lastLaunchedID: remembered.id
    )

    #expect(recommended?.id == remembered.id)
  }

  @Test func recommendationFallsThroughDanglingMemoryToFirstEnabled() {
    let disabledFirst = profile(name: "Disabled", isEnabled: false)
    let enabled = profile(name: "Enabled")
    let profiles = [disabledFirst, enabled]

    let recommended = AgentProfileRecommendation.recommendedProfile(
      profiles: profiles,
      designatedID: nil,
      lastLaunchedID: UUID()
    )

    #expect(recommended?.id == enabled.id)
  }

  @Test func recommendationIsNilWhenNothingIsEnabled() {
    let profiles = [profile(name: "Disabled", isEnabled: false)]

    let recommended = AgentProfileRecommendation.recommendedProfile(
      profiles: profiles,
      designatedID: nil,
      lastLaunchedID: nil
    )

    #expect(recommended == nil)
  }

  // MARK: - Shell word splitting

  @Test func splitterHandlesQuotesAndEscapes() {
    #expect(ShellWordSplitter.split("") == [])
    #expect(ShellWordSplitter.split("   ") == [])
    #expect(ShellWordSplitter.split("--yolo --search") == ["--yolo", "--search"])
    #expect(ShellWordSplitter.split("--cd '/tmp/with space'") == ["--cd", "/tmp/with space"])
    #expect(ShellWordSplitter.split(#"--note "double \" quote""#) == ["--note", #"double " quote"#])
    #expect(ShellWordSplitter.split(#"a\ b"#) == ["a b"])
    #expect(ShellWordSplitter.split("''") == [""])
    #expect(ShellWordSplitter.split("--flag=value") == ["--flag=value"])
  }

  @Test func splitterConsumesUnterminatedQuoteAsLiteralTail() {
    #expect(ShellWordSplitter.split("--note 'unterminated tail") == ["--note", "unterminated tail"])
  }

  // MARK: - Launch plan

  @Test func environmentAndArgumentRelocationsCompileToManagedHomes() throws {
    let base = URL(fileURLWithPath: "/base/agent-profiles", isDirectory: true)
    let expected = [
      HomeRelocationExpectation(
        runtime: .claude, environmentName: "CLAUDE_CONFIG_DIR", relativeArguments: [], sessionRootComponent: ""),
      HomeRelocationExpectation(
        runtime: .codex, environmentName: "CODEX_HOME", relativeArguments: [], sessionRootComponent: ""),
      HomeRelocationExpectation(
        runtime: .gemini, environmentName: "GEMINI_CLI_HOME", relativeArguments: [], sessionRootComponent: ".gemini"),
      HomeRelocationExpectation(
        runtime: .cline, environmentName: nil,
        relativeArguments: ["--config", "config", "--data-dir", "data", "--hooks-dir", "hooks"],
        sessionRootComponent: "data"),
      HomeRelocationExpectation(
        runtime: .copilot, environmentName: "COPILOT_HOME", relativeArguments: [], sessionRootComponent: ""),
      HomeRelocationExpectation(
        runtime: .qoder, environmentName: nil, relativeArguments: ["--config-dir", ""], sessionRootComponent: ""),
      HomeRelocationExpectation(
        runtime: .qwen, environmentName: "QWEN_HOME", relativeArguments: [], sessionRootComponent: ""),
      HomeRelocationExpectation(
        runtime: .pi, environmentName: "PI_CODING_AGENT_DIR", relativeArguments: [], sessionRootComponent: ""),
      HomeRelocationExpectation(
        runtime: .omp, environmentName: "PI_CODING_AGENT_DIR", relativeArguments: [], sessionRootComponent: ""),
    ]

    for expectation in expected {
      var bound = AgentProfile(
        name: expectation.runtime.rawValue,
        runtime: expectation.runtime,
        bindsDedicatedHome: true
      )
      bound.extraArguments = "--config-dir /tmp/ignored"
      let plan = try AgentProfileLaunchPlanner.plan(for: bound, homeBaseDirectory: base)
      let home = try #require(plan.dedicatedHome)
      let sessionRoot = try #require(plan.sessionConfigRoot)

      if let environmentName = expectation.environmentName {
        #expect(
          plan.commandEnvironmentTokens.first
            == "\(environmentName)=\(AgentInvocation.shellQuote(AgentProfileLaunchPlanner.pathString(home)))"
        )
      } else {
        #expect(plan.commandEnvironmentTokens.isEmpty)
      }
      let expectedRoot =
        expectation.sessionRootComponent.isEmpty
        ? home
        : home.appending(path: expectation.sessionRootComponent)
      #expect(
        AgentProfileLaunchPlanner.pathString(sessionRoot)
          == AgentProfileLaunchPlanner.pathString(expectedRoot)
      )

      if !expectation.relativeArguments.isEmpty {
        let managedArguments = expectation.relativeArguments.map { component in
          component.hasPrefix("--") || component.isEmpty
            ? component
            : AgentProfileLaunchPlanner.pathString(home.appending(path: component))
        }
        let suffix = managedArguments.map { $0.isEmpty ? AgentProfileLaunchPlanner.pathString(home) : $0 }
        let tuiCount = expectation.runtime == .cline ? 1 : 0
        let invocationSuffix = Array(plan.invocation.arguments.dropLast(tuiCount).suffix(suffix.count))
        #expect(invocationSuffix == suffix)
      }
    }
  }

  @Test func unsupportedDedicatedHomesAreRejectedWithoutAFalseIsolationClaim() {
    let unsupported: [AgentProfileRuntime] = [.cursor, .opencode, .kimi, .droid, .amp, .grok]

    for runtime in unsupported {
      let bound = AgentProfile(name: runtime.rawValue, runtime: runtime, bindsDedicatedHome: true)
      #expect(throws: AgentProfileLaunchPlanError.accountIsolationUnsupported(runtime)) {
        try AgentProfileLaunchPlanner.plan(
          for: bound,
          homeBaseDirectory: URL(fileURLWithPath: "/base", isDirectory: true)
        )
      }
    }
  }

  @Test func purePresetPlanHasNoEnvironmentAndSplitsExtraArguments() throws {
    var preset = profile(name: "Codex · Deep")
    preset.model = "gpt-5.4"
    preset.reasoningEffort = "xhigh"
    preset.extraArguments = "--search --cd '/tmp/with space'"

    let plan = try AgentProfileLaunchPlanner.plan(
      for: preset,
      homeBaseDirectory: URL(fileURLWithPath: "/base", isDirectory: true)
    )

    #expect(plan.surfaceEnvironment.isEmpty)
    #expect(plan.commandEnvironmentTokens.isEmpty)
    #expect(plan.dedicatedHome == nil)
    #expect(plan.invocation.executable == "codex")
    #expect(
      plan.invocation.arguments == [
        "--model", "gpt-5.4",
        "-c", "model_reasoning_effort=xhigh",
        "--search", "--cd", "/tmp/with space",
      ]
    )
    #expect(plan.previewText == plan.invocation.terminalInput)
  }

  @Test func plannerCarriesPromptOutsideTheInitialPTYInput() throws {
    var preset = profile(name: "Codex · Reviewer")
    preset.model = "gpt-5.4"
    let prompt = String(repeating: "Review the current diff carefully. ", count: 80) + "\tReport findings."

    let plan = try AgentProfileLaunchPlanner.plan(
      for: preset,
      intent: .prompt(prompt),
      homeBaseDirectory: URL(fileURLWithPath: "/base", isDirectory: true)
    )

    #expect(plan.invocation.executable == "codex")
    #expect(plan.invocation.arguments == ["--model", "gpt-5.4", prompt])
    #expect(plan.surfaceEnvironment[AgentProfileLaunchPlanner.promptCarrierName] == prompt)
    #expect(!plan.terminalInput.contains(prompt))
    #expect(plan.terminalInput.hasPrefix("env -u \(AgentProfileLaunchPlanner.promptCarrierName) "))
    #expect(plan.terminalInput.contains("\"$\(AgentProfileLaunchPlanner.promptCarrierName)\""))
    #expect(!plan.terminalInput.contains(";"))
    #expect(!plan.terminalInput.contains("unset "))
    #expect(!plan.terminalInput.contains("\(AgentProfileLaunchPlanner.promptCarrierName)="))
    #expect(plan.terminalInput.utf8.count < 1_024)
  }

  @Test func dispatchPromptAddsVersionedProtocolAndChildOnlyContext() throws {
    let dispatchID = "dispatch-secret-id"
    let plan = try AgentProfileLaunchPlanner.plan(
      for: profile(name: "Codex · Reviewer"),
      intent: .prompt("Review the current diff."),
      homeBaseDirectory: URL(fileURLWithPath: "/base", isDirectory: true),
      dispatchID: dispatchID
    )

    let effectivePrompt = try #require(
      plan.surfaceEnvironment[AgentProfileLaunchPlanner.promptCarrierName]
    )
    #expect(effectivePrompt.hasPrefix("Review the current diff."))
    #expect(effectivePrompt.contains("Prowl dispatch completion protocol v1"))
    #expect(effectivePrompt.contains("prowl agents dispatch-complete"))
    #expect(effectivePrompt.contains("--outcome succeeded|failed"))
    #expect(effectivePrompt.contains("single line"))
    #expect(effectivePrompt.contains("no control characters"))
    #expect(!effectivePrompt.contains(dispatchID))
    #expect(
      plan.surfaceEnvironment[AgentProfileLaunchPlanner.dispatchCarrierName] == dispatchID
    )
    #expect(plan.surfaceEnvironment[DispatchCompleteInput.environmentKey] == nil)
    #expect(
      plan.commandEnvironmentTokens.contains(
        "\(DispatchCompleteInput.environmentKey)=\"$\(AgentProfileLaunchPlanner.dispatchCarrierName)\""
      )
    )
    #expect(plan.terminalInput.contains("-u \(AgentProfileLaunchPlanner.dispatchCarrierName)"))
    #expect(!plan.terminalInput.contains(dispatchID))
  }

  @Test func interactiveLaunchNeverInheritsDispatchContext() throws {
    let plan = try AgentProfileLaunchPlanner.plan(
      for: profile(name: "Codex"),
      homeBaseDirectory: URL(fileURLWithPath: "/base", isDirectory: true)
    )

    #expect(plan.surfaceEnvironment[AgentProfileLaunchPlanner.dispatchCarrierName] == nil)
    #expect(!plan.terminalInput.contains(DispatchCompleteInput.environmentKey))
  }

  @Test func promptedTerminalInputRunsThroughSupportedInteractiveShellSyntax() throws {
    let prompt = "Review the current diff."
    let carrier = AgentProfileLaunchPlanner.promptCarrierName
    let childCheck = "[[ \"$1\" == \"\(prompt)\" && -z ${\(carrier)+x} ]]"
    let plan = AgentProfileLaunchPlan(
      profileID: UUID(),
      profileName: "Reviewer",
      runtime: .claude,
      invocation: AgentInvocation(
        executable: "/bin/zsh",
        arguments: ["-f", "-c", childCheck, "prowl-child", prompt]
      ),
      commandEnvironmentTokens: [],
      placement: .tab,
      splitDirection: .right,
      surfaceEnvironment: [carrier: prompt],
      dedicatedHome: nil
    )
    let shellCandidates = [
      "/bin/zsh",
      "/bin/bash",
      "/opt/homebrew/bin/fish",
      "/usr/local/bin/fish",
    ]
    let shells = shellCandidates.filter(FileManager.default.isExecutableFile(atPath:))

    for shell in shells {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: shell)
      process.arguments = ["-c", plan.terminalInput]
      var environment = ProcessInfo.processInfo.environment
      environment[carrier] = prompt
      process.environment = environment

      try process.run()
      process.waitUntilExit()

      #expect(process.terminationStatus == 0, "Prompt launch syntax failed in \(shell)")
    }
  }

  @Test func plannerRejectsPromptThatCannotRideInTheSurfaceEnvironment() {
    #expect(throws: AgentProfileLaunchPlanError.promptContainsNUL) {
      try AgentProfileLaunchPlanner.plan(
        for: profile(name: "Codex"),
        intent: .prompt("Review\0this"),
        homeBaseDirectory: URL(fileURLWithPath: "/base", isDirectory: true)
      )
    }
  }

  @Test func plannerKeepsInteractiveAsTheDefaultIntent() throws {
    let plan = try AgentProfileLaunchPlanner.plan(
      for: profile(name: "Codex"),
      homeBaseDirectory: URL(fileURLWithPath: "/base", isDirectory: true)
    )

    #expect(plan.invocation.arguments.isEmpty)
  }

  @Test func plannerPreservesAmpPromptRejection() {
    #expect(throws: AgentRuntimeError.unsupportedStartIntent(.amp, .prompt("Review."))) {
      try AgentProfileLaunchPlanner.plan(
        for: profile(name: "Amp", runtime: .amp),
        intent: .prompt("Review."),
        homeBaseDirectory: URL(fileURLWithPath: "/base", isDirectory: true)
      )
    }
  }

  @Test func boundProfilePlanDerivesHomeFromUUIDInsideBase() throws {
    var bound = profile(name: "Codex · Work")
    bound.bindsDedicatedHome = true
    let base = URL(fileURLWithPath: "/base/agent-profiles", isDirectory: true)

    let plan = try AgentProfileLaunchPlanner.plan(for: bound, homeBaseDirectory: base)

    let home = try #require(plan.dedicatedHome)
    #expect(
      AgentProfileLaunchPlanner.pathString(home) == "/base/agent-profiles/\(bound.id.uuidString)"
    )
    // The home rides the launch command, not the pane's shell environment: a
    // manual launch after the agent exits uses the default account.
    #expect(
      plan.commandEnvironmentTokens == ["CODEX_HOME='/base/agent-profiles/\(bound.id.uuidString)'"]
    )
    #expect(plan.surfaceEnvironment.isEmpty)
    #expect(plan.previewText.hasPrefix("env CODEX_HOME='/base/agent-profiles/"))
    #expect(AgentProfileLaunchPlanner.isContained(home, in: base))
  }

  @Test func boundClaudeProfileUsesConfigDirVariable() throws {
    var bound = profile(name: "Claude · Personal", runtime: .claude)
    bound.bindsDedicatedHome = true

    let plan = try AgentProfileLaunchPlanner.plan(
      for: bound,
      homeBaseDirectory: URL(fileURLWithPath: "/base", isDirectory: true)
    )

    #expect(plan.commandEnvironmentTokens.first?.hasPrefix("CLAUDE_CONFIG_DIR=") == true)
  }

  // MARK: - Environment overrides

  @Test func planAppliesOverridesWithTrimmedNamesAndLastDuplicateWins() throws {
    var preset = profile(name: "Codex · DeepSeek")
    preset.environmentOverrides = [
      AgentProfileEnvironmentOverride(name: "  OPENAI_BASE_URL ", value: "https://api.deepseek.com/v1"),
      AgentProfileEnvironmentOverride(name: "OPENAI_BASE_URL", value: "https://api.deepseek.com/beta"),
      AgentProfileEnvironmentOverride(name: "EMPTY_VALUE", value: ""),
    ]

    let plan = try AgentProfileLaunchPlanner.plan(
      for: preset,
      homeBaseDirectory: URL(fileURLWithPath: "/base", isDirectory: true)
    )

    // Values ride in namespaced carriers; the command only references them.
    #expect(
      plan.surfaceEnvironment == [
        "PROWL_ENV_OPENAI_BASE_URL": "https://api.deepseek.com/beta",
        "PROWL_ENV_EMPTY_VALUE": "",
      ]
    )
    #expect(
      plan.commandEnvironmentTokens == [
        "EMPTY_VALUE=\"$PROWL_ENV_EMPTY_VALUE\"",
        "OPENAI_BASE_URL=\"$PROWL_ENV_OPENAI_BASE_URL\"",
      ]
    )
    #expect(plan.terminalInput.hasPrefix("env EMPTY_VALUE="))
  }

  @Test func planDropsInvalidReservedAndInProgressOverrideRows() throws {
    var preset = profile(name: "Codex · Broken rows")
    preset.environmentOverrides = [
      AgentProfileEnvironmentOverride(name: "   ", value: "in-progress row"),
      AgentProfileEnvironmentOverride(name: "9LEADING_DIGIT", value: "x"),
      AgentProfileEnvironmentOverride(name: "BAD-NAME", value: "x"),
      AgentProfileEnvironmentOverride(name: "PROWL_WORKTREE_PATH", value: "/forged"),
      AgentProfileEnvironmentOverride(name: "CODEX_HOME", value: "/elsewhere"),
      AgentProfileEnvironmentOverride(name: "CLAUDE_CONFIG_DIR", value: "/elsewhere"),
      AgentProfileEnvironmentOverride(name: "HOME", value: "/relocated"),
      AgentProfileEnvironmentOverride(name: "NUL_VALUE", value: "trunc\0ated"),
    ]

    let plan = try AgentProfileLaunchPlanner.plan(
      for: preset,
      homeBaseDirectory: URL(fileURLWithPath: "/base", isDirectory: true)
    )

    #expect(plan.surfaceEnvironment.isEmpty)
    #expect(plan.commandEnvironmentTokens.isEmpty)
  }

  @Test func dedicatedHomeBindingBeatsSameNamedUserOverride() throws {
    var bound = profile(name: "Codex · Work")
    bound.bindsDedicatedHome = true
    bound.environmentOverrides = [
      AgentProfileEnvironmentOverride(name: "CODEX_HOME", value: "/attacker/home")
    ]
    let base = URL(fileURLWithPath: "/base/agent-profiles", isDirectory: true)

    let plan = try AgentProfileLaunchPlanner.plan(for: bound, homeBaseDirectory: base)

    // The reserved-name policy drops the user row, so the launch command
    // carries exactly one CODEX_HOME assignment — the derived home.
    #expect(
      plan.commandEnvironmentTokens == ["CODEX_HOME='/base/agent-profiles/\(bound.id.uuidString)'"]
    )
    #expect(plan.surfaceEnvironment.isEmpty)
  }

  @Test func commandAndPreviewCarryReferencesButNeverOverrideValues() throws {
    var preset = profile(name: "Codex · DeepSeek")
    preset.environmentOverrides = [
      AgentProfileEnvironmentOverride(name: "OPENAI_BASE_URL", value: "https://a.example/v1 beta"),
      AgentProfileEnvironmentOverride(name: "OPENAI_API_KEY", value: "sk-secret-123"),
    ]

    let plan = try AgentProfileLaunchPlanner.plan(
      for: preset,
      homeBaseDirectory: URL(fileURLWithPath: "/base", isDirectory: true)
    )

    // The typed command (== preview) references the carriers; the values ride
    // the spawn environment only — never shell history or scrollback.
    #expect(plan.previewText == plan.terminalInput)
    #expect(plan.previewText.contains("OPENAI_API_KEY=\"$PROWL_ENV_OPENAI_API_KEY\""))
    #expect(plan.previewText.contains("OPENAI_BASE_URL=\"$PROWL_ENV_OPENAI_BASE_URL\""))
    #expect(!plan.previewText.contains("sk-secret-123"))
    #expect(!plan.previewText.contains("a.example"))
    #expect(plan.surfaceEnvironment["PROWL_ENV_OPENAI_API_KEY"] == "sk-secret-123")
  }

  @Test func environmentPolicyReportsRowIssuesForEditorDiagnostics() {
    #expect(
      AgentProfileEnvironmentPolicy.issue(
        for: AgentProfileEnvironmentOverride(name: "OPENAI_BASE_URL", value: "x")
      ) == nil
    )
    #expect(
      AgentProfileEnvironmentPolicy.issue(
        for: AgentProfileEnvironmentOverride(name: "", value: "typing…")
      ) == nil
    )
    #expect(
      AgentProfileEnvironmentPolicy.issue(
        for: AgentProfileEnvironmentOverride(name: "BAD NAME", value: "x")
      ) == .invalidName
    )
    #expect(
      AgentProfileEnvironmentPolicy.issue(
        for: AgentProfileEnvironmentOverride(name: "PROWL_ROOT_PATH", value: "x")
      ) == .reservedName
    )
    #expect(
      AgentProfileEnvironmentPolicy.issue(
        for: AgentProfileEnvironmentOverride(name: "CLAUDE_CONFIG_DIR", value: "x")
      ) == .reservedName
    )
    // Relocating `HOME` would move every runtime's default home past the
    // dedicated-home safeguards, so it is reserved alongside the account-home
    // variables (docs-ai 053/005).
    #expect(
      AgentProfileEnvironmentPolicy.issue(
        for: AgentProfileEnvironmentOverride(name: "HOME", value: "/relocated")
      ) == .reservedName
    )
    #expect(
      AgentProfileEnvironmentPolicy.issue(
        for: AgentProfileEnvironmentOverride(name: "OK", value: "bad\0value")
      ) == .invalidValue
    )
  }

  @Test func launchWarningPrefersTheProbeAnswerOverTheHomeHeuristic() {
    let codex = profile(name: "Codex")

    // Probe answered: ground truth in both directions, home is irrelevant.
    #expect(
      AgentProfileAvailability.launchWarning(
        for: codex, probedAvailable: true, isRuntimeInstalled: { _ in false }
      ) == nil
    )
    #expect(
      AgentProfileAvailability.launchWarning(
        for: codex, probedAvailable: false, isRuntimeInstalled: { _ in true }
      ) == "Codex is not on your shell's PATH"
    )

    // Probe unanswered: the home-directory heuristic fills in.
    #expect(
      AgentProfileAvailability.launchWarning(
        for: codex, probedAvailable: nil, isRuntimeInstalled: { _ in true }
      ) == nil
    )
    #expect(
      AgentProfileAvailability.launchWarning(
        for: codex, probedAvailable: nil, isRuntimeInstalled: { _ in false }
      ) == "Codex may not be installed"
    )
  }

  @Test func containmentRejectsBaseItselfAndOutsidePaths() {
    let base = URL(fileURLWithPath: "/base/agent-profiles", isDirectory: true)
    #expect(!AgentProfileLaunchPlanner.isContained(base, in: base))
    #expect(
      !AgentProfileLaunchPlanner.isContained(
        URL(fileURLWithPath: "/base/agent-profiles/../../.codex", isDirectory: true),
        in: base
      )
    )
    #expect(
      !AgentProfileLaunchPlanner.isContained(
        URL(fileURLWithPath: "/base/agent-profiles-other/x", isDirectory: true),
        in: base
      )
    )
  }

  @Test func effectiveExecutionModeNeverClaimsStandardItCannotProve() {
    var codex = profile(name: "Codex")
    #expect(codex.effectiveExecutionMode == .standard)

    // Recognized bypass flags upgrade the claim to unrestricted.
    codex.extraArguments = "--search --yolo"
    #expect(codex.effectiveExecutionMode == .unrestricted)
    codex.extraArguments = "--dangerously-bypass-approvals-and-sandbox"
    #expect(codex.effectiveExecutionMode == .unrestricted)

    // Unrecognized safety-relevant overrides must not read as Standard:
    // the claim defers to the command line instead.
    codex.extraArguments = "--sandbox danger-full-access"
    #expect(codex.effectiveExecutionMode == .followsExtraArguments)
    codex.extraArguments = "--ask-for-approval never"
    #expect(codex.effectiveExecutionMode == .followsExtraArguments)
    codex.extraArguments = "-c approval_policy=never"
    #expect(codex.effectiveExecutionMode == .followsExtraArguments)

    var claude = profile(name: "Claude", runtime: .claude)
    claude.extraArguments = "--permission-mode bypassPermissions"
    #expect(claude.effectiveExecutionMode == .unrestricted)

    // Harmless flags also defer — any extra argument voids the Standard claim.
    claude.extraArguments = "--verbose"
    #expect(claude.effectiveExecutionMode == .followsExtraArguments)
    claude.executionMode = .unrestricted
    #expect(claude.effectiveExecutionMode == .unrestricted)

    // Advanced arguments remain authoritative and intentionally unparsed.
    // Keep the explicit picker warning conservative even when a later flag
    // may override the generated least-restricted request.
    var cline = profile(name: "Cline", runtime: .cline)
    cline.executionMode = .unrestricted
    cline.extraArguments = "--auto-approve false"
    #expect(cline.effectiveExecutionMode == .unrestricted)

    var piProfile = profile(name: "Pi", runtime: .pi)
    piProfile.executionMode = .unrestricted
    #expect(piProfile.effectiveExecutionMode == .standard)
  }

  @Test func physicalContainmentRejectsSymlinkLeafAndEscapingTargets() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appending(path: "agent-profile-symlink-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? fileManager.removeItem(at: root) }
    let base = root.appending(path: "agent-profiles", directoryHint: .isDirectory)
    let outside = root.appending(path: "fake-codex-home", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)

    // A <uuid> leaf replaced by a symlink to a directory outside the base
    // must be rejected before any file operation.
    let linkedHome = base.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try fileManager.createSymbolicLink(at: linkedHome, withDestinationURL: outside)
    #expect(throws: AgentProfileLaunchPlanError.self) {
      try AgentProfileHomeProvisioner.provision(home: linkedHome, base: base)
    }
    #expect(throws: AgentProfileLaunchPlanError.self) {
      try AgentProfileHomeProvisioner.validatePhysicalContainment(home: linkedHome, base: base)
    }

    // A symlinked *base* (e.g. ~/.prowl on a synced volume) stays legal:
    // both sides of the comparison resolve consistently.
    let baseLink = root.appending(path: "agent-profiles-link", directoryHint: .isDirectory)
    try fileManager.createSymbolicLink(at: baseLink, withDestinationURL: base)
    let homeViaLink = baseLink.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try AgentProfileHomeProvisioner.provision(home: homeViaLink, base: baseLink)
    #expect(fileManager.fileExists(atPath: AgentProfileLaunchPlanner.pathString(homeViaLink)))
  }

  @Test func provisionerRefusesHomesOutsideBase() {
    let base = URL(fileURLWithPath: "/base/agent-profiles", isDirectory: true)
    #expect(throws: AgentProfileLaunchPlanError.self) {
      try AgentProfileHomeProvisioner.provision(
        home: URL(fileURLWithPath: "/Users/x/.codex", isDirectory: true),
        base: base
      )
    }
  }

  @Test func provisionerCreatesOwnerOnlyHome() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "agent-profile-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)

    try AgentProfileHomeProvisioner.provision(home: home, base: root)

    let attributes = try FileManager.default.attributesOfItem(
      atPath: home.path(percentEncoded: false)
    )
    #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o700)
  }

  // MARK: - Settings persistence

  @Test func globalSettingsDecodeLegacyJSONWithoutProfileFields() throws {
    let legacy = Data(#"{"customCommands":[]}"#.utf8)

    let decoded = try JSONDecoder().decode(UserGlobalSettings.self, from: legacy)

    #expect(decoded.agentProfiles.isEmpty)
    #expect(!decoded.didSeedAgentProfiles)
  }

  @Test func globalSettingsRoundTripKeepsProfilesAndSeedFlag() throws {
    let settings = UserGlobalSettings(
      customCommands: [],
      agentProfiles: [profile(name: "Codex · Work")],
      didSeedAgentProfiles: true
    )

    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(UserGlobalSettings.self, from: data)

    #expect(decoded == settings)
  }

  @Test func repositorySettingsDecodeLegacyJSONWithoutProfileFields() throws {
    let legacy = Data(#"{"customCommands":[],"disabledGlobalCommandIDs":[]}"#.utf8)

    let decoded = try JSONDecoder().decode(UserRepositorySettings.self, from: legacy)

    #expect(decoded.defaultAgentProfileID == nil)
    #expect(decoded.lastLaunchedAgentProfileID == nil)
  }

  @Test func repositorySettingsRoundTripKeepsProfileReferences() throws {
    let designated = UUID()
    let remembered = UUID()
    let settings = UserRepositorySettings(
      customCommands: [],
      defaultAgentProfileID: designated,
      lastLaunchedAgentProfileID: remembered
    )

    let data = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(UserRepositorySettings.self, from: data)

    #expect(decoded.defaultAgentProfileID == designated)
    #expect(decoded.lastLaunchedAgentProfileID == remembered)
  }
}
