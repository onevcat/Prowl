import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

/// S3c injects Prowl's bundled extensions into Pi (`-e`), Oh My Pi (`--hook`), and OpenCode
/// (`OPENCODE_CONFIG_CONTENT`), measured on Pi 0.84.3, Oh My Pi 18.0.6, and OpenCode 1.18.23
/// (docs-ai 064.010).
struct AgentS3cHookRenderingTests {
  private let piExtension = "/Applications/Prowl Debug.app/Contents/Resources/agent-hooks/pi/prowl-hooks.ts"
  private let ompExtension = "/Applications/Prowl.app/Contents/Resources/agent-hooks/omp/prowl-hooks.ts"
  private let opencodePlugin = "/Applications/Prowl.app/Contents/Resources/agent-hooks/opencode/prowl-hooks.ts"

  // MARK: - Pi / Oh My Pi

  /// Both runtimes take the prompt as the last positional, so the flag lands just before it.
  @Test func extensionFlagIsInsertedBeforeThePromptThroughACarrier() {
    let invocation = AgentInvocation(
      executable: "pi",
      arguments: ["--model", "gpt-5.6-sol", "--thinking", "high", "Review this"]
    )
    let prepared = ExtensionFlagHookRenderer.prepare(
      invocation: invocation,
      option: "-e",
      extensionPath: piExtension,
      promptArgumentIndex: 4
    )
    #expect(prepared.invocation.executable == "pi")
    #expect(prepared.invocation.arguments == ["--model", "gpt-5.6-sol", "--thinking", "high", "-e", "", "Review this"])
    #expect(prepared.argumentValues == [5: piExtension])
    #expect(prepared.environmentValues.isEmpty)

    let omp = ExtensionFlagHookRenderer.prepare(
      invocation: AgentInvocation(executable: "omp", arguments: ["--approval-mode", "always-ask"]),
      option: "--hook",
      extensionPath: ompExtension,
      promptArgumentIndex: nil
    )
    #expect(omp.invocation.arguments == ["--approval-mode", "always-ask", "--hook", ""])
    #expect(omp.argumentValues == [3: ompExtension])
  }

