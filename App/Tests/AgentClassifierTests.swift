import Darwin
import Testing

@testable import Prowl

struct AgentClassifierTests {
  @Test func identifiesDirectAgentProcessNames() {
    #expect(identifyAgent(processName: "pi") == .pi)
    #expect(identifyAgent(processName: "omp") == .omp)
    #expect(identifyAgent(processName: "oh-my-pi") == .omp)
    #expect(identifyAgent(processName: "claude") == .claude)
    #expect(identifyAgent(processName: "claude-code") == .claude)
    #expect(identifyAgent(processName: "codex") == .codex)
    #expect(identifyAgent(processName: "omx") == .codex)
    #expect(identifyAgent(processName: "oh-my-codex") == .codex)
    #expect(identifyAgent(processName: "gemini") == .gemini)
    #expect(identifyAgent(processName: "cursor") == .cursor)
    #expect(identifyAgent(processName: "cursor-agent") == .cursor)
    #expect(identifyAgent(processName: "cline") == .cline)
    #expect(identifyAgent(processName: "opencode") == .opencode)
    #expect(identifyAgent(processName: "open-code") == .opencode)
    #expect(identifyAgent(processName: "github-copilot") == .copilot)
    #expect(identifyAgent(processName: "ghcs") == .copilot)
    #expect(identifyAgent(processName: "kimi") == .kimi)
    #expect(identifyAgent(processName: "Kimi Code") == .kimi)
    #expect(identifyAgent(processName: "droid") == .droid)
    #expect(identifyAgent(processName: "amp") == .amp)
    #expect(identifyAgent(processName: "amp-local") == .amp)
    #expect(identifyAgent(processName: "qwen") == .qwen)
    #expect(identifyAgent(processName: "qodercli") == .qoder)
    #expect(identifyAgent(processName: "grok") == .grok)
    #expect(identifyAgent(processName: "grok-0.2.101-macos-aarch64") == .grok)
    // Model ids must not be treated as the install binary.
    #expect(identifyAgent(processName: "grok-4") == nil)
    #expect(identifyAgent(processName: "grok-4.5") == nil)
    #expect(identifyAgent(processName: "agy") == .antigravity)
    #expect(identifyAgent(processName: "antigravity-cli") == .antigravity)
    #expect(identifyAgent(processName: "antigravity_cli") == .antigravity)
    // The desktop IDE ships an `antigravity` launcher; only the CLI entrypoints map.
    #expect(identifyAgent(processName: "antigravity") == nil)
    #expect(identifyAgent(processName: "traecli") == .trae)
    #expect(identifyAgent(processName: "traex") == .trae)
    #expect(identifyAgent(processName: "trae-cli") == .trae)
    #expect(identifyAgent(processName: "trae-agent") == .trae)
    // The desktop IDE ships a `trae` launcher; only the CLI entrypoints map.
    #expect(identifyAgent(processName: "trae") == nil)
  }

  @Test func ignoresWrappedRuntimeWithTraeBinaryToken() {
    // traecli is a native executable; its name in a wrapper's argv is a quoted
    // prompt or install path, not the TUI. Only argv0/name evidence counts.
    for cmdline in [
      "node /tmp/app.js --model traecli",
      "bun /tmp/script.ts traecli",
    ] {
      let job = ForegroundJob(
        processGroupID: 42,
        processes: [
          ForegroundProcess(pid: 100, name: "node", argv0: "node", cmdline: cmdline)
        ]
      )
      #expect(identifyAgentInJob(job) == nil)
    }
  }

  @Test func identifiesGrokAgentAliasCommandLines() throws {
    // Production argv0 is basename-only; full path is cmdline's first token.
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

    let result = try #require(identifyAgentInJob(job))
    #expect(result.agent == .grok)
    #expect(result.name == "agent")
    // The shared `agent` name maps to the Cursor icon in CommandIconMap;
    // the icon token must resolve through the detected agent instead.
    #expect(result.iconLookupToken == "grok")
  }

