import Foundation
import ProwlCLIShared
import Testing

@testable import Prowl

struct CodexDaemonOptOutTests {
  @Test(arguments: [
    ("codex-cli 0.156.0", true),
    ("codex-cli 0.162.1\n", true),
    ("codex-cli 0.163.0-alpha.11", true),
    ("codex-cli 1.0.0", true),
    ("codex-cli 0.155.9", false),
    ("codex-cli 0.153.2", false),
    ("codex-cli", false),
    ("", false),
    ("codex-cli 0.162", false),
  ])
  func versionGate(output: String, supported: Bool) {
    #expect(CodexDaemonOptOut.isSupported(versionOutput: output) == supported)
  }

  @Test func insertsTheFlagBeforeThePromptAndShiftsItsIndex() {
    let invocation = AgentInvocation(executable: "codex", arguments: ["--model", "gpt", "Prompt"])

    let result = CodexDaemonOptOut.applying(to: invocation, promptArgumentIndex: 2)

    #expect(result.invocation.arguments == ["--model", "gpt", "--no-daemon", "Prompt"])
    #expect(result.promptArgumentIndex == 3)
  }

  @Test func insertsTheFlagBeforeTheSentinel() {
    let invocation = AgentInvocation(executable: "codex", arguments: ["--", "-literal"])

    let result = CodexDaemonOptOut.applying(to: invocation, promptArgumentIndex: nil)

    #expect(result.invocation.arguments == ["--no-daemon", "--", "-literal"])
    #expect(result.promptArgumentIndex == nil)
  }

  @Test func appliesOnlyToTheInteractiveTUI() {
    #expect(CodexDaemonOptOut.applies(to: [], promptArgumentIndex: nil))
    #expect(CodexDaemonOptOut.applies(to: ["Prompt"], promptArgumentIndex: 0))
    #expect(CodexDaemonOptOut.applies(to: ["resume", "--last"], promptArgumentIndex: nil))
    #expect(CodexDaemonOptOut.applies(to: ["fork", "--last"], promptArgumentIndex: nil))
    #expect(!CodexDaemonOptOut.applies(to: ["exec", "Prompt"], promptArgumentIndex: 1))
    #expect(!CodexDaemonOptOut.applies(to: ["--no-daemon", "Prompt"], promptArgumentIndex: 1))
    #expect(CodexDaemonOptOut.applies(to: ["--", "--no-daemon"], promptArgumentIndex: nil))
  }

  /// Generated model, effort, and mode options come before a profile's extra arguments, so the
  /// subcommand can follow options (review R1-001).
  @Test(arguments: [
    ["--model", "gpt-5", "exec", "Prompt"],
    ["--model", "gpt-5", "-c", "model_reasoning_effort=high", "e", "Prompt"],
    ["--dangerously-bypass-approvals-and-sandbox", "review", "Prompt"],
    ["-m", "gpt-5", "apply", "Prompt"],
  ])
  func optionsBeforeANonInteractiveSubcommandSkipTheFlag(arguments: [String]) {
    #expect(!CodexDaemonOptOut.applies(to: arguments, promptArgumentIndex: arguments.count - 1))
  }

  @Test func optionsBeforeAnInteractiveSubcommandKeepTheFlag() {
    #expect(CodexDaemonOptOut.applies(to: ["--model", "gpt-5", "resume", "--last"], promptArgumentIndex: nil))
    #expect(CodexDaemonOptOut.applies(to: ["--model", "gpt-5", "fork", "--last"], promptArgumentIndex: nil))
    #expect(CodexDaemonOptOut.applies(to: ["--model", "gpt-5", "exec"], promptArgumentIndex: 2))
  }

  /// Review R2-001: an option value that spells a subcommand is not a subcommand.
  @Test(arguments: [
    ["--cd", "app", "Prompt"],
    ["-C", "app", "Prompt"],
    ["--add-dir", "review", "--cd", "debug", "Prompt"],
    ["-m", "exec", "-s", "workspace-write", "Prompt"],
  ])
  func optionValuesThatSpellASubcommandKeepTheFlag(arguments: [String]) {
    #expect(CodexDaemonOptOut.applies(to: arguments, promptArgumentIndex: arguments.count - 1))
  }

  /// Review R3-001: an existing opt-out after `resume` / `fork` must not be duplicated.
  @Test(
    arguments: [
      (["resume", "--last", "--no-daemon"], nil),
      (["fork", "--last", "--no-daemon"], nil),
      (["--model", "gpt-5", "resume", "--last", "--no-daemon", "Prompt"], 5),
      (["-m", "gpt-5", "fork", "--no-daemon", "--last", "Prompt"], 5),
    ] as [([String], Int?)])
  func anExistingOptOutAfterAnInteractiveSubcommandIsKept(arguments: [String], promptIndex: Int?) {
    #expect(!CodexDaemonOptOut.applies(to: arguments, promptArgumentIndex: promptIndex))
    let invocation = AgentInvocation(executable: "codex", arguments: arguments)
    #expect(CodexDaemonOptOut.applying(to: invocation, promptArgumentIndex: promptIndex).invocation == invocation)
  }

  @Test func aPromptThatSpellsTheFlagDoesNotCountAsAnOptOut() {
    #expect(CodexDaemonOptOut.applies(to: ["resume", "--last", "--no-daemon"], promptArgumentIndex: 2))
  }