  /// Extension flags are additive and explicit paths survive `--no-extensions`, so a user's
  /// own extension and an end-of-options sentinel are left exactly where they were.
  @Test func extensionFlagPreservesUserExtensionsAndEndOfOptions() {
    let invocation = AgentInvocation(
      executable: "pi",
      arguments: ["--no-extensions", "-e", "/Users/me/ext.ts", "--", "--not-an-option"]
    )
    let prepared = ExtensionFlagHookRenderer.prepare(
      invocation: invocation,
      option: "-e",
      extensionPath: piExtension,
      promptArgumentIndex: nil
    )
    #expect(
      prepared.invocation.arguments == [
        "--no-extensions", "-e", "/Users/me/ext.ts", "-e", "", "--", "--not-an-option",
      ]
    )
    #expect(prepared.argumentValues == [4: piExtension])
  }

  @Test func extensionRuntimesDegradeWhenTheBundledFileIsMissing() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    var resources = try makeResources(in: root)
    resources.piExtensionPath = root.appending(path: "missing.ts").path(percentEncoded: false)
    resources.ompExtensionPath = nil

    for runtime in [AgentProfileRuntime.pi, .omp] {
      let preparation = await AgentManagedHookPreparer.prepare(
        plan: makePlan(runtime: runtime, arguments: ["Review this"]),
        inheritedCWD: root,
        resources: resources
      )
      #expect(preparation.preparedInvocation == nil)
      #expect(preparation.warning?.code == .managedHookDegraded)
      #expect(preparation.warning?.runtime == runtime.rawValue)
      #expect(preparation.warning?.message.contains("hook extension is unavailable") == true)
    }
  }

  /// Oh My Pi's `--cwd` (last wins, relative to the launch directory) is the directory its
  /// extensions report; Pi has no such option, so its launch directory is always inherited.
  @Test func ompRegistersTheLastCwdOptionAndPiInheritsTheLaunchDirectory() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = try makeExtensionResources(in: root)

    let omp = await AgentManagedHookPreparer.prepare(
      plan: makePlan(
        runtime: .omp, arguments: ["--cwd", "/tmp/elsewhere", "--cwd", "nested", "Review this"], prompt: "Review this"),
      inheritedCWD: root,
      resources: resources
    )
    #expect(omp.warning == nil)
    #expect(trimmed(omp.launchCWD) == trimmed(root.appending(path: "nested")))
    #expect(
      omp.preparedInvocation?.invocation.arguments == [
        "--cwd", "/tmp/elsewhere", "--cwd", "nested", "--hook", "", "Review this",
      ])
    #expect(omp.preparedInvocation?.argumentValues[5] == resources.ompExtensionPath)
    #expect(omp.capability?.runtime == .omp)

    let malformed = await AgentManagedHookPreparer.prepare(
      plan: makePlan(runtime: .omp, arguments: ["--cwd"]),
      inheritedCWD: root,
      resources: resources
    )
    #expect(malformed.preparedInvocation == nil)
    #expect(malformed.warning?.code == .managedHookDegraded)

    let piPreparation = await AgentManagedHookPreparer.prepare(
      plan: makePlan(runtime: .pi, arguments: ["--session-dir", "/tmp/sessions"]),
      inheritedCWD: root,
      resources: resources
    )
    #expect(piPreparation.warning == nil)
    #expect(piPreparation.launchCWD == root)
    #expect(piPreparation.preparedInvocation?.invocation.arguments == ["--session-dir", "/tmp/sessions", "-e", ""])
    #expect(piPreparation.preparedInvocation?.argumentValues[3] == resources.piExtensionPath)
  }

  // MARK: - OpenCode content

  @Test func opencodeAppendsItsPluginToAnEmptyOrBlankContent() throws {
    let invocation = AgentInvocation(executable: "opencode", arguments: ["--prompt", "Review this"])
    for existing in [nil, "", "  \n"] {
      let outcome = OpenCodeHookPluginPreparer.prepare(
        invocation: invocation,
        pluginPath: opencodePlugin,
        existingContent: existing,
        promptArgumentIndex: 1
      )
      let prepared = try #require(outcome.prepared)
      #expect(outcome.warning == nil)
      #expect(prepared.invocation == invocation)
      #expect(prepared.argumentValues.isEmpty)
      let content = try #require(prepared.environmentValues["OPENCODE_CONFIG_CONTENT"])
      let object = try #require(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
      #expect(object.keys.sorted() == ["plugin"])
      #expect(object["plugin"] as? [String] == [URL(filePath: opencodePlugin).absoluteString])
      #expect(content.contains("file:///Applications/Prowl.app/Contents/Resources/agent-hooks/opencode/prowl-hooks.ts"))
    }
  }

  /// `plugin[]` concatenates across OpenCode's config layers, so Prowl appends to the launch's
  /// own list and leaves every other key of the existing content untouched.
  @Test func opencodeAppendsToExistingContentPreservingOtherKeysWithoutDuplicating() throws {
    let existing = #"{"plugin":["opencode-helicone"],"model":"a/b","permission":{"edit":"ask"}}"#
    let outcome = OpenCodeHookPluginPreparer.prepare(
      invocation: AgentInvocation(executable: "opencode", arguments: []),
      pluginPath: opencodePlugin,
      existingContent: existing,
      promptArgumentIndex: nil
    )
    let content = try #require(outcome.prepared?.environmentValues["OPENCODE_CONFIG_CONTENT"])
    let object = try #require(try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
    #expect(object["plugin"] as? [String] == ["opencode-helicone", URL(filePath: opencodePlugin).absoluteString])
    #expect(object["model"] as? String == "a/b")
    #expect((object["permission"] as? [String: String]) == ["edit": "ask"])

    let again = OpenCodeHookPluginPreparer.prepare(
      invocation: AgentInvocation(executable: "opencode", arguments: []),
      pluginPath: opencodePlugin,
      existingContent: content,
      promptArgumentIndex: nil
    )
    #expect(again.prepared?.environmentValues["OPENCODE_CONFIG_CONTENT"] == content)
  }

  @Test func opencodeDegradesOnMalformedContentOrPluginShape() {
    for existing in ["not json", "[]", #"{"plugin":"one"}"#, #"{"plugin":{"a":1}}"#] {
      let outcome = OpenCodeHookPluginPreparer.prepare(
        invocation: AgentInvocation(executable: "opencode", arguments: []),
        pluginPath: opencodePlugin,
        existingContent: existing,
        promptArgumentIndex: nil
      )
      #expect(outcome.prepared == nil)
      #expect(outcome.warning?.code == .managedHookDegraded)
      #expect(outcome.warning?.runtime == "opencode")
      #expect(outcome.warning?.message.contains("launching unchanged") == true)
    }
  }

  /// `--pure` and `OPENCODE_PURE` disable every external plugin; OpenCode treats the variable
  /// as set unless it is `0` or `false` — an empty value still counts (measured).
  @Test func opencodeDegradesUnderPureFlagAndReadsPureEnvironmentLikeTheRuntime() {
    let pure = OpenCodeHookPluginPreparer.prepare(
      invocation: AgentInvocation(executable: "opencode", arguments: ["--pure", "--prompt", "Review this"]),
      pluginPath: opencodePlugin,
      existingContent: nil,
      promptArgumentIndex: 2
    )
    #expect(pure.prepared == nil)
    #expect(pure.warning?.message.contains("--pure") == true)
    let promptOnly = OpenCodeHookPluginPreparer.prepare(
      invocation: AgentInvocation(executable: "opencode", arguments: ["--prompt", "--pure"]),
      pluginPath: opencodePlugin,
      existingContent: nil,
      promptArgumentIndex: 1
    )
    #expect(promptOnly.prepared != nil)

    #expect(OpenCodeHookPluginPreparer.isPure(environmentValue: nil) == false)
    #expect(OpenCodeHookPluginPreparer.isPure(environmentValue: "0") == false)
    #expect(OpenCodeHookPluginPreparer.isPure(environmentValue: " FALSE ") == false)
    #expect(OpenCodeHookPluginPreparer.isPure(environmentValue: "") == true)
    #expect(OpenCodeHookPluginPreparer.isPure(environmentValue: "1") == true)
    #expect(OpenCodeHookPluginPreparer.isPure(environmentValue: "yes") == true)
  }

  /// The TUI takes the project as a positional; `opencode run` takes `--dir` (last wins).
  @Test func opencodeDirectoryScanFollowsTheTUIPositionalAndRunDir() {
    typealias Scan = ManagedHookWorkingDirectory.Scan
    #expect(
      OpenCodeLaunchDirectory.scan(
        arguments: ["--model", "a/b", "../dirA", "--prompt", "Review this"], promptArgumentIndex: 4)
        == Scan.changed("../dirA"))
    #expect(
      OpenCodeLaunchDirectory.scan(arguments: ["--prompt", "Review this"], promptArgumentIndex: 1)
        == Scan.inherited)
    #expect(OpenCodeLaunchDirectory.scan(arguments: ["--auto", "--", "x"], promptArgumentIndex: nil) == Scan.inherited)
    // Every OpenCode 1.18.23 TUI option that takes a value must be known, or its value would be
    // read as the project (`--replay-limit 7` would register `<cwd>/7`).
    #expect(
      OpenCodeLaunchDirectory.scan(
        arguments: ["--mini", "--no-replay", "--replay-limit", "7", "--prompt", "Review this"], promptArgumentIndex: 5)
        == Scan.inherited)
    #expect(
      OpenCodeLaunchDirectory.scan(
        arguments: [
          "--log-level", "DEBUG", "--port", "4096", "--hostname", "127.0.0.1", "--mdns", "--mdns-domain", "x.local",
          "--cors", "a.example", "-s", "ses_1", "--fork", "--agent", "plan", "--variant", "high",
        ],
        promptArgumentIndex: nil)
        == Scan.inherited)
    #expect(OpenCodeLaunchDirectory.scan(arguments: ["a", "b"], promptArgumentIndex: nil) == Scan.malformed)
    #expect(
      OpenCodeLaunchDirectory.scan(
        arguments: ["run", "--dir", "../dirA", "--dir", "../dirB", "Review this"], promptArgumentIndex: 5)
        == Scan.changed("../dirB"))
    #expect(OpenCodeLaunchDirectory.scan(arguments: ["run", "Review this"], promptArgumentIndex: 1) == Scan.inherited)
    #expect(OpenCodeLaunchDirectory.scan(arguments: ["run", "--dir"], promptArgumentIndex: nil) == Scan.malformed)
  }

  // MARK: - OpenCode preparation

  @Test func opencodePreferProfileOverridesSkipTheProbeAndDropPermissionAskedUnderAuto() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = try makeExtensionResources(in: root)
    let probeCalls = Counter()
    let plan = makePlan(runtime: .opencode, arguments: ["--auto", "--prompt", "Review this"])
      .withEnvironmentOverrides([
        "OPENCODE_CONFIG_CONTENT": #"{"plugin":["opencode-helicone"]}"#,
        "OPENCODE_PURE": "false",
      ])

    let preparation = await AgentManagedHookPreparer.prepare(
      plan: plan,
      inheritedCWD: root,
      resources: resources,
      openCodeEnvironmentResolver: { _, _ in
        await probeCalls.increment()
        return .failed
      }
    )
    #expect(await probeCalls.value == 0)
    #expect(preparation.warning == nil)
    #expect(preparation.launchCWD == root)
    let content = try #require(preparation.preparedInvocation?.environmentValues["OPENCODE_CONFIG_CONTENT"])
    #expect(content.contains("opencode-helicone"))
    #expect(content.contains("prowl-hooks.ts"))
    #expect(preparation.preparedInvocation?.invocation.arguments == ["--auto", "--prompt", "Review this"])
    let capability = try #require(preparation.capability)
    #expect(capability.nativeEvents == ["question.asked": .needsInput, "session.idle": .turnEnded])
    #expect(capability.coveredEvents == [.needsInput, .turnEnded])

    let standard = await AgentManagedHookPreparer.prepare(
      plan: makePlan(runtime: .opencode, arguments: ["--prompt", "Review this"]).withEnvironmentOverrides([
        "OPENCODE_CONFIG_CONTENT": "{}", "OPENCODE_PURE": "0",
      ]),
      inheritedCWD: root,
      resources: resources
    )
    #expect(standard.capability?.nativeEvents == AgentNativeHookDecoder.nativeEvents(for: .opencode))
  }

  @Test func opencodeUsesShellResolvedValuesAndDegradesWhenPureOrUnresolvable() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = try makeExtensionResources(in: root)
    let plan = makePlan(runtime: .opencode, arguments: ["--prompt", "Review this"])

    let merged = await AgentManagedHookPreparer.prepare(
      plan: plan, inheritedCWD: root, resources: resources,
      openCodeEnvironmentResolver: { _, _ in
        .values(["OPENCODE_CONFIG_CONTENT": #"{"plugin":["file:///Users/me/mine.ts"]}"#, "OPENCODE_PURE": nil])
      }
    )
    #expect(merged.warning == nil)
    let content = try #require(merged.preparedInvocation?.environmentValues["OPENCODE_CONFIG_CONTENT"])
    #expect(content.contains("file:///Users/me/mine.ts"))
    #expect(content.contains("prowl-hooks.ts"))

    let unset = await AgentManagedHookPreparer.prepare(
      plan: plan, inheritedCWD: root, resources: resources,
      openCodeEnvironmentResolver: { _, _ in .values(["OPENCODE_CONFIG_CONTENT": nil, "OPENCODE_PURE": nil]) }
    )
    #expect(
      unset.preparedInvocation?.environmentValues["OPENCODE_CONFIG_CONTENT"]?.hasPrefix(#"{"plugin":["file://"#) == true
    )

    let pure = await AgentManagedHookPreparer.prepare(
      plan: plan, inheritedCWD: root, resources: resources,
      openCodeEnvironmentResolver: { _, _ in .values(["OPENCODE_CONFIG_CONTENT": nil, "OPENCODE_PURE": ""]) }
    )
    #expect(pure.preparedInvocation == nil)
    #expect(pure.warning?.message.contains("OPENCODE_PURE") == true)

    let failed = await AgentManagedHookPreparer.prepare(
      plan: plan, inheritedCWD: root, resources: resources,
      openCodeEnvironmentResolver: { _, _ in .failed }
    )
    #expect(failed.preparedInvocation == nil)
    #expect(failed.warning?.code == .managedHookDegraded)

    // The override answers the probe's question for the variable it names; the other still
    // comes from the shell, and a shell `--pure` equivalent wins over a merged override.
    let half = await AgentManagedHookPreparer.prepare(
      plan: plan.withEnvironmentOverrides(["OPENCODE_CONFIG_CONTENT": "{}"]),
      inheritedCWD: root, resources: resources,
      openCodeEnvironmentResolver: { _, _ in .values(["OPENCODE_CONFIG_CONTENT": "ignored", "OPENCODE_PURE": "1"]) }
    )
    #expect(half.preparedInvocation == nil)
    #expect(half.warning?.message.contains("OPENCODE_PURE") == true)
  }

  @Test func opencodeDegradesWhenThePluginIsMissingOrTheProjectIsAmbiguous() async throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    var resources = try makeExtensionResources(in: root)

    let ambiguous = await AgentManagedHookPreparer.prepare(
      plan: makePlan(runtime: .opencode, arguments: ["one", "two"]),
      inheritedCWD: root, resources: resources,
      openCodeEnvironmentResolver: { _, _ in .values(["OPENCODE_CONFIG_CONTENT": nil, "OPENCODE_PURE": nil]) }
    )
    #expect(ambiguous.preparedInvocation == nil)
    #expect(ambiguous.warning?.message.contains("project directory") == true)

    try FileManager.default.createDirectory(at: root.appending(path: "nested"), withIntermediateDirectories: true)
    let project = await AgentManagedHookPreparer.prepare(
      plan: makePlan(runtime: .opencode, arguments: ["nested", "--prompt", "Review this"], prompt: "Review this"),
      inheritedCWD: root, resources: resources,
      openCodeEnvironmentResolver: { _, _ in .values(["OPENCODE_CONFIG_CONTENT": nil, "OPENCODE_PURE": nil]) }
    )
    #expect(trimmed(project.launchCWD) == trimmed(root.appending(path: "nested")))

    // OpenCode refuses to start in a directory that does not exist, so a positional that is not
    // an existing directory can only be the value of an option the scanner does not know: the
    // launch directory stays inherited instead of registering a path the hooks would never report.
    let unknownValue = await AgentManagedHookPreparer.prepare(
      plan: makePlan(
        runtime: .opencode, arguments: ["--future-option", "7", "--prompt", "Review this"], prompt: "Review this"),
      inheritedCWD: root, resources: resources,
      openCodeEnvironmentResolver: { _, _ in .values(["OPENCODE_CONFIG_CONTENT": nil, "OPENCODE_PURE": nil]) }
    )
    #expect(unknownValue.warning == nil)
    #expect(unknownValue.launchCWD == root)
    #expect(unknownValue.preparedInvocation != nil)

    resources.opencodePluginPath = nil
    let missing = await AgentManagedHookPreparer.prepare(
      plan: makePlan(runtime: .opencode, arguments: []),
      inheritedCWD: root, resources: resources
    )
    #expect(missing.preparedInvocation == nil)
    #expect(missing.warning?.message.contains("OpenCode hook plugin is unavailable") == true)
  }

  // MARK: - Shell probe

  /// Exercise the real script and parser through /bin/sh: set, set-but-empty, unset, and a
  /// multi-line value (OpenCode's content is JSON and may well span lines).
  @Test func shellEnvironmentProbeReadsSetEmptyUnsetAndMultilineValuesThroughRealSh() async {
    let cwd = FileManager.default.temporaryDirectory
    let resolution = await ShellEnvironmentProbe.resolve(
      variables: ["A_VALUE", "B_EMPTY", "C_UNSET"],
      cwd: cwd,
      run: Self.runShell(env: ["A_VALUE": "{\n  \"plugin\": []\n}\n", "B_EMPTY": "", "PATH": "/usr/bin:/bin"])
    )
    #expect(
      resolution
        == .values(["A_VALUE": "{\n  \"plugin\": []\n}\n", "B_EMPTY": "", "C_UNSET": nil]))

    let withPath = await ShellEnvironmentProbe.resolve(
      variables: ["PATH"],
      cwd: cwd,
      pathOverride: "/custom/bin:/usr/bin:/bin",
      run: Self.runShell(env: ["PATH": "/usr/bin:/bin"])
    )
    #expect(withPath == .values(["PATH": "/custom/bin:/usr/bin:/bin"]))
  }

  /// The production runner is the login-shell probe Codex uses, whose own default output bound
  /// is 16 KiB; a 20 KiB exported content must still come back whole. Only the deadline is
  /// relaxed, because the parallel suite can starve a real login shell past one second.
  @Test func shellEnvironmentProbeCarriesA20KiBValueThroughTheProductionRunner() async {
    let name = "PROWL_S3C_PROBE_LARGE_VALUE"
    let value = String(repeating: "x", count: 20 * 1_024)
    let environment = ProcessInfo.processInfo.environment.merging([name: value]) { $1 }
    let resolution = await ShellEnvironmentProbe.resolve(
      variables: [name],
      cwd: FileManager.default.temporaryDirectory,
      run: ShellEnvironmentProbe.defaultRunner(timeout: 15, environment: environment)
    )
    #expect(resolution == .values([name: value]))
  }

  @Test func shellEnvironmentProbeFailsClosedOnBadNamesOrIncompleteOutput() async {
    let cwd = FileManager.default.temporaryDirectory
    #expect(
      await ShellEnvironmentProbe.resolve(
        variables: ["bad name"], cwd: cwd,
        run: { _, _ in
          ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }) == .failed)
    #expect(
      await ShellEnvironmentProbe.resolve(
        variables: [], cwd: cwd,
        run: { _, _ in
          ShellOutput(stdout: "", stderr: "", exitCode: 0)
        }) == .failed)
    #expect(
      await ShellEnvironmentProbe.resolve(
        variables: ["A"], cwd: cwd,
        run: { _, _ in
          ShellOutput(stdout: "garbage\n", stderr: "", exitCode: 0)
        }) == .failed)
    #expect(
      await ShellEnvironmentProbe.resolve(
        variables: ["A"], cwd: cwd,
        run: { _, _ in
          ShellOutput(stdout: "", stderr: "", exitCode: 1)
        }) == .failed)
    #expect(
      await ShellEnvironmentProbe.resolve(
        variables: ["A"], cwd: cwd,
        run: { _, _ in
          throw CocoaError(.fileNoSuchFile)
        }) == .failed)
  }

  // MARK: - Helpers

  private func trimmed(_ url: URL) -> String {
    url.standardizedFileURL.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
  }

  private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
  }

  private static func runShell(env: [String: String]) -> @Sendable (URL, String) async throws -> ShellOutput {
    { cwd, script in
      try await withCheckedThrowingContinuation { continuation in
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh", directoryHint: .notDirectory)
        process.arguments = ["-c", script]
        process.currentDirectoryURL = cwd
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { proc in
          let data = out.fileHandleForReading.readDataToEndOfFile()
          continuation.resume(
            returning: ShellOutput(
              stdout: String(bytes: data, encoding: .utf8) ?? "", stderr: "", exitCode: proc.terminationStatus))
        }
        do { try process.run() } catch { continuation.resume(throwing: error) }
      }
    }
  }

  /// A prompted launch carries its prompt in the surface environment, which is how the preparer
  /// learns that the final argument is the prompt and inserts managed options before it.
  private func makePlan(
    runtime: AgentProfileRuntime,
    arguments: [String],
    prompt: String? = nil
  ) -> AgentProfileLaunchPlan {
    AgentProfileLaunchPlan(
      profileID: UUID(),
      profileName: "Test",
      runtime: runtime,
      invocation: AgentInvocation(executable: runtime.agent.iconLookupToken, arguments: arguments),
      commandEnvironmentTokens: [],
      placement: .tab,
      splitDirection: .right,
      surfaceEnvironment: prompt.map { [AgentProfileLaunchPlanner.promptCarrierName: $0] } ?? [:],
      dedicatedHome: nil
    )
  }

  private func makeTempDir() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "prowl-s3c-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeResources(in root: URL) throws -> AgentHookResources {
    let cli = root.appending(path: "prowl", directoryHint: .notDirectory)
    try "#!/bin/sh\nexit 0\n".write(to: cli, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
    return AgentHookResources(bundledCLIPath: cli.path(percentEncoded: false), socketPath: "/tmp/prowl.sock")
  }

  private func makeExtensionResources(in root: URL) throws -> AgentHookResources {
    var resources = try makeResources(in: root)
    for (name, keyPath) in [
      ("pi", \AgentHookResources.piExtensionPath),
      ("omp", \AgentHookResources.ompExtensionPath),
      ("opencode", \AgentHookResources.opencodePluginPath),
    ] {
      let directory = root.appending(path: "agent-hooks/\(name)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let file = directory.appending(path: "prowl-hooks.ts", directoryHint: .notDirectory)
      try "export default function () {}\n".write(to: file, atomically: true, encoding: .utf8)
      resources[keyPath: keyPath] = file.path(percentEncoded: false)
    }
    return resources
  }
}

extension AgentProfileLaunchPlan {
  fileprivate func withEnvironmentOverrides(_ overrides: [String: String]) -> AgentProfileLaunchPlan {
    AgentProfileLaunchPlan(
      profileID: profileID,
      profileName: profileName,
      runtime: runtime,
      invocation: invocation,
      argumentCarriers: argumentCarriers,
      environmentCarriers: environmentCarriers,
      hookRegistration: hookRegistration,
      commandEnvironmentTokens: commandEnvironmentTokens,
      placement: placement,
      splitDirection: splitDirection,
      surfaceEnvironment: surfaceEnvironment,
      profileEnvironmentOverrides: overrides,
      dedicatedHome: dedicatedHome,
      sessionConfigRoot: sessionConfigRoot
    )
  }
}
