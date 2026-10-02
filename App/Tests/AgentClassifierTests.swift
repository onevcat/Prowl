import Testing

@testable import supacode

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
    #expect(result.process.pid == 100)
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
    #expect(result.process.pid == 101)
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
    #expect(result.launchProcessID == 100)
  }

  @Test func launchProcessIsTheIdentifiedProcessWhenItsParentIsOutsideTheJob() throws {
    let shellChild = ForegroundJob(
      processGroupID: 100,
      processes: [
        ForegroundProcess(pid: 100, parentProcessID: 50, name: "claude", argv0: "claude", cmdline: "claude")
      ]
    )
    #expect(try #require(identifyAgentInJob(shellChild)).launchProcessID == 100)

    let unknownParent = ForegroundJob(
      processGroupID: 100,
      processes: [
        ForegroundProcess(pid: 100, name: "codex", argv0: "codex", cmdline: "codex")
      ]
    )
    #expect(try #require(identifyAgentInJob(unknownParent)).launchProcessID == 100)
  }

  @Test func launchProcessWalkStopsOnACorruptParentCycle() {
    let job = ForegroundJob(
      processGroupID: 100,
      processes: [
        ForegroundProcess(pid: 101, parentProcessID: 100, name: "droid", argv0: "droid", cmdline: "droid"),
        ForegroundProcess(pid: 100, parentProcessID: 101, name: "droid", argv0: "droid", cmdline: "droid"),
      ]
    )
    #expect([100, 101].contains(job.launchProcessID(of: 101)))
  }
}