  @Test func aSubcommandAfterADirectoryOptionStillSkipsTheFlag() {
    #expect(!CodexDaemonOptOut.applies(to: ["--cd", "app", "exec", "Prompt"], promptArgumentIndex: 3))
    #expect(!CodexDaemonOptOut.applies(to: ["-C", "app", "review", "Prompt"], promptArgumentIndex: 3))
  }
}

@Suite(.serialized) struct CodexDaemonOptOutPreparationTests {
  private static let prompt = "Prompt"

  private func plan(arguments: [String] = [prompt]) -> AgentProfileLaunchPlan {
    AgentProfileLaunchPlan(
      profileID: UUID(),
      profileName: "Codex",
      runtime: .codex,
      invocation: AgentInvocation(executable: "codex", arguments: arguments),
      commandEnvironment: [],
      placement: .tab,
      splitDirection: .right,
      surfaceEnvironment: [AgentProfileLaunchPlanner.promptCarrierName: Self.prompt],
      dedicatedHome: nil
    )
  }

  private func prepare(
    plan: AgentProfileLaunchPlan,
    root: URL,
    executable: URL,
    version: String?,
    versionQueries: QueryCounter = QueryCounter()
  ) async -> AgentManagedHookPreparation {
    await AgentManagedHookPreparer.prepare(
      plan: plan,
      inheritedCWD: root,
      resources: AgentHookResources(bundledCLIPath: "/usr/bin/true", socketPath: "/tmp/prowl-test.sock"),
      codexShellEnvironment: CodexShellLaunchEnvironment(
        executableURL: executable,
        processEnvironment: ["HOME": root.path(percentEncoded: false), "CODEX_HOME": root.path(percentEncoded: false)]
      ),
      codexConfigReadProcess: CodexConfigReadProcess(temporaryBaseDirectory: root, timeout: 15),
      codexVersionQuery: { _ in
        await versionQueries.increment()
        return version
      }
    )
  }

  @Test func preparedLaunchOptsOutBeforeTheManagedNotifier() async throws {
    let root = try temporaryDirectory("codex-opt-out-prepared")
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try fakeCodex(in: root)

    let preparation = await prepare(plan: plan(), root: root, executable: executable, version: "codex-cli 0.162.1")

    let prepared = try #require(preparation.preparedInvocation)
    #expect(preparation.warning == nil)
    #expect(prepared.invocation.arguments == ["--no-daemon", "-c", "notify=[]", Self.prompt])
    #expect(prepared.argumentValues.keys.sorted() == [2])
    #expect(preparation.fallbackInvocation?.arguments == ["--no-daemon", Self.prompt])
  }

  @Test func degradedLaunchStillOptsOut() async throws {
    let root = try temporaryDirectory("codex-opt-out-degraded")
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = root.appending(path: "missing-codex", directoryHint: .notDirectory)

    let preparation = await prepare(plan: plan(), root: root, executable: missing, version: "codex-cli 0.162.1")

    #expect(preparation.preparedInvocation == nil)
    #expect(preparation.warning?.code == .managedHookDegraded)
    #expect(
      preparation.fallbackInvocation == AgentInvocation(executable: "codex", arguments: ["--no-daemon", Self.prompt]))
  }

  @Test func degradedLaunchWithADirectoryNamedLikeASubcommandStillOptsOut() async throws {
    let root = try temporaryDirectory("codex-opt-out-degraded-cd")
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = root.appending(path: "missing-codex", directoryHint: .notDirectory)
    let counter = QueryCounter()

    let preparation = await prepare(
      plan: plan(arguments: ["--cd", "app", Self.prompt]), root: root, executable: missing,
      version: "codex-cli 0.162.1", versionQueries: counter)

    #expect(await counter.count == 1)
    #expect(preparation.warning?.code == .managedHookDegraded)
    #expect(preparation.fallbackInvocation?.arguments == ["--cd", "app", "--no-daemon", Self.prompt])
  }

  @Test(arguments: ["codex-cli 0.155.0", nil] as [String?])
  func unsupportedOrUnknownVersionKeepsTheArguments(version: String?) async throws {
    let root = try temporaryDirectory("codex-opt-out-unsupported")
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try fakeCodex(in: root)

    let preparation = await prepare(plan: plan(), root: root, executable: executable, version: version)

    let prepared = try #require(preparation.preparedInvocation)
    #expect(prepared.invocation.arguments == ["-c", "notify=[]", Self.prompt])
    #expect(preparation.fallbackInvocation == nil)
  }

  @Test func headlessLaunchSkipsTheVersionProbe() async throws {
    let root = try temporaryDirectory("codex-opt-out-headless")
    defer { try? FileManager.default.removeItem(at: root) }
    let executable = try fakeCodex(in: root)
    let counter = QueryCounter()

    let preparation = await prepare(
      plan: plan(arguments: ["exec", Self.prompt]), root: root, executable: executable,
      version: "codex-cli 0.162.1", versionQueries: counter)

    #expect(await counter.count == 0)
    #expect(preparation.fallbackInvocation == nil)
    #expect(preparation.preparedInvocation?.invocation.arguments.contains("--no-daemon") == false)
  }

  /// Answers `config/read` with no notifier and stays open, like Codex's app server.
  private func fakeCodex(in root: URL) throws -> URL {
    let executable = root.appending(path: "codex", directoryHint: .notDirectory)
    try """
    #!/bin/sh
    for request in 1 2 3; do
      IFS= read -r line || exit 1
    done
    printf '%s\\n' '{"id":2,"result":{"config":{}}}'
    while IFS= read -r line; do :; done
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
  }

  private func temporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

actor QueryCounter {
  private(set) var count = 0

  func increment() {
    count += 1
  }
}
