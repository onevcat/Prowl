import Foundation
import Testing

@testable import supacode

struct CodexEffectiveNotifyResolverTests {
  @Test func configReadProtocolUsesInitializeThenEffectiveCWDRequest() throws {
    let transcript = CodexConfigReadProtocol.requestData(cwd: "/tmp/Project Space/界")
    let lines = try transcript.split(separator: UInt8(ascii: "\n")).map {
      try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
    }

    #expect(lines.count == 3)
    #expect(lines[0]["method"] as? String == "initialize")
    #expect(lines[1]["method"] as? String == "initialized")
    #expect(lines[2]["method"] as? String == "config/read")
    let params = try #require(lines[2]["params"] as? [String: Any])
    #expect(params["cwd"] as? String == "/tmp/Project Space/界")
    #expect(params["includeLayers"] as? Bool == true)
  }

  @Test func resolverDistinguishesAbsentAndPresentNotifier() async {
    let context = makeContext()
    let absent = CodexEffectiveNotifyResolver(query: { _ in response(notify: nil) })
    #expect(await absent.resolve(context) == .absent)

    let present = CodexEffectiveNotifyResolver(query: { _ in
      response(notify: ["/tmp/notifier", "space value", "", "秘密"])
    })
    #expect(
      await present.resolve(context)
        == .present(["/tmp/notifier", "space value", "", "秘密"])
    )
  }

  @Test func selectedProfileWinsBaseAndMissingProfileNotifyFallsBack() async {
    let selected = makeContext(profileName: "selected")
    let profileWins = CodexEffectiveNotifyResolver(query: { query in
      switch query.kind {
      case .base: return response(notify: ["/tmp/base"])
      case .profile: return response(notify: ["/tmp/profile", "α"])
      case .explicitNotify:
        Issue.record("unexpected explicit override")
        return response(notify: nil)
      }
    })
    #expect(await profileWins.resolve(selected) == .present(["/tmp/profile", "α"]))

    let fallback = CodexEffectiveNotifyResolver(query: { query in
      switch query.kind {
      case .base: return response(notify: ["/tmp/base"])
      case .profile: return response(notify: nil)
      case .explicitNotify:
        Issue.record("unexpected explicit override")
        return response(notify: nil)
      }
    })
    #expect(await fallback.resolve(selected) == .present(["/tmp/base"]))
  }

  @Test func finalTopLevelCLIOverrideWinsProfile() async {
    let context = makeContext(
      profileName: "selected",
      explicitNotifyOverride: #"notify=["/tmp/cli notifier","quote=\"x\"",""]"#
    )
    let resolver = CodexEffectiveNotifyResolver(query: { query in
      switch query.kind {
      case .base: return response(notify: ["/tmp/base"])
      case .profile: return response(notify: ["/tmp/profile"])
      case .explicitNotify:
        #expect(query.overrides == [#"notify=["/tmp/cli notifier","quote=\"x\"",""]"#])
        return response(notify: ["/tmp/cli notifier", #"quote="x""#, ""])
      }
    })
    #expect(
      await resolver.resolve(context)
        == .present(["/tmp/cli notifier", #"quote="x""#, ""])
    )
  }

  @Test func malformedEmptyRecursiveAndTimeoutDegradeWithoutInjection() async {
    let context = makeContext()
    let malformed = CodexEffectiveNotifyResolver(query: { _ in Data("not-json\n".utf8) })
    #expect(await malformed.resolve(context).isDegraded)

    let empty = CodexEffectiveNotifyResolver(query: { _ in response(notify: []) })
    #expect(await empty.resolve(context).isDegraded)

    let recursive = CodexEffectiveNotifyResolver(
      bundledCLIPath: "/Applications/Prowl.app/Contents/Resources/prowl-cli/prowl",
      query: { _ in
        response(notify: [
          "/Applications/Prowl.app/Contents/Resources/prowl-cli/prowl",
          "agents", "_hook", "codex", "agent-turn-complete",
        ])
      }
    )
    #expect(await recursive.resolve(context).isDegraded)

    let failed = CodexEffectiveNotifyResolver(query: { _ in throw ProbeError.timeout })
    #expect(await failed.resolve(context).isDegraded)
  }

  @Test func launchContextFreezesSupportedCWDFormsAndRejectsRepeats() throws {
    let base = temporaryDirectory("codex-context")
    defer { try? FileManager.default.removeItem(at: base) }
    let child = base.appending(path: "space 界", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

    for arguments in [
      ["-C", "space 界"],
      ["--cd", "space 界"],
      ["--cd=space 界"],
      ["-Cspace 界"],
    ] {
      let context = try CodexLaunchContext.capture(
        invocation: AgentInvocation(executable: "codex", arguments: arguments),
        inheritedCWD: base,
        environment: [:]
      )
      #expect(
        context.effectiveCWD.path(percentEncoded: false)
          == child.standardizedFileURL.path(percentEncoded: false).trimmingTrailingSlashForTest
      )
    }

    #expect(throws: CodexLaunchContextError.repeatedWorkingDirectory) {
      try CodexLaunchContext.capture(
        invocation: AgentInvocation(executable: "codex", arguments: ["-C", "space 界", "--cd=space 界"]),
        inheritedCWD: base,
        environment: [:]
      )
    }
  }

  @Test func launchContextStopsScanningOptionsAtSentinel() throws {
    let base = temporaryDirectory("codex-sentinel")
    let context = try CodexLaunchContext.capture(
      invocation: AgentInvocation(
        executable: "codex",
        arguments: ["exec", "--", "-C", "/must-remain-literal", "Prompt"]
      ),
      inheritedCWD: base,
      environment: [:],
      promptArgumentIndex: 4
    )

    #expect(context.effectiveCWD == base.standardizedFileURL)
    #expect(context.configOverrides.isEmpty)
  }

  @Test func positionalPromptNeverBecomesAConfigOverride() throws {
    let base = temporaryDirectory("codex-prompt")
    let invocation = AgentInvocation(
      executable: "codex",
      arguments: ["-c", "model=\"x\"", #"-cnotify=["/tmp/notifier"]"#]
    )
    let context = try CodexLaunchContext.capture(
      invocation: invocation,
      inheritedCWD: base,
      environment: [:],
      promptArgumentIndex: 2
    )
    #expect(context.configOverrides == ["model=\"x\""])
    #expect(context.explicitNotifyOverride == nil)
  }

  @Test func launchContextCapturesHomeProfileAndOrderedOverrides() throws {
    let base = temporaryDirectory("codex-options")
    defer { try? FileManager.default.removeItem(at: base) }
    let home = base.appending(path: "home", directoryHint: .isDirectory)
    let invocation = AgentInvocation(
      executable: "codex",
      arguments: [
        "-c", "model=\"x\"",
        "--profile=selected",
        "--config", #"notify=["/tmp/first"]"#,
        "-cnotify=[\"/tmp/final\",\"秘密\"]",
      ]
    )
    let context = try CodexLaunchContext.capture(
      invocation: invocation,
      inheritedCWD: base,
      dedicatedHome: home,
      environment: ["CODEX_HOME": "/must/not/win"]
    )

    #expect(context.codexHome == home.standardizedFileURL)
    #expect(context.profileName == "selected")
    #expect(context.configOverrides == ["model=\"x\""])
    #expect(context.explicitNotifyOverride == "notify=[\"/tmp/final\",\"秘密\"]")
  }

  private enum ProbeError: Error {
    case timeout
  }

  private func makeContext(
    profileName: String? = nil,
    explicitNotifyOverride: String? = nil
  ) -> CodexLaunchContext {
    CodexLaunchContext(
      inheritedCWD: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      effectiveCWD: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      codexHome: URL(filePath: "/tmp/codex-home", directoryHint: .isDirectory),
      configOverrides: [],
      profileName: profileName,
      explicitNotifyOverride: explicitNotifyOverride
    )
  }

  private func response(notify: [String]?) -> Data {
    let value: Any = notify ?? NSNull()
    let data = try? JSONSerialization.data(
      withJSONObject: ["jsonrpc": "2.0", "id": 2, "result": ["config": ["notify": value]]],
      options: [.sortedKeys]
    )
    return (data ?? Data()) + Data([UInt8(ascii: "\n")])
  }

  private func temporaryDirectory(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "prowl-tests-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
  }
}

extension String {
  fileprivate var trimmingTrailingSlashForTest: String {
    count > 1 && hasSuffix("/") ? String(dropLast()) : self
  }
}

extension CodexEffectiveNotifyResult {
  fileprivate var isDegraded: Bool {
    if case .degraded = self { return true }
    return false
  }
}
