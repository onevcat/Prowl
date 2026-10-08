import Foundation
import ProwlCLIShared
import Testing

@testable import Prowl

struct AntigravitySupportTests {
  private func agent() throws -> DetectedAgent {
    try #require(DetectedAgent(rawValue: "antigravity"))
  }

  @Test func recognizesAgyAndPrefersTheSessionOwningTUI() throws {
    let expected = try agent()
    #expect(identifyAgent(processName: "agy") == expected)
    #expect(identifyAgent(processName: "antigravity-cli") == expected)
    #expect(identifyAgent(processName: "antigravity_cli") == expected)
    // Bare `antigravity` is the desktop IDE launcher, not the CLI.
    #expect(identifyAgent(processName: "antigravity") == nil)
    #expect(identifyAgent(processName: "agy-module") == nil)

    // The `--bg-updater` child shares argv0 and the foreground job but holds no
    // presence lock; the TUI must win regardless of process enumeration order.
    let tui = ForegroundProcess(
      pid: 200, name: "agy", argv0: "agy", cmdline: "/Users/me/.local/bin/agy")
    let updater = ForegroundProcess(
      pid: 201, parentProcessID: 200, name: "agy", argv0: "agy",
      cmdline: "agy --bg-updater --app_data_dir=antigravity-cli --gemini_dir=.gemini")
    for processes in [[tui, updater], [updater, tui]] {
      let identified = try #require(
        identifyAgentInJob(ForegroundJob(processGroupID: 200, processes: processes)))
      #expect(identified.agent == expected)
      #expect(identified.process.pid == 200)
      #expect(identified.launchProcessID == 200)
    }

