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
    // The unprovable check is symmetric: an unrecognized flag before a bare
    // decisive flag could have swallowed it just as well.
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime,
        arguments: [
          "agy", "--dangerously-skip-permissions=false", "--some-future-flag",
          "--dangerously-skip-permissions",
        ]
      )
      .executionMode == nil)
    // Adjacency is not the test: `--weird` could be a newer string flag that
    // consumed `--effort`, leaving `high` positional and the rest unparsed.
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime,
        arguments: [
          "agy", "--weird", "--effort", "high", "--sandbox",
          "--dangerously-skip-permissions",
        ]
      )
      .executionMode == nil)
    // `=`-valued unknowns are self-contained and cannot consume argv tokens,
    // so they leave the decisive flag's mode provable.
    #expect(
      AgentRuntimeAdapterRegistry.observe(
        runtime: runtime,
        arguments: [
          "agy", "--dangerously-skip-permissions", "--x=1",
          "--dangerously-skip-permissions=false",
        ]
      )
      .executionMode == .standard)
  }

  // The screens below reproduce agy 1.3.2 chrome captured live in a 100-column
  // tmux pane: full-width `─` composer borders, a column-0 `>` prompt, and the
  // status row directly below the box, padded away from the right-aligned
  // model label. Synthetic variants keep that shape at a narrower width.

  @Test func screenStatesAnchorOnTheComposerAndItsStatusRow() throws {
    let agent = try agent()
    let idle = """
      Antigravity CLI 1.3.2
      ────────────────────────────────────────────────────
      >
      ────────────────────────────────────────────────────
      ? for shortcuts                                             Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: idle) == .idle)

    let working = """
      ⣻  Generating...
      ────────────────────────────────────────────────────
      >
      ────────────────────────────────────────────────────
      esc to cancel                                               Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: working) == .working)
    #expect(agent.detectState(in: working.replacing("esc to cancel", with: "esc to interrupt")) == .working)

    // A completed turn redraws the status row in place below the same box; the
    // echoed prompt above it has a narrower rule and no bottom border.
    let afterTurn = """
      ────────────────────────────────────────────────────────────
      > Run the shell command `echo hello` and tell me its output.
      ● Ran (echo hello) (ctrl+o to expand)
        The output of the command is:
          hello
      ────────────────────────────────────────────────────────────────────────────────────────────────────
      >
      ────────────────────────────────────────────────────────────────────────────────────────────────────
      ? for shortcuts                                                              Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: afterTurn) == .idle)

    // The label resolves asynchronously (bare signature for the first seconds
    // of a `--model` launch) and non-Gemini labels carry no `· effort` tail.
    for label in ["", "                         Claude Sonnet 4.6 (Thinking)", "        GPT-OSS 120B (Medium)"] {
      let screen = idle.replacing("                                             Gemini 3.8 Flash · high", with: label)
      #expect(agent.detectState(in: screen) == .idle, "label: \(label)")
    }

    // Wrapped input continues on indented rows inside the box (verified live):
    // neither an indented `─` nor an indented signature is chrome.
    let workingWithWrappedSigInput = """
      ────────────────────────────────────
      > a very long line that wraps inside the box
        ────────────────────────────────────
        ? for shortcuts docs
      ────────────────────────────────────
      esc to cancel                                               Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: workingWithWrappedSigInput) == .working)
    // Signature-shaped text typed into the prompt row is input, not a status row.
    #expect(agent.detectState(in: working.replacing("\n>\n", with: "\n> ? for shortcuts\n")) == .working)

    // No composer on screen — a redraw in flight, a viewer overlay, a headless
    // run — is unknown, never affirmative idle; so is a contradictory tail.
    #expect(agent.detectState(in: "⣻  Generating...\npartial output row\nmore partial output") == .unknown)
    #expect(agent.detectState(in: "esc to cancel\n? for shortcuts") == .unknown)
    // The last composer is the live one: a box caught without its status row is
    // unknown even when an earlier box above it still shows an idle footer.
    let historicalIdleThenUnsignedComposer = """
      ────────────────────────────────────────────────────
      > earlier prompt
      ────────────────────────────────────────────────────
      ? for shortcuts                                             Gemini 3.8 Flash · high
      Some ordinary transcript output.
      ────────────────────────────────────────────────────
      >
      ────────────────────────────────────────────────────
      """
    #expect(agent.detectState(in: historicalIdleThenUnsignedComposer) == .unknown)
  }

  @Test func dialogsAreBlockedWhateverFollowsTheHint() throws {
    let agent = try agent()
    // Workspace trust (live 1.3.2): the hint is followed only by the model label.
    let trust = """
      Accessing workspace:
      /Users/usr/project
      Do you trust the contents of this project?
      Antigravity CLI requires permission to read, edit, and execute files here.
      > Yes, I trust this folder
        No, exit
        ↑/↓ Navigate · enter Confirm
                                                                                   Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: trust) == .blocked)
    let trustWithoutLabel = trust.replacing("Gemini 3.8 Flash · high", with: "")
    #expect(agent.detectState(in: trustWithoutLabel) == .blocked)

    // Tool permission (live 1.3.2) keeps the `esc to cancel` status row under a
    // `Command` header and a full-width rule; the dialog chrome wins over it.
    let permission = """
      ────────────────────────────────────────────────────────────
      > Run the shell command `echo hello` and tell me its output.
      ○ Thought for 4.2s (The task is to execute a simple shell command and retrieve its output. The...)
      ● Ran (echo hello) (ctrl+o to expand)
      Command
      ────────────────────────────────────────────────────────────────────────────────────────────────────
      Requesting permission for:
         echo hello
      Run this command?
      > 1. Yes, run command
        2. Yes, and always allow in this conversation for commands that start with 'echo'
        3. Yes, and always allow for commands that start with 'echo' (Persist to settings.json)
        4. No, cancel
        ↑/↓ Navigate · tab Amend · ctrl+g edit/expand command
      esc to cancel                                                                Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: permission) == .blocked)

    let askUser = """
      ? Which color do you prefer?
      Question
      ────────────────────────────────────────────────────────────────────────────────────────────────────
      Question 1/1: Which color do you prefer?
      > 1. Red
        2. Blue
        3. Write-in...
        ↑/↓ Navigate · enter Select · esc Skip
      esc to cancel                                                                Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: askUser) == .blocked)

    // A usage row between the hint and the status row, and long option lists
    // (the `> ` row seven rows above the hint) stay inside the dialog read.
    let permissionWithExtraRow = """
      Requesting permission for:
         echo hello
      > 1. Yes, run command
        2. No, cancel
        ↑/↓ Navigate · enter Confirm
      usage: 12k tokens
      esc to cancel                                               Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: permissionWithExtraRow) == .blocked)
    let permissionLongOptions = """
      Requesting permission for:
         echo hello
      > 1. Yes, run command
        2. Yes, always allow
        3. Yes, allow always
        4. Amend command
        5. Explain command
        6. Ask a question
        7. No, cancel
        ↑/↓ Navigate · enter Confirm
      esc to cancel                                               Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: permissionLongOptions) == .blocked)

    // Answered dialogs scroll into the transcript without their `> ` selection.
    let answered = """
      Requesting permission for:
         echo hello
        1. Yes, run command
        2. Yes, always allow
      ────────────────────────────────────────────────────
      >
      ────────────────────────────────────────────────────
      ? for shortcuts                                             Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: answered) == .idle)
    // Transcript prose cannot spoof the cancel footer or the navigate hint.
    let prose = """
      I explained that esc to cancel interrupts a turn.
      ────────────────────────────────────────────────────
      >
      ────────────────────────────────────────────────────
      ? for shortcuts
      """
    #expect(agent.detectState(in: prose) == .idle)
  }

  @Test func quotedDialogChromeStaysBlocked() throws {
    let agent = try agent()
    // A hint row with no column-0 `> ` selection above it is cropped live
    // chrome or residue: the composer evidence below it is denied.
    let staleHintWithTypedComposer = """
        1. Yes, run command
        ↑/↓ Navigate · enter Confirm
      ────────────────────────────────────────────────────
      > explain this
      ────────────────────────────────────────────────────
      ? for shortcuts                                             Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: staleHintWithTypedComposer) == .unknown)

    // Column-0 dialog chrome is terminal: agent responses render indented,
    // so a `> ` selection at column 0 is the live dialog or the user's own
    // echo. A verbatim quote above a live composer reads Blocked until it
    // scrolls off — a delay, where a vetoed live dialog would be a dispatch
    // into a modal prompt.
    let quotedDialogThenIdle = """
      Here is the dialog you asked me to explain:
      > Yes, run command
        No, cancel
        ↑/↓ Navigate · enter Confirm
      ────────────────────────────────────
      >
      ────────────────────────────────────
      ? for shortcuts                                             Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: quotedDialogThenIdle) == .blocked)
    #expect(agent.detectState(in: quotedDialogThenIdle.replacing("? for shortcuts", with: "esc to cancel")) == .blocked)

    // The quote may carry the dialog's own status line; it stays Blocked.
    let quotedDialogWithStatusThenIdle = """
      Requesting permission for:
         echo hello
      > 1. Yes, run command
        2. No, cancel
        ↑/↓ Navigate · enter Confirm
      esc to cancel                                               Gemini 3.8 Flash · high
      ────────────────────────────────────
      >
      ────────────────────────────────────
      ? for shortcuts                                             Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: quotedDialogWithStatusThenIdle) == .blocked)

    // Detection anchors on the LAST hint row: a quoted dialog above a live
    // one still reports the live dialog. A live dialog replaces the composer,
    // so no composer box sits between the quote and the dialog.
    let quotedDialogThenLiveDialog = """
      > Yes, run command
        No, cancel
        ↑/↓ Navigate · enter Confirm
        I quoted that dialog above as you asked.
      Command
      ────────────────────────────────────────────────────────────
      Requesting permission for:
         echo hello
      > 1. Yes, run command
        2. No, cancel
        ↑↓ Navigate · enter Confirm
      esc to cancel                                               Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: quotedDialogThenLiveDialog) == .blocked)
  }

  @Test func stackedStatusOutputIsNeverEvidence() throws {
    let agent = try agent()
    // `stack_with_default` renders the status script's stdout verbatim below
    // the built-in status row (verified live with 25 rows), so rows under the
    // status row never reach the evidence, whatever they look like.
    let workingStacked = """
      ⣻  Generating...
      ────────────────────────────────────
      >
      ────────────────────────────────────
      esc to cancel                                               Gemini 3.8 Flash · high
      ctx 12% · ⌘ custom status
      """
    #expect(agent.detectState(in: workingStacked) == .working)
    #expect(agent.detectState(in: workingStacked.replacing("esc to cancel", with: "? for shortcuts")) == .idle)

    let workingWithSpoofedIdle = """
      ⣻  Generating...
      ────────────────────────────────────
      >
      ────────────────────────────────────
      esc to cancel                                               Gemini 3.8 Flash · high
      ────────────────
      branch main
      ctx 12%
      ? for shortcuts custom help
      """
    #expect(agent.detectState(in: workingWithSpoofedIdle) == .working)
    // A stacked box narrower than the composer is not a composer.
    let workingWithBoxedSpoofedIdle = """
      ⣻  Generating...
      ────────────────────────────────────
      >
      ────────────────────────────────────
      esc to cancel                                               Gemini 3.8 Flash · high
      ────────────────
      > ahead 2
      ────────────────
      ? for shortcuts custom help
      """
    #expect(agent.detectState(in: workingWithBoxedSpoofedIdle) == .working)

    // Live permission and ask-user dialogs survive the same stacked box below
    // their status row (captured on 1.3.2): nothing below the hint can veto
    // the dialog.
    let permissionWithStackedBox = """
      Command
      ────────────────────────────────────────────────────────────────────────────────────────────────────
      Requesting permission for:
         echo hello
      Run this command?
      > 1. Yes, run command
        2. Yes, and always allow in this conversation for commands that start with 'echo'
        3. Yes, and always allow for commands that start with 'echo' (Persist to settings.json)
        4. No, cancel
        ↑/↓ Navigate · tab Amend · ctrl+g edit/expand command
      esc to cancel                                                                Gemini 3.8 Flash · high
      ────────────────
      > ahead 2
      ────────────────
      ? for shortcuts custom help
      """
    #expect(agent.detectState(in: permissionWithStackedBox) == .blocked)
    let askUserWithStackedBox = """
      Question
      ────────────────────────────────────────────────────────────────────────────────────────────────────
      Question 1/1: Which color do you prefer?
      > 1. Red
        2. Blue
        3. Write-in...
        ↑/↓ Navigate · enter Select · esc Skip
      esc to cancel                                                                Gemini 3.8 Flash · high
      ────────────────
      > ahead 2
      ────────────────
      ? for shortcuts custom help
      """
    #expect(agent.detectState(in: askUserWithStackedBox) == .blocked)
    let stackedRows = [
      "> ahead 2",
      "────────────────",
      "esc to cancel\n────────────────\nbranch main\nctx 12%\n? for shortcuts custom help",
    ]
    for stacked in stackedRows {
      let screen = permissionDialog + "\n" + stacked
      #expect(agent.detectState(in: screen) == .blocked, "stacked: \(stacked)")
    }

    // Twenty-five stacked rows would push the composer out of the 24-row tail
    // the other legacy detectors read; Antigravity reads the full screen, and
    // the cropped slice still reads unknown rather than the spoofed idle.
    let longStack = (1...24).map { "ordinary output line \($0)" } + ["? for shortcuts custom help"]
    let composerRows = workingStacked.split(separator: "\n").dropLast().map(String.init)
    let workingWithLongStack = (composerRows + longStack).joined(separator: "\n")
    #expect(agent.detectState(in: workingWithLongStack) == .working)
    #expect(agent.detectState(in: agentDetectionRecentText(workingWithLongStack)) == .unknown)
  }

  private var permissionDialog: String {
    """
    Requesting permission for:
       echo hello
    > 1. Yes, run command
      2. No, cancel
      ↑/↓ Navigate · enter Confirm
    esc to cancel                                               Gemini 3.8 Flash · high
    """
  }

  // The fixtures below come from the contributor's follow-up (`84fce7e0`);
  // expectations follow the composer-anchored contract of this branch.

  @Test func unanchoredSignaturesAreNotFooterEvidence() throws {
    let agent = try agent()
    // Deep output can push the composer and footer off the screen entirely;
    // the remaining `? for shortcuts`-leading row has no composer to anchor
    // to, so the screen is unknown rather than idle.
    let croppedWorkingWithSpoofedIdle = """
      ⣻  Generating...
      partial output row 1
      partial output row 2
      partial output row 3
      partial output row 4
      partial output row 5
      partial output row 6
      partial output row 7
      partial output row 8
      partial output row 9
      partial output row 10
      partial output row 11
      partial output row 12
      partial output row 13
      partial output row 14
      partial output row 15
      partial output row 16
      partial output row 17
      partial output row 18
      partial output row 19
      partial output row 20
      partial output row 21
      partial output row 22
      partial output row 23
      ? for shortcuts custom help
      """
    #expect(agent.detectState(in: croppedWorkingWithSpoofedIdle) == .unknown)

    // A historical idle box does not rescue a live composer that has not
    // rendered its footer — the last box must carry its own status row.
    let quotedIdleThenUnsignedComposer = """
      ────────────────────────────────────
      > earlier prompt
      ────────────────────────────────────
      ? for shortcuts
      ────────────────────────────────────
      > current input
      ────────────────────────────────────
      """
    #expect(agent.detectState(in: quotedIdleThenUnsignedComposer) == .unknown)

    // Earlier boxes never vote: only the last box's status row decides.
    let unsignedEarlierBox = """
      ────────────────────────────────────
      > earlier prompt
      ────────────────────────────────────
      ────────────────────────────────────
      > current input
      ────────────────────────────────────
      ? for shortcuts
      """
    #expect(agent.detectState(in: unsignedEarlierBox) == .idle)
    let agreeingBoxes = """
      ────────────────────────────────────
      > earlier prompt
      ────────────────────────────────────
      esc to cancel
      ────────────────────────────────────
      > current input
      ────────────────────────────────────
      esc to cancel                                               Gemini 3.1 Pro · high
      """
    #expect(agent.detectState(in: agreeingBoxes) == .working)

    // An unclosed box is no box at all, so its signature is unanchored.
    let unclosedBox = """
      ────────────────────────────────────
      > current input
      esc to cancel
      """
    #expect(agent.detectState(in: unclosedBox) == .unknown)

    // Appended `esc`-leading output below an idle footer cannot flip it to
    // working either — rows under the real footer are not evidence.
    let idleWithSpoofedWorking = """
      ────────────────────────────────────
      >
      ────────────────────────────────────
      ? for shortcuts                                             Gemini 3.1 Pro · high
      esc to cancel custom
      """
    #expect(agent.detectState(in: idleWithSpoofedWorking) == .idle)
  }

  @Test func dialogWindowBounds() throws {
    let agent = try agent()
    // A live trust dialog carries no footer at all, so appended rows sit
    // directly below its hint — an appended box and signature there cannot
    // demote it, and neither can the same box under a permission dialog.
    let trustWithBoxedSpoofedFooter = """
      Do you trust the contents of this project?
      Antigravity CLI requires permission to read, edit, and execute files here.
      > Yes, I trust this folder
        No, exit
        ↑/↓ Navigate · enter Confirm
      ────────────────
      > ahead 2
      ────────────────
      ? for shortcuts custom help
      """
    #expect(agent.detectState(in: trustWithBoxedSpoofedFooter) == .blocked)
    let permissionWithBoxedSpoofedFooter = """
      Requesting permission for:
         echo hello
      > 1. Yes, run command
        2. No, cancel
        ↑/↓ Navigate · enter Confirm
      esc to cancel
      ────────────────
      > ahead 2
      ────────────────
      ? for shortcuts custom help
      """
    #expect(agent.detectState(in: permissionWithBoxedSpoofedFooter) == .blocked)

    // Depth below the hint does not hide the dialog.
    let permissionBuriedHint = """
      Requesting permission for:
         echo hello
      > 1. Yes, run command
        2. No, cancel
        ↑/↓ Navigate · enter Confirm
      esc to cancel
      output row 1
      output row 2
      output row 3
      output row 4
      output row 5
      output row 6
      output row 7
      output row 8
      output row 9
      output row 10
      output row 11
      """
    #expect(agent.detectState(in: permissionBuriedHint) == .blocked)

    // The `> ` selection window spans eight rows above the hint; nine filler
    // rows leave a bare hint — cropped dialog or residue — which denies the
    // composer evidence below it rather than trusting it.
    let optionBeyondWindow = """
      > 1. Yes, run command
        filler row 1
        filler row 2
        filler row 3
        filler row 4
        filler row 5
        filler row 6
        filler row 7
        filler row 8
        filler row 9
        ↑/↓ Navigate · enter Confirm
      ────────────────────────────────────
      >
      ────────────────────────────────────
      ? for shortcuts                                             Gemini 3.1 Pro · high
      """
    #expect(agent.detectState(in: optionBeyondWindow) == .unknown)
  }

  @Test func echoedPromptsAreNeverOptionRows() throws {
    let agent = try agent()
    // Live 1.3.2: a slash command echoes as a column-0 `> ` row with no `─`
    // rule above it and an indented result beneath — the shape a selected
    // dialog option has. The live composer below decides, so this is Idle.
    let slashCommandEcho = """
      ────────────────────────────────────────────────────────────
      > hello

        Hello! How can I help you with Prowl today?

      > /model
        ⎿  Model set to Gemini 3.8 Flash (High)

      ────────────────────────────────────────────────────────────
      > 你好啊

        你好！今天有什么我可以帮你的吗？

      ────────────────────────────────────────────────────────────────────────────────────────────────────
      >
      ────────────────────────────────────────────────────────────────────────────────────────────────────
      ? for shortcuts                                                                 Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: slashCommandEcho) == .idle)
    let slashCommandEchoWhileWorking = slashCommandEcho.replacing(
      "? for shortcuts   ", with: "esc to cancel     ")
    #expect(agent.detectState(in: slashCommandEchoWhileWorking) == .working)

    // Scrolled so the first row on screen is an echoed prompt whose rule
    // scrolled off: the echo plus its indented response is not a dialog.
    let echoAtTopOfScreen = """
      > 你好啊

        你好！今天有什么我可以帮你的吗？

      ────────────────────────────────────────────────────────────────────────────────────────────────────
      >
      ────────────────────────────────────────────────────────────────────────────────────────────────────
      ? for shortcuts                                                                 Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: echoAtTopOfScreen) == .idle)
  }

  @Test func slashCommandPopupKeepsThePriorState() throws {
    let agent = try agent()
    // Live 1.3.2: typing `/` opens an autocomplete popup below the composer
    // box with a selected option row and a `↑/↓ Navigate` hint, and the status
    // row reads `esc to cancel` even while idle. The box above the hint marks
    // it as the popup, not a dialog, and the state is unknown either way.
    let popupWhileIdle = """
        Prowl is a macOS orchestrator for running multiple coding agents.
      ────────────────────────────────────────────────────────────
      > /
      ────────────────────────────────────────────────────────────
      > /add-dir                 Add a directory to the workspace
        /agents                  List available custom agents
        /artifact                View and review artifacts
         ↓ 48 more
        ↑/↓ Navigate · enter Select · tab Complete
      esc to cancel                               Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: popupWhileIdle) == .unknown)
    let popupWhileWorking = """
      ────────────────────────────────────────────────────────────
      > Count from 1 to 60, one number per line, nothing else.
      ⡿  Working...
      ────────────────────────────────────────────────────────────
      > /
      ────────────────────────────────────────────────────────────
      > /add-dir                 Add a directory to the workspace
        /agents                  List available custom agents
        ↑/↓ Navigate · enter Select · tab Complete
      esc to cancel                               Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: popupWhileWorking) == .unknown)
    // The popup can outlive the message it filtered (`No matches` residue
    // under an empty composer, an echoed `> ` prompt within reach above it).
    let popupResidue = """
      ────────────────────────────────────────────────────────────
      > //clear
      ▸ Thought for 4s, 315 tokens
        Ready for your next task. How can I help you?
      ────────────────────────────────────────────────────────────
      >
      ────────────────────────────────────────────────────────────
         No matches
        ↑/↓ Navigate · enter Select · tab Complete
      esc to cancel                               Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: popupResidue) == .unknown)
    // Dismissing the popup restores the plain composer and its status row.
    let popupDismissed = """
      ────────────────────────────────────────────────────────────
      > //clear
      ▸ Thought for 4s, 315 tokens
        Ready for your next task. How can I help you?
      ────────────────────────────────────────────────────────────
      >
      ────────────────────────────────────────────────────────────
      ? for shortcuts                             Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: popupDismissed) == .idle)
  }

  @Test func typedDraftHidesTheStatusSignature() throws {
    let agent = try agent()
    // Live 1.3.2: any draft in the composer, one row or wrapped, drops
    // `? for shortcuts` from the status row; only the model label remains.
    let shortDraft = """
      ────────────────────────────────────────────────────────────
      > short draft
      ────────────────────────────────────────────────────────────
                                                  Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: shortDraft) == .unknown)
    let wrappedDraft = """
      ────────────────────────────────────────────────────────────
      > This is a long draft that should wrap inside the composer box because
        it keeps going so that it wraps onto continuation rows before I press
        enter. Reply with one word: ok
      ────────────────────────────────────────────────────────────
                                                  Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: wrappedDraft) == .unknown)
    let draftCleared = """
      ────────────────────────────────────────────────────────────
      >
      ────────────────────────────────────────────────────────────
      ? for shortcuts                             Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: draftCleared) == .idle)
  }

  @Test func unrecognizedDialogShapesFailTowardUnknown() throws {
    let agent = try agent()
    // A dialog whose hint copy is unrecognized is not read by option shape:
    // echoed prompts share that shape. It fails toward unknown, never Idle,
    // because the stacked box below cannot produce a padded status signature.
    let optionListWithUnrecognizedHint = """
      Requesting permission for:
         rm -rf build
      Run this command?
      > 1. Yes, run command
        2. No, cancel
        select with arrows and press enter
      esc to cancel
      ────────────────
      > ahead 2
      ────────────────
      ? for shortcuts custom help
      """
    #expect(agent.detectState(in: optionListWithUnrecognizedHint) == .unknown)

    // Live 1.3.2: a typed draft — even a numbered-looking line with a wrapped
    // continuation — leaves only the model label on the status row, so the
    // screen is unknown and the prior state is retained, never Blocked.
    let composerWithNumberedDraft = """
      ────────────────────────────────────
      > 1. first draft line
        2. wrapped continuation
      ────────────────────────────────────
                                                                  Gemini 3.1 Pro · high
      """
    #expect(agent.detectState(in: composerWithNumberedDraft) == .unknown)
    let echoedMultilinePrompt = """
      ────────────────────────────────────────────────────────────
      > Before doing anything else, use your ask-user question tool to ask me which color I prefer,
        offering exactly two options: red and blue. Wait for my answer.
      ▸ Thought for 3s, 203 tokens
      ────────────────────────────────────────────────────────────────────────────────────────────────────
      >
      ────────────────────────────────────────────────────────────────────────────────────────────────────
      esc to cancel                                                                Gemini 3.8 Flash · high
      """
    #expect(agent.detectState(in: echoedMultilinePrompt) == .working)
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
