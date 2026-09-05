import Foundation
import Testing

@testable import supacode

struct CodexConfigReadLiveContractTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["PROWL_RUN_LIVE_CODEX_CONTRACT"] == "1"))
  func scratchPrecedenceAndProjectExclusion() async throws {
    let environment = ProcessInfo.processInfo.environment
    let executablePath = try #require(environment["PROWL_CONTRACT_CODEX_EXECUTABLE"])
    let receiptPath = try #require(environment["PROWL_CONTRACT_RECEIPT"])
    let nonce = try #require(environment["PROWL_CONTRACT_NONCE"])
    let executable = URL(filePath: executablePath, directoryHint: .notDirectory)
    let root = FileManager.default.temporaryDirectory.appending(
      path: "prowl-codex-live-contract-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let workspace = root.appending(path: "workspace", directoryHint: .isDirectory)
    let parser = root.appending(path: "parser", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: workspace.appending(path: ".codex", directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try """
    notify = ["/tmp/base notifier", "base"]
    [projects."\(workspace.path(percentEncoded: false))"]
    trust_level = "trusted"
    """.write(
      to: home.appending(path: "config.toml"),
      atomically: true,
      encoding: .utf8
    )
    try #"notify = ["/tmp/profile notifier", "profile 界", ""]"#.write(
      to: home.appending(path: "selected.config.toml"),
      atomically: true,
      encoding: .utf8
    )
    try #"notify = ["/tmp/project notifier", "must-be-ignored"]"#.write(
      to: workspace.appending(path: ".codex/config.toml"),
      atomically: true,
      encoding: .utf8
    )
    let process = CodexConfigReadProcess(
      executableURL: executable,
      temporaryBaseDirectory: parser,
      timeout: 2
    )
    let resolver = CodexEffectiveNotifyResolver(
      bundledCLIPath: "/bundle/prowl",
      query: process.query
    )
    let base = CodexLaunchContext(
      inheritedCWD: workspace,
      effectiveCWD: workspace,
      codexHome: home,
      configOverrides: [],
      profileName: nil,
      explicitNotifyOverride: nil
    )
    try #require(await resolver.resolve(base) == .present(["/tmp/base notifier", "base"]))

    let profile = CodexLaunchContext(
      inheritedCWD: workspace,
      effectiveCWD: workspace,
      codexHome: home,
      configOverrides: [],
      profileName: "selected",
      explicitNotifyOverride: nil
    )
    try #require(
      await resolver.resolve(profile)
        == .present(["/tmp/profile notifier", "profile 界", ""])
    )

    let override = CodexLaunchContext(
      inheritedCWD: workspace,
      effectiveCWD: workspace,
      codexHome: home,
      configOverrides: [],
      profileName: "selected",
      explicitNotifyOverride: #"notify=["/tmp/cli notifier","cli"]"#
    )
    try #require(await resolver.resolve(override) == .present(["/tmp/cli notifier", "cli"]))
    try #require((try? FileManager.default.contentsOfDirectory(atPath: parser.path))?.isEmpty == true)

    // A nonce-bound receipt plus xcresult counts prevents an opt-in test skipped by Xcode
    // environment forwarding from being mistaken for a verified real-binary contract.
    let receipt: [String: Any] = [
      "schema": 1,
      "mode": "preflight",
      "runtime": "codex",
      "nonce": nonce,
      "executable": executablePath,
      "scenarios": ["base", "profile", "override", "cleanup"],
    ]
    let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
    try data.write(to: URL(filePath: receiptPath), options: [.withoutOverwriting])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptPath)
  }
}