  @Test func ignoresAgentProcessWithGrokModelArgument() {
    // Unrelated `agent` CLIs that merely take a grok model id must stay unknown.
    // Production-shaped: basename argv0, no `/.grok/` in the executable path.
    let job = ForegroundJob(
      processGroupID: 42,
      processes: [
        ForegroundProcess(
          pid: 100,
          name: "agent",
          argv0: "agent",
          cmdline: "/usr/local/bin/agent --model grok-4"
        )
      ]
    )
    #expect(identifyAgentInJob(job) == nil)
  }

  @Test func ignoresWrappedRuntimeWithGrokModelToken() {
    // Wrapped-runtime cmdline tokens are score-40 candidates; model ids —
    // bare `grok` included — must not flip the job to Grok.
    for cmdline in [
      "node /tmp/app.js --model grok-4.5",
      "node /tmp/app.js --model grok",
    ] {
      let job = ForegroundJob(
        processGroupID: 42,
        processes: [
          ForegroundProcess(pid: 100, name: "node", argv0: "node", cmdline: cmdline)
        ]
      )
      #expect(identifyAgentInJob(job) == nil)
    }
  }

  @Test func identifiesDirectGrokProcess() throws {
    let job = ForegroundJob(
      processGroupID: 42,
      processes: [
        ForegroundProcess(
          pid: 100,
          name: "grok",
          argv0: "grok",
          cmdline: "grok --always-approve"
        )
      ]
    )

    let result = try #require(identifyAgentInJob(job))
    #expect(result.agent == .grok)
    #expect(result.name == "grok")
  }

  @Test func identifiesVersionedGrokBinaryPath() throws {
    let job = ForegroundJob(
      processGroupID: 42,
      processes: [
        ForegroundProcess(
          pid: 100,
          name: "grok-0.2.101-macos-aarch64",
          argv0: "/Users/me/.grok/downloads/grok-0.2.101-macos-aarch64",
          cmdline: "/Users/me/.grok/downloads/grok-0.2.101-macos-aarch64"
        )
      ]
    )

    let result = try #require(identifyAgentInJob(job))
    #expect(result.agent == .grok)
  }

  @Test func identifiesOhMyPiCommandNames() throws {
    #expect(identifyAgent(processName: "omp") == .omp)
    #expect(identifyAgent(processName: "oh-my-pi") == .omp)

    let job = ForegroundJob(
      processGroupID: 42,
      processes: [
        ForegroundProcess(
          pid: 100,
          name: "bun",
          argv0: "bun",
          cmdline: "bun /opt/homebrew/bin/omp --model gpt-5"
        )
      ]
    )

    let result = try #require(identifyAgentInJob(job))
    #expect(result.agent == .omp)
    #expect(result.name == "omp")
    #expect(result.process.ref == .local(100))
  }

  @Test func identifiesCursorAgentAliasCommandLines() throws {
    let job = ForegroundJob(
      processGroupID: 42,
      processes: [
        ForegroundProcess(
          pid: 100,
          name: "agent",
          argv0: "/Users/onevcat/.local/bin/agent",
          cmdline: """
            /Users/onevcat/.local/bin/agent --use-system-ca \
            /Users/onevcat/.local/share/cursor-agent/versions/2026.05.09-0afadcc/index.js
            """
        )
      ]
    )

    let result = try #require(identifyAgentInJob(job))
    #expect(result.agent == .cursor)
    #expect(result.name == "agent")
    // Same icon either way ("agent" and "cursor" both map to the Cursor
    // asset); the token just resolves through the detected agent now.
    #expect(result.iconLookupToken == "cursor")
  }

  @Test func ignoresGenericAgentProcessWithoutCursorContext() {
    let job = ForegroundJob(
      processGroupID: 42,
      processes: [
        ForegroundProcess(
          pid: 100,
          name: "agent",
          argv0: "agent",
          cmdline: "agent --serve"
        )
      ]
    )

    #expect(identifyAgent(processName: "agent") == nil)
    #expect(identifyAgentInJob(job) == nil)
  }

  @Test func identifiesCursorAgentCommandLines() throws {
    let job = ForegroundJob(
      processGroupID: 42,
      processes: [
        ForegroundProcess(
          pid: 100,
          name: "node",
          argv0: "node",
          cmdline: "node /opt/homebrew/bin/cursor-agent"
        )
      ]
    )

    let result = try #require(identifyAgentInJob(job))
    #expect(result.agent == .cursor)
    #expect(result.name == "cursor-agent")
  }

