import Foundation
import Testing

@testable import supacode

/// Export real production launch preparation. Inference belongs to the opt-in Python runner;
/// no credentials enter the test host or its result bundle.
struct AgentHookContractExportTests {
  private struct Request: Decodable {
    let runtime: String
    let executable: String
    let workspace: String
    let resources: String
    let model: String
    let arguments: [String]
    let environment: [String: String]
    let prompt: String
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["PROWL_CONTRACT_EXPORT_INPUT"] != nil))
  func exportPreparedLaunches() async throws {
    let environment = ProcessInfo.processInfo.environment
    let input = try #require(environment["PROWL_CONTRACT_EXPORT_INPUT"])
    let output = try #require(environment["PROWL_CONTRACT_EXPORT_OUTPUT"])
    let nonce = try #require(environment["PROWL_CONTRACT_NONCE"])
    let requests = try JSONDecoder().decode([Request].self, from: Data(contentsOf: URL(filePath: input)))
    var rows: [[String: Any]] = []
    for request in requests {
      let runtime = try #require(AgentProfileRuntime(rawValue: request.runtime))
      let invocation = try AgentRuntimeAdapterRegistry.makeStartInvocation(
        AgentStartRequest(
          runtime: runtime,
          intent: .headless(request.prompt),
          configuration: .init(model: request.model, extraArguments: request.arguments)
        )
      )
      let plan = AgentProfileLaunchPlan(
        profileID: UUID(), profileName: "Runtime contract", runtime: runtime,
        invocation: invocation, commandEnvironmentTokens: [], placement: .tab, splitDirection: .right,
        surfaceEnvironment: [AgentProfileLaunchPlanner.promptCarrierName: request.prompt],
        profileEnvironmentOverrides: request.environment, dedicatedHome: nil
      )
      let root = request.resources
      let resources = AgentHookResources(
        bundledCLIPath: root + "/prowl-cli/prowl", socketPath: "/unused-export-socket",
        copilotPluginPath: root + "/agent-hooks/copilot",
        piExtensionPath: root + "/agent-hooks/pi/prowl-hooks.ts",
        ompExtensionPath: root + "/agent-hooks/omp/prowl-hooks.ts",
        opencodePluginPath: root + "/agent-hooks/opencode/prowl-hooks.ts"
      )
      let preparation = await AgentManagedHookPreparer.prepare(
        plan: plan, inheritedCWD: URL(filePath: request.workspace), resources: resources,
        codexShellEnvironment: CodexShellLaunchEnvironment(
          executableURL: URL(filePath: request.executable), processEnvironment: request.environment
        ),
        droidSettingsEnvironmentResolver: { _, _ in .value(nil) },
        openCodeEnvironmentResolver: { _, _ in .values(["OPENCODE_CONFIG_CONTENT": nil, "OPENCODE_PURE": nil]) }
      )
      var prepared = preparation.preparedInvocation
      if let pending = preparation.pendingSettingsFile {
        let path = URL(filePath: request.workspace).appending(path: "managed-settings.json")
        try pending.data.write(to: path, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        prepared = DroidHookSettingsPreparer.applying(
          settingsPath: path, invocation: pending.invocation, promptArgumentIndex: pending.promptArgumentIndex
        )
      }
      guard let prepared, preparation.warning == nil, preparation.forwardingArgv == nil else {
        rows.append([
          "runtime": request.runtime, "status": "blocked", "reason": "managed_hook_preparation_failed",
          "message": preparation.warning?.message ?? "Unexpected notifier forwarding",
        ])
        continue
      }
      var arguments = prepared.invocation.arguments
      for (index, value) in prepared.argumentValues { arguments[index] = value }
      rows.append([
        "runtime": request.runtime, "status": "prepared", "executable": request.executable,
        "arguments": arguments, "environment": prepared.environmentValues,
        "cwd": preparation.launchCWD.path(percentEncoded: false),
      ])
    }
    let data = try JSONSerialization.data(
      withJSONObject: ["schema": 1, "nonce": nonce, "launches": rows], options: [.sortedKeys]
    )
    try data.write(to: URL(filePath: output), options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output)
  }
}
