import Testing

@testable import supacode

struct AgentClassifierTests {
  @Test func identifiesDirectAgentProcessNames() {
    #expect(identifyAgent(processName: "pi") == .pi)
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
    #expect(identifyAgent(processName: "grok") == .grok)
  }

  @Test func identifiesGrokAgentAliasCommandLines() throws {
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
    #expect(result.iconLookupToken == "grok")
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

  @Test func identifiesOhMyPiCommandNames() throws {
    #expect(identifyAgent(processName: "omp") == .pi)
    #expect(identifyAgent(processName: "oh-my-pi") == .pi)

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
    #expect(result.agent == .pi)
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
  }

  @Test func ignoresGenericAgentProcessWithoutCursorContext() {
    #expect(identifyAgent(processName: "agent") == nil)
    for cmdline in ["agent --serve", "/usr/local/bin/agent --model grok"] {
      let job = ForegroundJob(
        processGroupID: 42,
        processes: [
          ForegroundProcess(pid: 100, name: "agent", argv0: "agent", cmdline: cmdline)
        ]
      )
      #expect(identifyAgentInJob(job) == nil)
    }
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

  @Test func ignoresGrokTokensPassedToWrappedRuntimes() {
    for cmdline in [
      "node /tmp/tool --model grok",
      "node /tmp/tool --model grok-4.5",
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
}