  @Test func ignoresPlainShellsAndUnknownProcesses() {
    #expect(identifyAgent(processName: "zsh") == nil)
    #expect(identifyAgent(processName: "bash") == nil)
    #expect(identifyAgent(processName: "node") == nil)
    #expect(identifyAgent(processName: "vim") == nil)
  }

  @Test func identifiesWrappedRuntimeCommandLines() throws {
    let job = ForegroundJob(
      processGroupID: 42,
      processes: [
        ForegroundProcess(
          pid: 100,
          name: "node",
          argv0: "node",
          cmdline: "node /opt/homebrew/bin/codex --model gpt-5"
        )
      ]
    )

    let result = try #require(identifyAgentInJob(job))
    #expect(result.agent == .codex)
    #expect(result.name == "codex")
  }

  @Test func identifiesQoderCLIWrappedByNode() throws {
    let job = ForegroundJob(
      processGroupID: 42,
      processes: [
        ForegroundProcess(
          pid: 100,
          name: "node",
          argv0: "node",
          cmdline: "node /opt/homebrew/lib/node_modules/@qoder-ai/qodercli/bundle/qodercli.js"
        )
      ]
    )

    let result = try #require(identifyAgentInJob(job))
    #expect(result.agent == .qoder)
    #expect(result.name == "qodercli")
  }

  @Test func identifiesAnAgentNamedInsideOneArgumentOfTheJob() throws {
    // The production shape: `arguments` is always present (argv and cmdline come from
    // one read), and a shell or tmux carries the whole command in a single element.
    // `isWrappedRuntime` lists `sh`, `zsh`, and `tmux` for exactly these, so the words
    // inside an element must count — covered here because the other wrapped-runtime
    // tests pass `cmdline` only and so exercise a fallback production never takes.
    let argumentLists = [
      ["sh", "-c", "/opt/homebrew/bin/codex --model gpt-5"],
      ["tmux", "new-session", "-s", "work", "claude --resume"],
      ["zsh", "-lc", "gemini"],
    ]
    let expected: [DetectedAgent] = [.codex, .claude, .gemini]
    for (arguments, agent) in zip(argumentLists, expected) {
      let job = ForegroundJob(
        processGroupID: 42,
        processes: [
          ForegroundProcess(
            pid: 100, name: arguments[0], argv0: arguments[0],
            cmdline: arguments.joined(separator: " "), arguments: arguments
          )
        ]
      )
      let result = try #require(identifyAgentInJob(job), "\(arguments)")
      #expect(result.agent == agent, "\(arguments)")
    }
  }

  @Test func identifiesOmxAsCodexWrapper() throws {
    let job = ForegroundJob(
      processGroupID: 42,
      processes: [
        ForegroundProcess(
          pid: 100,
          name: "node",
          argv0: "node",
          cmdline: "node /opt/homebrew/bin/omx --madmax --high"
        )
      ]
    )

    let result = try #require(identifyAgentInJob(job))
    #expect(result.agent == .codex)
    #expect(result.name == "omx")
  }

  @Test func prefersDirectAgentProcessOverWrapper() throws {
    let job = ForegroundJob(
      processGroupID: 42,
      processes: [
        ForegroundProcess(pid: 100, name: "node", argv0: "node", cmdline: "node /tmp/codex"),
        ForegroundProcess(pid: 101, name: "claude", argv0: "claude", cmdline: "claude"),
      ]
    )

    let result = try #require(identifyAgentInJob(job))
    #expect(result.agent == .claude)
    #expect(result.name == "claude")
    #expect(result.process.ref == .local(101))
  }