    // The updater demotion covers every registered argv0 alias — a shim or
    // direct install can spawn the child as `antigravity-cli` too.
    let aliasedUpdater = ForegroundProcess(
      pid: 203, parentProcessID: 200, name: "antigravity-cli", argv0: "antigravity-cli",
      cmdline: "antigravity-cli --bg-updater")
    for processes in [[tui, aliasedUpdater], [aliasedUpdater, tui]] {
      let identified = try #require(
        identifyAgentInJob(ForegroundJob(processGroupID: 200, processes: processes)))
      #expect(identified.agent == expected)
      #expect(identified.process.pid == 200)
    }

    // `--bg-updater` is pinned to the first argument: a TUI whose seeded prompt
    // merely mentions the token keeps full score and still wins.
    let promptedTUI = ForegroundProcess(
      pid: 204, name: "agy", argv0: "agy",
      cmdline: "agy --prompt-interactive \"explain what --bg-updater does\"")
    for processes in [[promptedTUI, updater], [updater, promptedTUI]] {
      let identified = try #require(
        identifyAgentInJob(ForegroundJob(processGroupID: 204, processes: processes)))
      #expect(identified.process.pid == 204)
    }

    // Go flag equivalence: `-bg-updater` spells the same updater mode.
    let singleDashUpdater = ForegroundProcess(
      pid: 207, parentProcessID: 200, name: "agy", argv0: "agy",
      cmdline: "agy -bg-updater --app_data_dir=antigravity-cli")
    for processes in [[tui, singleDashUpdater], [singleDashUpdater, tui]] {
      let identified = try #require(
        identifyAgentInJob(ForegroundJob(processGroupID: 200, processes: processes)))
      #expect(identified.process.pid == 200)
    }

    // Without argv0 (procargs failure) the comm-name candidate is still demoted
    // below the TUI's, so enumeration order never hands the pane the updater.
    let nameOnlyTUI = ForegroundProcess(pid: 205, name: "agy", argv0: nil, cmdline: nil)
    let nameOnlyUpdater = ForegroundProcess(
      pid: 206, name: "agy", argv0: nil, cmdline: "agy --bg-updater")
    for processes in [[nameOnlyTUI, nameOnlyUpdater], [nameOnlyUpdater, nameOnlyTUI]] {
      let identified = try #require(
        identifyAgentInJob(ForegroundJob(processGroupID: 205, processes: processes)))
      #expect(identified.process.pid == 205)
    }

    // Native-executable name: a cmdline token inside a wrapped runtime must not
    // classify the job (score-40 guard, same as grok/devin).
    let wrapped = ForegroundProcess(
      pid: 202, name: "node", argv0: "node", cmdline: "node /tmp/app.js --model agy")
    #expect(identifyAgentInJob(ForegroundJob(processGroupID: 202, processes: [wrapped])) == nil)
  }

  @Test func launchBindsPromptAsLastValueTokenAndMapsModes() throws {
    let runtime = try #require(AgentProfileRuntime(rawValue: "antigravity"))
    // `--print`/`--prompt-interactive` consume the next token as the prompt, so
    // a prompt shaped like a flag stays a prompt (except bare `--help`/
    // `--version`, which agy intercepts before flag parsing — unreachable as
    // seeded prompts, which carry task text) — and the last-token contract
    // keeps seeded-prompt probing (workflows) working.
    let prompt = "--model is task text\nnot an option"
    for (intent, suffix) in [
      (AgentStartIntent.interactive, []),
      (.prompt(prompt), ["--prompt-interactive", prompt]),
      (.headless(prompt), ["--print", prompt]),
    ] {
      let invocation = try AgentRuntimeAdapterRegistry.makeStartInvocation(
        AgentStartRequest(
          runtime: runtime, intent: intent,
          configuration: .init(model: "gemini-3-pro", reasoningEffort: "high")))
      #expect(invocation.executable == "agy")
      #expect(invocation.arguments == ["--model", "gemini-3-pro", "--effort", "high"] + suffix)
    }
    let unrestricted = try AgentRuntimeAdapterRegistry.makeStartInvocation(
      AgentStartRequest(
        runtime: runtime, intent: .interactive, configuration: .init(executionMode: .unrestricted)))
    #expect(unrestricted.arguments == ["--dangerously-skip-permissions"])
    let adapter = try #require(AgentRuntimeAdapterRegistry.profileAdapter(for: runtime))
    #expect(!adapter.supportsAccountIsolation)
    #expect(adapter.supportsReasoningEffort)
    #expect(runtime.defaultHomeDirectoryName == ".gemini/antigravity-cli")
  }

  @Test func observesOptionsAroundPromptFlags() throws {
    let runtime = try #require(AgentProfileRuntime(rawValue: "antigravity"))
    let observation = AgentRuntimeAdapterRegistry.observe(
      runtime: runtime,
      arguments: [
        "agy", "--model", "gemini-3-pro", "--dangerously-skip-permissions",
        "-i", "--model", "wrong",
      ])
    #expect(observation.model == "gemini-3-pro")
    #expect(observation.executionMode == .unrestricted)
    // agy consumes exactly one token after a prompt flag; real flags after the
    // prompt value are still observed.
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime,
        arguments: ["agy", "-i", "task text", "--model", "gemini-3-flash"])
        == AgentLaunchObservation(model: "gemini-3-flash", executionMode: nil))
    // A flag-shaped prompt value is consumed as text, never as an option.
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime, arguments: ["agy", "-i", "--dangerously-skip-permissions"])
        == AgentLaunchObservation(model: nil, executionMode: nil))
    // The same holds for every agy value-flag: `--model` takes the flag as its
    // model name, so the permission flag never takes effect.
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime, arguments: ["agy", "--model", "--dangerously-skip-permissions"])
        == AgentLaunchObservation(model: "--dangerously-skip-permissions", executionMode: nil))
    // `--effort` consumes `-i` as its value; the trailing permission flag is real.
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime, arguments: ["agy", "--effort", "-i", "--dangerously-skip-permissions"])
        == AgentLaunchObservation(model: nil, executionMode: .unrestricted))
    #expect(
      AgentRuntimeAdapterRegistry.observe(runtime: runtime, arguments: ["agy"]).executionMode == nil)
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime,
        arguments: ["agy", "--model=gemini-3-pro", "--dangerously-skip-permissions=false"])
        == AgentLaunchObservation(model: "gemini-3-pro", executionMode: .standard))
  }

  @Test func observesGoStyleFlagSpellingsAndPositionals() throws {
    let runtime = try #require(AgentProfileRuntime(rawValue: "antigravity"))
    // Go flag semantics: `-name` spells the same option as `--name`
    // (verified `agy -print`/`-model`/`-help` on 1.3.1), including `=` forms,
    // value consumption, and last-wins permission overrides.
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime,
        arguments: [
          "agy", "--dangerously-skip-permissions=false", "-dangerously-skip-permissions",
        ]
      )
      .executionMode == .unrestricted)
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime,
        arguments: [
          "agy", "--dangerously-skip-permissions", "-dangerously-skip-permissions=false",
        ]
      )
      .executionMode == .standard)
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime, arguments: ["agy", "-model", "--dangerously-skip-permissions"])
        == AgentLaunchObservation(model: "--dangerously-skip-permissions", executionMode: nil))
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime,
        arguments: ["agy", "-model=gemini-3-pro", "-dangerously-skip-permissions"])
        == AgentLaunchObservation(model: "gemini-3-pro", executionMode: .unrestricted))
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime, arguments: ["agy", "-effort", "high", "-dangerously-skip-permissions=0"])
        == AgentLaunchObservation(model: nil, executionMode: .standard))
    // A bare `--` ends flag parsing; following tokens are positionals.
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime, arguments: ["agy", "--", "--dangerously-skip-permissions"]
      )
      .executionMode == nil)
    // The `-p` alias consumes its value like `--print`; `-c` is a bool alias.
    // Two-dash spellings of the aliases (`--i`, `--p`) are equivalent in Go.
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime, arguments: ["agy", "-p", "--dangerously-skip-permissions"])
        == AgentLaunchObservation(model: nil, executionMode: nil))
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime, arguments: ["agy", "--i", "--dangerously-skip-permissions"])
        == AgentLaunchObservation(model: nil, executionMode: nil))
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime,
        arguments: ["agy", "-c", "--dangerously-skip-permissions=false", "-model", "gemini-3-pro"])
        == AgentLaunchObservation(model: "gemini-3-pro", executionMode: .standard))
    // Hidden string flags (updater argv) consume their value like `--model`.
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime, arguments: ["agy", "--gemini_dir", "--dangerously-skip-permissions"])
        == AgentLaunchObservation(model: nil, executionMode: nil))
  }

  @Test func observesPermissionModesPositionalsAndUnprovableCases() throws {
    let runtime = try #require(AgentProfileRuntime(rawValue: "antigravity"))
    // Go-style bool: a space `false` is a positional, not the flag's value.
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime, arguments: ["agy", "--dangerously-skip-permissions", "false"]
      )
      .executionMode == .unrestricted)
    // Later arguments override earlier ones, and every Go bool-false spelling
    // explicitly clears the flag.
    for offForm in ["=false", "=0", "=f", "=F", "=FALSE", "=False"] {
      #expect(
        AgentRuntimeAdapterRegistry.observe(
          runtime: runtime,
          arguments: [
            "agy", "--dangerously-skip-permissions", "--dangerously-skip-permissions\(offForm)",
          ]
        )
        .executionMode == .standard)
    }
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime,
        arguments: [
          "agy", "--dangerously-skip-permissions=false", "--dangerously-skip-permissions",
        ]
      )
      .executionMode == .unrestricted)
    // Go flag parsing stops at the first positional (argv0 aside), so flags
    // after a stray operand — or a subcommand — are never parsed by agy.
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime, arguments: ["agy", "note", "--dangerously-skip-permissions"]
      )
      .executionMode == nil)
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime, arguments: ["agy", "models", "--dangerously-skip-permissions"]
      )
      .executionMode == nil)
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime,
        arguments: [
          "agy", "--dangerously-skip-permissions", "stray",
          "--dangerously-skip-permissions=false",
        ]
      )
      .executionMode == .unrestricted)
    // A flag-shaped token the table doesn't know could be a hidden string
    // flag that swallowed the off-form, so Standard is unprovable — nil.
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime,
        arguments: [
          "agy", "--dangerously-skip-permissions", "--some-future-flag",
          "--dangerously-skip-permissions=false",
        ]
      )
      .executionMode == nil)
    // A known bool in the same slot doesn't swallow, and an `=`-valued
    // unknown is self-contained.
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime,
        arguments: [
          "agy", "--dangerously-skip-permissions", "--sandbox",
          "--dangerously-skip-permissions=false",
        ]
      )
      .executionMode == .standard)
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime,
        arguments: [
          "agy", "--dangerously-skip-permissions", "--some-future=x",
          "--dangerously-skip-permissions=false",
        ]
      )
      .executionMode == .standard)
  }

  @Test func screenStatesUseStatusRowAndDialogChrome() throws {
    let agent = try agent()
    let idle = """
      Antigravity CLI 1.3.1

      >

      ? for shortcuts                                             Gemini 3.1 Pro · high
      """
    #expect(agent.detectState(in: idle) == .idle)

    let working = """
      ⣻  Generating...
      ────────────────────────────────────────────────────
      >
      ────────────────────────────────────────────────────
      esc to cancel                                               Gemini 3.1 Pro · high
      """
    #expect(agent.detectState(in: working) == .working)
    // A completed turn redraws the status row in place: `? for shortcuts`
    // replaces `esc to cancel` — the working footer never scrolls up.
    let afterTurn = """
      ⣻  Generating...
      Done. Wrote the file.
      ────────────────────────────────────────────────────
      >
      ────────────────────────────────────────────────────
      ? for shortcuts                                             Gemini 3.1 Pro · high
      """
    #expect(agent.detectState(in: afterTurn) == .idle)

    // Workspace trust (1.3.1): navigate hint is the last row, no status row.
    let trust = """
      Do you trust the contents of this project?
      Antigravity CLI requires permission to read, edit, and execute files here.
      > Yes, I trust this folder
        No, exit
        ↑/↓ Navigate · enter Confirm
      """
    #expect(agent.detectState(in: trust) == .blocked)

    // Tool permission keeps the `esc to cancel` status row; the dialog chrome
    // must win over the working footer.
    let permission = """
      Requesting permission for:
         echo hello
      Run this command?
      > 1. Yes, run command
        2. Yes, always allow
        3. No, cancel
        ↑/↓ Navigate · tab Amend · ctrl+g edit/expand command
      esc to cancel                                               Gemini 3.1 Pro · high
      """
    #expect(agent.detectState(in: permission) == .blocked)

    // Headroom: a second status row below the navigate hint must not mask a
    // live dialog into Working.
    let permissionWithExtraRow = """
      Requesting permission for:
         echo hello
      > 1. Yes, run command
        2. No, cancel
        ↑/↓ Navigate · enter Confirm
      usage: 12k tokens
      esc to cancel                                               Gemini 3.1 Pro · high
      """
    #expect(agent.detectState(in: permissionWithExtraRow) == .blocked)

    // The hint window tolerates status + usage + appended stack rows below it;
    // the selected option stays above the hint in live dialogs.
    let permissionWithStackedStatus = """
      Requesting permission for:
         echo hello
      > 1. Yes, run command
        2. No, cancel
        ↑/↓ Navigate · enter Confirm
      usage: 12k tokens
      esc to cancel                                               Gemini 3.1 Pro · high
      ctx 12% · custom status
      """
    #expect(agent.detectState(in: permissionWithStackedStatus) == .blocked)

    // Answered dialogs scroll into transcript without their live chrome.
    let answered = """
      Requesting permission for:
         echo hello
        1. Yes, run command
        2. Yes, always allow
      >
      ? for shortcuts                                             Gemini 3.1 Pro · high
      """
    #expect(agent.detectState(in: answered) == .idle)
    // Transcript prose cannot spoof the cancel footer or the navigate hint.
    #expect(
      agent.detectState(
        in: "I explained that esc to cancel interrupts a turn.\n>\n? for shortcuts") == .idle)
  }

  @Test func historicalDialogChromeIsScrollback() throws {
    let agent = try agent()
    // A stale hint residue sits ABOVE the composer's `> typed` row — reversed
    // order is transcript, not a live dialog.
    let staleHintWithTypedComposer = """
        1. Yes, run command
        ↑/↓ Navigate · enter Confirm
      ────────────────────────────────────────────────────
      > explain this
      ────────────────────────────────────────────────────
      ? for shortcuts                                             Gemini 3.1 Pro · high
      """
    #expect(agent.detectState(in: staleHintWithTypedComposer) == .idle)

    // A complete dialog quoted in transcript — `> ` option and hint intact —
    // is scrollback once a fresh composer owns the bottom region, whatever the
    // footer below it reports.
    let quotedDialogThenIdle = """
      Here is the dialog you asked me to explain:
      > Yes, run command
        No, cancel
        ↑/↓ Navigate · enter Confirm
      ────────────────────────────────────
      >
      ────────────────────────────────────
      ? for shortcuts                                             Gemini 3.1 Pro · high
      """
    #expect(agent.detectState(in: quotedDialogThenIdle) == .idle)

    let quotedDialogThenWorking = """
      ⣻  Generating...
      > Yes, run command
        No, cancel
        ↑/↓ Navigate · enter Confirm
      ────────────────────────────────────
      >
      ────────────────────────────────────
      esc to cancel                                               Gemini 3.1 Pro · high
      """
    #expect(agent.detectState(in: quotedDialogThenWorking) == .working)
  }

  @Test func appendedStatusOutputKeepsFooterEvidence() throws {
    let agent = try agent()
    // `stack_with_default` appends custom status output below the built-in row;
    // the footer signatures must still be found in the bounded tail.
    let workingStacked = """
      ⣻  Generating...
      >
      esc to cancel                                               Gemini 3.1 Pro · high
      ctx 12% · ⌘ custom status
      """
    #expect(agent.detectState(in: workingStacked) == .working)

    let idleStacked = """
      >
      ? for shortcuts                                             Gemini 3.1 Pro · high
      ctx 12% · ⌘ custom status
      """
    #expect(agent.detectState(in: idleStacked) == .idle)

    // A layout with no footer signature is unknown, not affirmative idle —
    // screen heuristics are the only evidence channel for this runtime.
    let midStream = """
      ⣻  Generating...
      partial output row
      more partial output
      """
    #expect(agent.detectState(in: midStream) == .unknown)

    // Contradictory evidence in the tail is also unknown.
    #expect(
      agent.detectState(
        in: "esc to cancel\n? for shortcuts") == .unknown)

    // A `>`-leading custom status row is not composer chrome: the scrollback
    // veto keys on the `─` border, so a live dialog survives stray output.
    let permissionWithArrowStatus = """
      Requesting permission for:
         echo hello
      > 1. Yes, run command
        2. No, cancel
        ↑/↓ Navigate · enter Confirm
      esc to cancel                                               Gemini 3.1 Pro · high
      > ahead 2
      """
    #expect(agent.detectState(in: permissionWithArrowStatus) == .blocked)
  }

  @Test func sessionOwnershipUsesOnlyOpenLockPaths() throws {
    let profile = AgentSessionProfile.profile(for: try agent())
    let root = "/Users/test/.gemini/antigravity-cli"
    let id = "7513431a-f203-40bf-a062-3c423b19babc"
    let session = try #require(profile.parsePath(root + "/presence/\(id).lock"))
    #expect(session.id == id)
    #expect(
      session.transcriptPath?.path
        == root + "/brain/\(id)/.system_generated/logs/transcript.jsonl")
    #expect(session.source == .openFile)
    #expect(session.confidence == .exact)
    let upper = try #require(profile.parsePath(root + "/presence/\(id.uppercased()).lock"))
    #expect(upper.id == id)
    // Stale or malformed locks resolve to nothing: only open descriptors parse.
    #expect(profile.parsePath(root + "/presence/not-a-uuid.lock") == nil)
    #expect(profile.parsePath(root + "/presence/.lock") == nil)
    #expect(profile.parsePath(root + "/presence/nested/\(id).lock") == nil)
    #expect(profile.parsePath(root + "/conversations/\(id).db") == nil)
    #expect(profile.candidateRoots(URL(filePath: "/Users/test"), nil, Date(), Date()).isEmpty)
  }

  @Test func workflowBindsAntigravityThroughTheExistingProfilePath() throws {
    let runtime = try #require(AgentProfileRuntime(rawValue: "antigravity"))
    let profile = AgentProfile(name: "Antigravity", runtime: runtime)
    for agents: [String]? in [nil, ["antigravity"]] {
      let role = WorkflowRoleDefinition(
        name: "worker", source: .launch, launch: WorkflowLaunchRequirements(agents: agents))
      let result = try WorkflowBindingResolver.resolve(
        role: role, remembered: nil, override: .profileID(profile.id),
        context: WorkflowBindingResolverContext(profiles: [profile])
      ).get()
      #expect(result.resolution == .resolved(profile, tier: .override))
    }
    #expect(WorkflowBindingResolver.adapterSupportsSeededPrompt(profile))
  }
}
