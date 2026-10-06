import Foundation
import ProwlCLIShared
import Testing

@testable import Prowl

struct DevinSupportTests {
  @Test func composerReadsWrappedDraftsAndRejectsMenus() {
    let draft = AgentScreenSnapshot(
      text: """
        ────────────────────────────────────────
        ❭ first line
          second line
        ────────────────────────────────────────
        SWE-1.6 Slow        Context: 18k / 200k tokens (9%)
        """)
    #expect(DevinScreenProfile.composerContents(in: draft) == "first line\nsecond line")
    let idle = AgentScreenSnapshot(
      text: """
        ────────────────────────────────────────
        ❭ Ask Devin to build features, fix bugs, or work on your code
        ────────────────────────────────────────
        SWE-1.6 Slow
        """)
    #expect(DevinScreenProfile.composerContents(in: idle) == "")
    #expect(
      DevinScreenProfile.composerContents(in: .init(text: "❭ 1 Yes\n↑↓ select · esc cancel")) == nil
    )
  }

  private func agent() throws -> DetectedAgent {
    try #require(DetectedAgent(rawValue: "devin"))
  }

  @Test func recognizesNativeProcessAndPrefersItsSessionOwner() throws {
    let expected = try agent()
    #expect(identifyAgent(processName: "Devin") == expected)
    let parent = ForegroundProcess(pid: 100, name: "devin", argv0: "devin", cmdline: "/bin/devin")
    let child = ForegroundProcess(
      pid: 101, parentProcessID: 100, name: "devin", argv0: "devin", cmdline: "/bin/devin acp")
    for processes in [[parent, child], [child, parent]] {
      let identified = try #require(
        identifyAgentInJob(ForegroundJob(processGroupID: 100, processes: processes)))
      #expect(identified.agent == expected)
      #expect(identified.process.pid == 101)
      #expect(identified.launchProcessID == 100)
    }
    #expect(identifyAgent(processName: "devin-model") == nil)
    let unrelated = ForegroundProcess(
      pid: 102, name: "node", argv0: "node", cmdline: "node app.js --model devin")
    #expect(identifyAgentInJob(ForegroundJob(processGroupID: 102, processes: [unrelated])) == nil)
  }

  @Test func launchUsesPromptSeparatorAndExplicitPermissions() throws {
    let runtime = try #require(AgentProfileRuntime(rawValue: "devin"))
    let prompt = "--model is task text\nnot an option"
    let options = ["--model", "swe-1-6-slow", "--permission-mode", "auto"]
    for (intent, suffix) in [
      (AgentStartIntent.interactive, []),
      (.prompt(prompt), ["--", prompt]),
      (.headless(prompt), ["--print", "--", prompt]),
    ] {
      let invocation = try AgentRuntimeAdapterRegistry.makeStartInvocation(
        AgentStartRequest(
          runtime: runtime, intent: intent, configuration: .init(model: "swe-1-6-slow")))
      #expect(invocation.executable == "devin")
      #expect(invocation.arguments == options + suffix)
    }
    let unrestricted = try AgentRuntimeAdapterRegistry.makeStartInvocation(
      AgentStartRequest(
        runtime: runtime, intent: .interactive, configuration: .init(executionMode: .unrestricted)))
    #expect(unrestricted.arguments == ["--permission-mode", "dangerous"])
    let adapter = try #require(AgentRuntimeAdapterRegistry.profileAdapter(for: runtime))
    #expect(!adapter.supportsAccountIsolation)
    #expect(!adapter.supportsReasoningEffort)
    #expect(runtime.defaultHomeDirectoryName == ".config/devin")
  }

  @Test func observesOnlyOptionsBeforePrompt() throws {
    let runtime = try #require(AgentProfileRuntime(rawValue: "devin"))
    let observation = AgentRuntimeAdapterRegistry.observe(
      runtime: runtime,
      arguments: [
        "devin", "--model", "swe-1-6-slow", "--permission-mode", "auto", "--", "--model", "wrong",
      ])
    #expect(observation.model == "swe-1-6-slow")
    #expect(observation.executionMode == .standard)
    #expect(
      AgentRuntimeAdapterRegistry.observe(runtime: runtime, arguments: ["devin"]).executionMode
        == nil)
  }

  @Test func screenStatesUseLiveComposerAndDialogRegions() throws {
    let agent = try agent()
    let idle = """
      DONE
      ────────────────────────────────────────
      ❭ Ask Devin to build features, fix bugs, or work on your code
      ────────────────────────────────────────
      SWE-1.6 Slow        Context: 18k / 200k tokens (9%)
      """
    #expect(agent.detectState(in: idle) == .idle)
    for phase in ["Thinking", "Running tools", "Typing"] {
      let working = """
        ⡆⠀ \(phase) · 3s (esc twice to interrupt)
        ────────────────────────────────────────
        ❭ Guide Devin while it works
        ────────────────────────────────────────
        SWE-1.6 Slow        Context: 18k / 200k tokens (9%)
        """
      #expect(agent.detectState(in: working) == .working)
      #expect(agent.detectScreen(in: working).reason.identifier == "devin.workingFooter")
      #expect(agent.detectState(in: working + "\n" + idle) == .idle)
    }
    let trust = """
      ✱ Do you trust the authors of this directory?
      For security, devin should not be run in directories with untrusted content.
      /tmp/example
      ❭ 1 Yes, trust
        2 No, exit
      ↓↑ to select · ↵ to choose · esc to quit
      """
    #expect(agent.detectState(in: trust) == .blocked)
    #expect(agent.detectScreen(in: trust).reason.identifier == "devin.directoryTrust")
    #expect(agent.detectState(in: trust + "\n" + idle) == .idle)
    let permission = """
      ● Running command
      └ $ echo test
      ❭ 1 Yes  (Approve once)
        2 Yes, and don't ask again
        3 No
      ↑↓ to navigate · enter to select · esc to cancel
      """
    #expect(agent.detectState(in: permission) == .blocked)
    #expect(agent.detectState(in: permission + "\n" + idle) == .idle)
    #expect(agent.detectState(in: "The output says Thinking and Running tools.") == .idle)
  }

  @Test func sessionOwnershipUsesOnlyOpenLockPaths() throws {
    let profile = AgentSessionProfile.profile(for: try agent())
    let root = "/Users/test/.local/share/devin/cli"
    let session = try #require(profile.parsePath(root + "/session_locks/sordid-pheasant.lock"))
    #expect(session.id == "sordid-pheasant")
    #expect(session.transcriptPath?.path == root + "/transcripts/sordid-pheasant.json")
    #expect(profile.parsePath(root + "/transcripts/sordid-pheasant.json") == nil)
    #expect(profile.parsePath(root + "/session_locks/.lock") == nil)
    #expect(profile.parsePath(root + "/session_locks/nested/other.lock") == nil)
    #expect(profile.candidateRoots(URL(filePath: "/Users/test"), nil, Date(), Date()).isEmpty)
  }

  @Test func workflowBindsDevinThroughTheExistingProfilePath() throws {
    let runtime = try #require(AgentProfileRuntime(rawValue: "devin"))
    let profile = AgentProfile(name: "Devin", runtime: runtime)
    for agents: [String]? in [nil, ["devin"]] {
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