  @Test func launchProcessIsTheTopmostJobAncestorOfTheIdentifiedProcess() throws {
    // Droid ≥ 0.202 forks its engine as a second `droid` process; `proc_listpids`
    // lists the newest member first, so the child is scanned before the launcher.
    let job = ForegroundJob(
      processGroupID: 100,
      processes: [
        ForegroundProcess(
          pid: 101,
          parentProcessID: 100,
          name: "droid",
          argv0: "droid",
          cmdline: "droid exec --input-format stream-jsonrpc --output-format stream-jsonrpc"
        ),
        ForegroundProcess(
          pid: 100,
          parentProcessID: 50,
          name: "droid",
          argv0: "droid",
          cmdline: "droid --settings /tmp/settings.json"
        ),
      ]
    )

    let result = try #require(identifyAgentInJob(job))
    #expect(result.agent == .droid)
    #expect(result.launchProcess == .local(100))
  }

  @Test func launchProcessIsTheIdentifiedProcessWhenItsParentIsOutsideTheJob() throws {
    let shellChild = ForegroundJob(
      processGroupID: 100,
      processes: [
        ForegroundProcess(pid: 100, parentProcessID: 50, name: "claude", argv0: "claude", cmdline: "claude")
      ]
    )
    #expect(try #require(identifyAgentInJob(shellChild)).launchProcess == .local(100))

    let unknownParent = ForegroundJob(
      processGroupID: 100,
      processes: [
        ForegroundProcess(pid: 100, name: "codex", argv0: "codex", cmdline: "codex")
      ]
    )
    #expect(try #require(identifyAgentInJob(unknownParent)).launchProcess == .local(100))
  }

  @Test func launchProcessWalkStopsOnACorruptParentCycle() {
    let job = ForegroundJob(
      processGroupID: 100,
      processes: [
        ForegroundProcess(pid: 101, parentProcessID: 100, name: "droid", argv0: "droid", cmdline: "droid"),
        ForegroundProcess(pid: 100, parentProcessID: 101, name: "droid", argv0: "droid", cmdline: "droid"),
      ]
    )
    #expect([ProcessRef.local(100), .local(101)].contains(job.launchProcess(of: .local(101))))
  }

  // MARK: - Launcher-hosted agents (Happy)

  /// Happy's own processes, shaped like the live job: the `happy` bin shim and the
  /// bundled entrypoint it re-executes, both in the pane's process group.
  private func happyJobProcesses(_ arguments: [String]) -> [ForegroundProcess] {
    let shim = ["node", "/opt/homebrew/bin/happy"] + arguments
    let dist =
      [
        "/opt/homebrew/Cellar/node/25.6.0/bin/node", "--no-warnings", "--no-deprecation",
        "/opt/homebrew/lib/node_modules/happy/dist/index.mjs",
      ] + arguments
    return [
      ForegroundProcess(
        pid: 3823, parentProcessID: 1766, name: "node", argv0: "node",
        cmdline: shim.joined(separator: " "), arguments: shim
      ),
      ForegroundProcess(
        pid: 3824, parentProcessID: 3823, name: "node", argv0: "node",
        cmdline: dist.joined(separator: " "), arguments: dist
      ),
    ]
  }

  /// The out-of-job chain Happy starts: its per-session launcher script and, under
  /// it, the engine. Happy spawns the engine by absolute path, so argv0 carries the
  /// packaged binary name (`claude.exe`) rather than the `claude` a shell would pass.
  private func happyHostedClaude() -> [ForegroundProcess] {
    let engine = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
    return [
      ForegroundProcess(
        pid: 3829, parentProcessID: 3824, name: "node", argv0: "node",
        cmdline: "node /opt/homebrew/lib/node_modules/happy/scripts/claude_local_launcher.cjs",
        arguments: ["node", "/opt/homebrew/lib/node_modules/happy/scripts/claude_local_launcher.cjs"]
      ),
      ForegroundProcess(
        pid: 3831, parentProcessID: 3829, name: "claude.exe", argv0: engine,
        cmdline: engine, arguments: [engine]
      ),
    ]
  }

  @Test func identifiesTheEngineHappyRunsOutsideTheJob() throws {
    let job = ForegroundJob(
      processGroupID: 3823,
      processes: happyJobProcesses(["--resume", "--dangerously-skip-permissions"]),
      hosted: happyHostedClaude()
    )

    let result = try #require(identifyAgentInJob(job))
    #expect(result.agent == .claude)
    // The engine's own pid, not Happy's: this is what native state and session
    // lookup read, so detection must publish it.
    #expect(result.process.ref == .local(3831))
    // The launch is still the job member the shell started, so relaunching Happy
    // reads as a new launch rather than an engine replacement.
    #expect(result.launchProcess == .local(3823))
    #expect(result.iconLookupToken == "claude")
  }

  @Test func normalizesThePackagedExecutableSuffix() throws {
    // Claude Code ships `bin/claude.exe` on macOS too, so any spawn by absolute
    // path — a launcher's, or a script's — carries that name instead of `claude`.
    let binary = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
    let job = ForegroundJob(
      processGroupID: 100,
      processes: [
        ForegroundProcess(
          pid: 100, name: "claude.exe", argv0: binary, cmdline: binary, arguments: [binary]
        )
      ]
    )

    let result = try #require(identifyAgentInJob(job))
    #expect(result.agent == .claude)
    #expect(result.name == "claude")
  }

  /// An agent packaged as pure JavaScript, in the shape the kernel reports: a node
  /// shebang script runs inside node, so `argv0` and the comm name are both `node` and
  /// only the script names the agent. Verified against a live `#!/usr/bin/env node`
  /// process (`comm=node`, `argv=node /path/to/script`).
  private func hostedScriptAgent(_ binary: String, pid: pid_t = 3831, parent: pid_t = 3824)
    -> ForegroundProcess
  {
    let argv = ["node", "/opt/homebrew/bin/\(binary)"]
    return ForegroundProcess(
      pid: pid, parentProcessID: parent, name: "node", argv0: "node",
      cmdline: argv.joined(separator: " "), arguments: argv
    )
  }

  @Test func identifiesAnyHostedRuntimeFromItsOwnEvidence() throws {
    // No table of launcher subcommands: the engine names itself. Each case passes the
    // launcher argv the user actually typed, so a subcommand that names the runtime
    // (`happy codex`) is covered alongside one that does not (`happy resume <id>`) —
    // and the engine's pid must win in both. The hosted process is a node script,
    // which is how gemini, qwen, cline, copilot, and amp actually run.
    struct Launch {
      let launcher: [String]
      let binary: String
      let expected: DetectedAgent
    }
    let cases = [
      Launch(launcher: ["codex"], binary: "codex", expected: .codex),
      Launch(launcher: ["gemini"], binary: "gemini", expected: .gemini),
      Launch(launcher: ["acp", "opencode", "--verbose"], binary: "opencode", expected: .opencode),
      Launch(launcher: ["acp", "--", "opencode", "--acp"], binary: "opencode", expected: .opencode),
      Launch(launcher: ["resume", "cmmij8"], binary: "claude", expected: .claude),
      Launch(launcher: [], binary: "claude", expected: .claude),
    ]
    for (launcher, binary, expected) in cases.map({ ($0.launcher, $0.binary, $0.expected) }) {
      let label = "happy \(launcher.joined(separator: " "))"
      let job = ForegroundJob(
        processGroupID: 3823,
        processes: happyJobProcesses(launcher),
        hosted: [hostedScriptAgent(binary)]
      )
      let result = try #require(identifyAgentInJob(job), "\(label)")
      #expect(result.agent == expected, "\(label)")
      // The engine's own pid. A launcher subcommand naming the runtime must not pin
      // the pane to the launcher's pid, or native state and session lookup — which
      // read this pid — would both look at Happy instead of the agent.
      #expect(result.process.ref == .local(3831), "\(label)")
    }
  }

  @Test func prefersTheBestEvidencedProcessOfAHostedAgent() throws {
    // `codex` is a node script that spawns a native binary, and it is the native
    // process that holds the session file open. The published pid is what session
    // resolution and native state read, so the script's pid would find nothing.
    let native = "/opt/homebrew/lib/node_modules/@openai/codex-darwin-arm64/vendor/bin/codex"
    let job = ForegroundJob(
      processGroupID: 3823,
      processes: happyJobProcesses(["codex"]),
      hosted: [
        hostedScriptAgent("codex", pid: 3831),
        ForegroundProcess(
          pid: 3840, parentProcessID: 3831, name: "codex", argv0: native, cmdline: native,
          arguments: [native]
        ),
      ]
    )

    let result = try #require(identifyAgentInJob(job))
    #expect(result.agent == .codex)
    #expect(result.process.ref == .local(3840))
  }

  @Test func managedCodexDaemonDoesNotDisplaceTheHostedEngine() throws {
    // Codex 0.157+ runs every thread's shell commands in a shared `app-server
    // --managed-daemon`, whose environment and ancestry belong to whichever process
    // last started it. It is named `codex` by its own argv0 — the same agent, the same
    // score as the engine — so only "shallower wins at equal evidence" keeps it from
    // taking the pane, and that depends on the walk's breadth order.
    let native = "/opt/homebrew/lib/node_modules/@openai/codex-darwin-arm64/vendor/bin/codex"
    let job = ForegroundJob(
      processGroupID: 3823,
      processes: happyJobProcesses(["codex"]),
      hosted: [
        ForegroundProcess(
          pid: 3831, parentProcessID: 3824, name: "codex", argv0: native, cmdline: native,
          arguments: [native]
        ),
        ForegroundProcess(
          pid: 3840, parentProcessID: 3831, name: "codex", argv0: native,
          cmdline: "\(native) app-server --managed-daemon",
          arguments: [native, "app-server", "--managed-daemon"]
        ),
      ]
    )

    let result = try #require(identifyAgentInJob(job))
    #expect(result.agent == .codex)
    #expect(result.process.ref == .local(3831))
  }

  @Test func ignoresADifferentAgentBelowTheHostedOne() throws {
    // An agent spawns its own work, and `claude mcp serve` is a documented way to do
    // it. That claude is strongly named and deeper; the shallower gemini is the
    // session Happy started and must keep the pane.
    let served = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
    let job = ForegroundJob(
      processGroupID: 3823,
      processes: happyJobProcesses(["gemini"]),
      hosted: [
        hostedScriptAgent("gemini", pid: 3831),
        ForegroundProcess(
          pid: 3840, parentProcessID: 3831, name: "claude.exe", argv0: served,
          cmdline: "\(served) mcp serve", arguments: [served, "mcp", "serve"]
        ),
      ]
    )

    let result = try #require(identifyAgentInJob(job))
    #expect(result.agent == .gemini)
    #expect(result.process.ref == .local(3831))
  }

  @Test func ignoresWhatALauncherWasAskedToStart() {
    // A launcher's remaining arguments name another process's work. Without a hosted
    // engine there is nothing running here to detect, so the pane stays empty rather
    // than claiming the launcher's pid.
    for launcher in [["codex"], ["gemini"], ["acp", "opencode"]] {
      let job = ForegroundJob(processGroupID: 3823, processes: happyJobProcesses(launcher))
      #expect(identifyAgentInJob(job) == nil, "happy \(launcher.joined(separator: " "))")
    }
  }

  @Test func ignoresPayloadTokensInAHostedShim() {
    // Happy's per-session shim carries a `--mcp-config` JSON blob and a prompt file.
    // A token in one of those must not let the shim outrank the engine below it,
    // whatever the blob's spacing or quoting turns out to be.
    let engine = "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
    let payloads = [
      #"{"mcpServers": {"x": {"command": "/opt/homebrew/bin/codex"}}}"#,
      "/opt/homebrew/bin/codex",
      "run codex mcp serve",
      "--model grok-4",
    ]
    for payload in payloads {
      let shim = ["node", "/x/happy/scripts/claude_local_launcher.cjs", "--mcp-config", payload]
      let job = ForegroundJob(
        processGroupID: 3823,
        processes: happyJobProcesses([]),
        hosted: [
          ForegroundProcess(
            pid: 3829, parentProcessID: 3824, name: "node", argv0: "node",
            cmdline: shim.joined(separator: " "), arguments: shim
          ),
          ForegroundProcess(
            pid: 3831, parentProcessID: 3829, name: "claude.exe", argv0: engine, cmdline: engine,
            arguments: [engine]
          ),
        ]
      )
      let result = identifyAgentInJob(job)
      #expect(result?.agent == .claude, "payload: \(payload)")
      #expect(result?.process.ref == .local(3831), "payload: \(payload)")
    }
  }

  @Test func reportsNoAgentWhenALauncherHostsNone() {
    // `happy daemon start-sync` and the other non-session subcommands start no
    // engine, so the walk finds nothing to name.
    let job = ForegroundJob(
      processGroupID: 3360,
      processes: happyJobProcesses(["daemon", "start-sync"]),
      hosted: [
        ForegroundProcess(
          pid: 3375, parentProcessID: 3824, name: "caffeinate", argv0: "caffeinate",
          cmdline: "caffeinate -i", arguments: ["caffeinate", "-i"]
        )
      ]
    )
    #expect(identifyAgentInJob(job) == nil)
  }

  @Test func prefersAnInJobAgentOverAHostedOne() throws {
    let job = ForegroundJob(
      processGroupID: 3823,
      processes: happyJobProcesses([])
        + [
          ForegroundProcess(
            pid: 3840, parentProcessID: 3823, name: "codex", argv0: "codex", cmdline: "codex",
            arguments: ["codex"]
          )
        ],
      hosted: happyHostedClaude()
    )

    let result = try #require(identifyAgentInJob(job))
    #expect(result.agent == .codex)
    #expect(result.process.ref == .local(3840))
  }

  @Test func prefersTheHostedAgentNearestTheLauncher() throws {
    // The engine spawns its own work — a subagent, a tool, even another CLI. Those
    // are deeper than the engine and must never take the pane's identity from it.
    let job = ForegroundJob(
      processGroupID: 3823,
      processes: happyJobProcesses([]),
      hosted: happyHostedClaude()
        + [
          ForegroundProcess(
            pid: 3850, parentProcessID: 3831, name: "codex", argv0: "codex", cmdline: "codex exec",
            arguments: ["codex", "exec"]
          )
        ]
    )

    let result = try #require(identifyAgentInJob(job))
    #expect(result.agent == .claude)
    #expect(result.process.ref == .local(3831))
  }

  @Test func launchProcessOfAHostedEngineResolvesThroughItsOutOfJobAncestors() {
    let job = ForegroundJob(
      processGroupID: 3823,
      processes: happyJobProcesses([]),
      hosted: happyHostedClaude()
    )
    // 3831 -> 3829 (hosted) -> 3824 (job) -> 3823 (job), whose parent is the shell.
    #expect(job.launchProcess(of: .local(3831)) == .local(3823))
    #expect(job.allProcesses.count == 4)
  }

  @Test func recognizesHappyEntrypointsAndOnlyThose() {
    func process(_ arguments: [String], name: String = "node") -> ForegroundProcess {
      ForegroundProcess(
        pid: 1, name: name, argv0: arguments.first, cmdline: arguments.joined(separator: " "),
        arguments: arguments
      )
    }

    #expect(AgentLauncher.hostsAgentsOutsideJob(process(["node", "/opt/homebrew/bin/happy"])))
    #expect(
      AgentLauncher.hostsAgentsOutsideJob(process(["node", "--no-warnings", "/x/node_modules/happy/dist/index.mjs"])))
    #expect(
      AgentLauncher.hostsAgentsOutsideJob(
        process(["node", "/Users/me/.bun/install/global/node_modules/happy-coder/dist/index.mjs"])))
    // Happy as the executable itself, with no wrapped runtime in front of it.
    #expect(AgentLauncher.hostsAgentsOutsideJob(process(["/opt/homebrew/bin/happy", "--yolo"], name: "happy")))

    // A later token that merely says `happy` is a word in a payload, not an
    // entrypoint, so nothing is expanded and no agent can be invented.
    #expect(!AgentLauncher.hostsAgentsOutsideJob(process(["node", "/tmp/app.js", "--prompt", "happy"])))
    #expect(!AgentLauncher.hostsAgentsOutsideJob(process(["node", "/tmp/app.js", "happy"])))
    #expect(!AgentLauncher.hostsAgentsOutsideJob(process(["bun", "/tmp/s.ts", "--name", "happy-coder"])))
    #expect(!AgentLauncher.hostsAgentsOutsideJob(process(["claude"], name: "claude")))
  }
}
