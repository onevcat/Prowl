#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import ProwlCLIShared
import XCTest

final class ProwlCLIIntegrationTests: XCTestCase {
  private var repoRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  /// Backstop cleanup for mock-server socket files. `MockSocketServer.stop()`
  /// (run via `defer`) covers the normal and throwing paths, but a test process
  /// killed mid-run (timeout, Ctrl-C) skips both `defer` and `deinit` and leaks
  /// the bound socket. Sweep any leftover `prowl-cli-*` from the socket
  /// directory after each test so they cannot accumulate. Matched by prefix
  /// only (no `.sock` suffix), so a truncated name would still be caught.
  override func tearDownWithError() throws {
    let dir = Self.socketDirectory
    for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    where name.hasPrefix("prowl-cli-") {
      unlink((dir as NSString).appendingPathComponent(name))
    }
    try super.tearDownWithError()
  }

  func testHelpAndVersionSmoke() throws {
    let version = try runProwl(args: ["--version"])
    XCTAssertEqual(version.exitCode, 0)
    XCTAssertTrue(version.stdout.contains(ProwlVersion.current))

    let help = try runProwl(args: ["--help"])
    XCTAssertEqual(help.exitCode, 0)
    XCTAssertTrue(help.stdout.contains("USAGE:"))
  }

  func testListReturnsAppNotRunningWhenSocketUnavailable() throws {
    let socketPath = temporarySocketPath(suffix: "app-not-running")
    let result = try runProwl(
      args: ["list", "--json"],
      environment: [ProwlSocket.environmentKey: socketPath]
    )

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.appNotRunning)
  }

  func testListReportsSocketPermissionDeniedWhenSocketCannotBeOpened() throws {
    let socketPath = temporarySocketPath(suffix: "permission-denied")
    let socket = PermissionDeniedSocket(socketPath: socketPath)
    try socket.start()
    defer { socket.stop() }

    let result = try runProwl(
      args: ["list", "--json"],
      environment: [ProwlSocket.environmentKey: socketPath]
    )

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.socketPermissionDenied)
    let message = try XCTUnwrap(error["message"] as? String)
    XCTAssertTrue(message.contains("EACCES"), "Message should include errno name: \(message)")
    XCTAssertTrue(message.localizedCaseInsensitiveContains("sandbox"), "Message should guide agent recovery: \(message)")
  }

  func testListReportsTransportFailedWhenSocketPathIsNotASocket() throws {
    let socketPath = temporarySocketPath(suffix: "not-a-socket")
    XCTAssertTrue(FileManager.default.createFile(atPath: socketPath, contents: Data()))
    defer { unlink(socketPath) }

    let result = try runProwl(
      args: ["list", "--json"],
      environment: [ProwlSocket.environmentKey: socketPath]
    )

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.transportFailed)
    let message = try XCTUnwrap(error["message"] as? String)
    XCTAssertTrue(message.contains("ENOTSOCK"), "Message should include errno name: \(message)")
  }

  func testListReportsTransportFailedWhenSocketPathIsTooLong() throws {
    let socketPath = (Self.socketDirectory as NSString)
      .appendingPathComponent("prowl-cli-\(String(repeating: "x", count: 120)).sock")

    let result = try runProwl(
      args: ["list", "--json"],
      environment: [ProwlSocket.environmentKey: socketPath]
    )

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.transportFailed)
    let message = try XCTUnwrap(error["message"] as? String)
    XCTAssertTrue(message.localizedCaseInsensitiveContains("too long"), "Message should identify path length: \(message)")
  }

  func testAgentsCommandRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "agents")
    let response = try CommandResponse(
      ok: true,
      command: "agents",
      schemaVersion: "prowl.cli.agents.v1",
      data: RawJSON(encoding: AgentsResponseData(count: 0, agents: []))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["agents", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .agents = envelope.command {
      // expected
    } else {
      XCTFail("Expected agents command envelope")
    }

    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, true)
    XCTAssertEqual(payload["command"] as? String, "agents")
  }

  func testJSONModePreservesEscapedControlCharactersFromAppResponse() throws {
    let socketPath = temporarySocketPath(suffix: "json-control")
    let responseJSON = [
      #"{"ok":true,"command":"read","schema_version":"prowl.cli.read.v1","data":{"#,
      #""target":{"#,
      #""worktree":{"id":"wt-1","name":"main","path":"/Projects/App","root_path":"/Projects/App","kind":"git"},"#,
      #""tab":{"id":"tab-1","title":"Tab\u0007Title","selected":true},"#,
      #""pane":{"id":"pane-1","title":"zsh\u001b[31m","cwd":"/Projects/App","focused":true}"#,
      #"},"#,
      #""mode":"last","last":80,"source":"scrollback","truncated":false,"#,
      #""line_count":1,"text":"alpha\u001b[31mbeta\u0000end"}}"#,
    ].joined()
    let responseData = try XCTUnwrap(responseJSON.data(using: .utf8))

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      responseData: responseData,
      args: ["read", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.stdout, "\(responseJSON)\n")
    assertNoRawJSONControlCharacters(in: result.stdout)

    let payload = try jsonObject(from: result.stdout)
    let data = try XCTUnwrap(payload["data"] as? [String: Any])
    XCTAssertEqual(data["text"] as? String, "alpha\u{1B}[31mbeta\u{0}end")

    let target = try XCTUnwrap(data["target"] as? [String: Any])
    let tab = try XCTUnwrap(target["tab"] as? [String: Any])
    let pane = try XCTUnwrap(target["pane"] as? [String: Any])
    XCTAssertEqual(tab["title"] as? String, "Tab\u{7}Title")
    XCTAssertEqual(pane["title"] as? String, "zsh\u{1B}[31m")
  }

  func testOpenCommandRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "open")
    let response = try CommandResponse(
      ok: true,
      command: "open",
      schemaVersion: "prowl.cli.open.v1",
      data: RawJSON(encoding: OpenResponseData(
        invocation: "open-subcommand",
        requestedPath: repoRoot.path,
        resolvedPath: repoRoot.path,
        resolution: "exact-root",
        appLaunched: false,
        broughtToFront: true
      ))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["open", ".", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .open(let input) = envelope.command {
      let openedPath = try XCTUnwrap(input.path)
      XCTAssertEqual(input.invocation, "open-subcommand")
      XCTAssertEqual(
        URL(fileURLWithPath: openedPath).resolvingSymlinksInPath().path,
        repoRoot.resolvingSymlinksInPath().path
      )
    } else {
      XCTFail("Expected open command envelope")
    }

    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, true)
    XCTAssertEqual(payload["command"] as? String, "open")
  }

  func testOpenCommandTextSuccessIsSilent() throws {
    let socketPath = temporarySocketPath(suffix: "open-text")
    let response = try CommandResponse(
      ok: true,
      command: "open",
      schemaVersion: "prowl.cli.open.v1",
      data: RawJSON(encoding: OpenResponseData(
        invocation: "implicit-open",
        requestedPath: repoRoot.path,
        resolvedPath: repoRoot.path,
        resolution: "exact-root",
        appLaunched: false,
        broughtToFront: true
      ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["."]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.stdout, "")
    XCTAssertEqual(result.stderr, "")
  }

  func testFocusCommandRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "focus")
    let response = CommandResponse(
      ok: true,
      command: "focus",
      schemaVersion: "prowl.cli.focus.v1"
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["focus", "--pane", "pane-123", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .focus(let input) = envelope.command {
      XCTAssertEqual(input.selector, .pane("pane-123"))
    } else {
      XCTFail("Expected focus command envelope")
    }

    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, true)
    XCTAssertEqual(payload["command"] as? String, "focus")
  }

  func testFocusCommandWithoutSelectorSendsCurrentTarget() throws {
    let socketPath = temporarySocketPath(suffix: "focus-current")
    let response = CommandResponse(
      ok: true,
      command: "focus",
      schemaVersion: "prowl.cli.focus.v1"
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["focus", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .focus(let input) = envelope.command {
      XCTAssertEqual(input.selector, .none)
    } else {
      XCTFail("Expected focus command envelope")
    }
  }

  func testTabCreateCommandRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "tab-create")
    let response = try CommandResponse(
      ok: true,
      command: "tab",
      schemaVersion: "prowl.cli.tab.v1",
      data: RawJSON(encoding: makeTabPayload(action: .create))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["tab", "create", "--worktree", "App", "--path", "/Projects/App", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .tab(let input) = envelope.command {
      XCTAssertEqual(input.action, .create)
      XCTAssertEqual(input.selector, .worktree("App"))
      XCTAssertEqual(input.path, "/Projects/App")
    } else {
      XCTFail("Expected tab command envelope")
    }
  }

  func testTabCloseCommandRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "tab-close")
    let response = try CommandResponse(
      ok: true,
      command: "tab",
      schemaVersion: "prowl.cli.tab.v1",
      data: RawJSON(encoding: makeTabPayload(action: .close))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["tab", "close", "--tab", "tab-123", "--force", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .tab(let input) = envelope.command {
      XCTAssertEqual(input.action, .close)
      XCTAssertEqual(input.selector, .tab("tab-123"))
      XCTAssertNil(input.path)
      XCTAssertTrue(input.force)
    } else {
      XCTFail("Expected tab command envelope")
    }
  }

  func testTabCloseRejectsMissingTargetBeforeTransport() throws {
    let result = try runProwl(args: ["tab", "close", "--json"])

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "tab")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  func testPaneCloseCommandRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "pane-close")
    let response = try CommandResponse(
      ok: true,
      command: "pane",
      schemaVersion: "prowl.cli.pane.v1",
      data: RawJSON(encoding: makePanePayload(action: .close))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["pane", "close", "--pane", "pane-123", "--force", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .pane(let input) = envelope.command {
      XCTAssertEqual(input.action, .close)
      XCTAssertEqual(input.selector, .pane("pane-123"))
      XCTAssertTrue(input.force)
    } else {
      XCTFail("Expected pane command envelope")
    }
  }

  func testPaneCloseRejectsMissingTargetBeforeTransport() throws {
    let result = try runProwl(args: ["pane", "close", "--json"])

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "pane")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  func testFocusRejectsMultipleSelectorsBeforeTransport() throws {
    let result = try runProwl(args: ["focus", "--worktree", "Prowl", "--pane", "pane-123", "--json"])

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "focus")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  func testFocusCommandTextRenderingFromSocket() throws {
    let socketPath = temporarySocketPath(suffix: "focus-text")
    let response = try CommandResponse(
      ok: true,
      command: "focus",
      schemaVersion: "prowl.cli.focus.v1",
      data: RawJSON(encoding: FocusResponseData(
        requested: FocusRequested(selector: "pane", value: "6E1A2A10-D99F-4E3F-920C-D93AA3C05764"),
        resolvedVia: "pane",
        broughtToFront: true,
        target: FocusResponseTarget(
          worktree: ListWorktree(
            id: "Prowl:/Users/onevcat/Projects/Prowl",
            name: "Prowl",
            path: "/Users/onevcat/Projects/Prowl",
            rootPath: "/Users/onevcat/Projects/Prowl",
            kind: "git"
          ),
          tab: FocusResponseTab(
            id: "2FC00CF0-3974-4E1B-BEF8-7A08A8E3B7C0",
            title: "Prowl 1",
            selected: true
          ),
          pane: FocusResponsePane(
            id: "6E1A2A10-D99F-4E3F-920C-D93AA3C05764",
            title: "zsh",
            cwd: "/Users/onevcat/Projects/Prowl",
            focused: true
          )
        )
      ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["focus"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("Focused Prowl:Prowl"), "Missing focus header: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("requested: pane"), "Missing requested field: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("resolved: pane"), "Missing resolved field: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("tab: Prowl 1"), "Missing tab field: \(result.stdout)")
  }


  func testListCommandTextRenderingFromSocket() throws {
    let socketPath = temporarySocketPath(suffix: "list-text")
    let response = try CommandResponse(
      ok: true,
      command: "list",
      schemaVersion: "prowl.cli.list.v1",
      data: RawJSON(encoding: ListResponseData(
        count: 1,
        items: [
          ListResponseItem(
            worktree: ListWorktree(
              id: "Prowl:/Users/onevcat/Projects/Prowl",
              name: "Prowl",
              path: "/Users/onevcat/Projects/Prowl",
              rootPath: "/Users/onevcat/Projects/Prowl",
              kind: "git"
            ),
            tab: ListTab(
              id: "2FC00CF0-3974-4E1B-BEF8-7A08A8E3B7C0",
              handle: 7,
              title: "Prowl 1",
              selected: true
            ),
            pane: ListPane(
              id: "6E1A2A10-D99F-4E3F-920C-D93AA3C05764",
              handle: 8,
              title: "zsh",
              cwd: "/Users/onevcat/Projects/Prowl",
              focused: true
            ),
            task: ListTask(status: "running")
          )
        ]
      ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["list"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("Prowl:Prowl (running)"), "Missing worktree header: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("Tab 1:"), "Missing tab label: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("t7"), "Missing tab handle: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("Pane 1:"), "Missing pane label: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("p8"), "Missing pane handle: \(result.stdout)")
    XCTAssertFalse(result.stdout.contains("6E1A2A10-D99F-4E3F-920C-D93AA3C05764"))
  }

  func testListEmptyPayloadShowsNoPanesFound() throws {
    let socketPath = temporarySocketPath(suffix: "list-empty")
    let response = try CommandResponse(
      ok: true,
      command: "list",
      schemaVersion: "prowl.cli.list.v1",
      data: RawJSON(encoding: ListResponseData(count: 0, items: []))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["list"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("No panes found."), "Expected empty message: \(result.stdout)")
  }

  func testAgentsCommandTextRenderingFromSocket() throws {
    let socketPath = temporarySocketPath(suffix: "agents-text")
    let response = try CommandResponse(
      ok: true,
      command: "agents",
      schemaVersion: "prowl.cli.agents.v1",
      data: RawJSON(encoding: AgentsResponseData(
        count: 3,
        agents: [
          makeAgentResponse(
            id: "done-pane",
            name: "codex",
            status: "done",
            projectName: "Prowl",
            branch: "main",
            tabTitle: "Done tab",
            session: AgentsResponseSession(
              id: "019f4e9e-1234-4567-89ab-0123456789ab",
              path: "/Users/me/.codex/sessions/rollout.jsonl",
              confidence: "exact",
              source: "open_file"
            )
          ),
          makeAgentResponse(
            id: "blocked-pane",
            handle: 3,
            name: "omp",
            status: "blocked",
            projectName: "Prowl",
            branch: "feature/cli-agents",
            tabTitle: "issue 330"
          ),
          makeAgentResponse(
            id: "working-pane",
            name: "claude",
            status: "working",
            projectName: "Notes",
            branch: "main",
            tabTitle: "review"
          ),
        ]
      ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["agents"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let lines = result.stdout.split(separator: "\n").map(String.init)
    XCTAssertEqual(lines.count, 3, "Unexpected agents output: \(result.stdout)")
    XCTAssertTrue(lines[0].contains("Blocked"), "Expected blocked first: \(result.stdout)")
    XCTAssertTrue(lines[0].contains("omp"), "Missing agent name: \(result.stdout)")
    XCTAssertTrue(lines[0].contains("Prowl:feature/cli-agents"), "Missing project label: \(result.stdout)")
    XCTAssertTrue(lines[0].contains("issue 330"), "Missing tab title: \(result.stdout)")
    XCTAssertTrue(lines[0].contains("p3"), "Missing pane handle: \(result.stdout)")
    XCTAssertFalse(lines[0].contains("blocked-pane"), "Unexpected UUID fallback: \(result.stdout)")
    XCTAssertTrue(lines[1].contains("Working"), "Expected working second: \(result.stdout)")
    XCTAssertTrue(lines[2].contains("Done"), "Expected done third: \(result.stdout)")
    XCTAssertTrue(lines[2].contains("session=019f4e9e-1234-4567-89ab-0123456789ab [exact]"))
  }

  func testAgentsEmptyPayloadShowsNoAgentsFound() throws {
    let socketPath = temporarySocketPath(suffix: "agents-empty")
    let response = try CommandResponse(
      ok: true,
      command: "agents",
      schemaVersion: "prowl.cli.agents.v1",
      data: RawJSON(encoding: AgentsResponseData(count: 0, agents: []))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["agents"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("No agents found."), "Expected empty message: \(result.stdout)")
  }

  func testListMultipleWorktreesGroupedWithBlankLine() throws {
    let socketPath = temporarySocketPath(suffix: "list-multi-wt")
    let response = try CommandResponse(
      ok: true,
      command: "list",
      schemaVersion: "prowl.cli.list.v1",
      data: RawJSON(encoding: ListResponseData(
        count: 2,
        items: [
          ListResponseItem(
            worktree: ListWorktree(
              id: "wt-1", name: "main",
              path: "/Projects/Alpha", rootPath: "/Projects/Alpha", kind: "git"
            ),
            tab: ListTab(id: "t1", title: "Tab A", selected: true),
            pane: ListPane(id: "p1", title: "zsh", cwd: "/Projects/Alpha", focused: true),
            task: ListTask(status: "running")
          ),
          ListResponseItem(
            worktree: ListWorktree(
              id: "wt-2", name: "develop",
              path: "/Projects/Beta", rootPath: "/Projects/Beta", kind: "git"
            ),
            tab: ListTab(id: "t2", title: "Tab B", selected: true),
            pane: ListPane(id: "p2", title: "zsh", cwd: "/Projects/Beta", focused: false),
            task: ListTask(status: "idle")
          ),
        ]
      ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["list"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("Alpha:main (running)"), "Missing first worktree: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("Beta:develop (idle)"), "Missing second worktree: \(result.stdout)")

    // Worktrees should be separated by a blank line.
    let lines = result.stdout.components(separatedBy: "\n")
    let blankIndices = lines.enumerated().filter { $0.element.isEmpty }.map(\.offset)
    XCTAssertFalse(blankIndices.isEmpty, "Expected blank line between worktrees: \(result.stdout)")
  }

  func testListCwdSuppressedWhenMatchingWorktreePath() throws {
    let socketPath = temporarySocketPath(suffix: "list-cwd-dedup")
    let response = try CommandResponse(
      ok: true,
      command: "list",
      schemaVersion: "prowl.cli.list.v1",
      data: RawJSON(encoding: ListResponseData(
        count: 2,
        items: [
          ListResponseItem(
            worktree: ListWorktree(
              id: "wt-1", name: "main",
              path: "/Projects/App", rootPath: "/Projects/App", kind: "git"
            ),
            tab: ListTab(id: "t1", title: "Tab 1", selected: true),
            pane: ListPane(id: "p-same", title: "zsh", cwd: "/Projects/App", focused: true),
            task: ListTask(status: "idle")
          ),
          ListResponseItem(
            worktree: ListWorktree(
              id: "wt-1", name: "main",
              path: "/Projects/App", rootPath: "/Projects/App", kind: "git"
            ),
            tab: ListTab(id: "t1", title: "Tab 1", selected: true),
            pane: ListPane(id: "p-diff", title: "zsh", cwd: "/Users/onevcat", focused: false),
            task: ListTask(status: "idle")
          ),
        ]
      ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["list"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let lines = result.stdout.components(separatedBy: "\n")

    // Pane whose cwd matches worktree path should NOT repeat the cwd.
    let sameLine = lines.first { $0.contains("p-same") }
    XCTAssertNotNil(sameLine, "Missing same-cwd pane")
    XCTAssertFalse(sameLine?.contains("/Projects/App") ?? true, "cwd should be suppressed: \(sameLine ?? "")")

    // Pane whose cwd differs should show it.
    let diffLine = lines.first { $0.contains("p-diff") }
    XCTAssertNotNil(diffLine, "Missing diff-cwd pane")
    XCTAssertTrue(diffLine?.contains("/Users/onevcat") ?? false, "cwd should be shown: \(diffLine ?? "")")
  }

  func testListMultiTabMultiPaneNumbering() throws {
    let socketPath = temporarySocketPath(suffix: "list-numbering")
    let response = try CommandResponse(
      ok: true,
      command: "list",
      schemaVersion: "prowl.cli.list.v1",
      data: RawJSON(encoding: ListResponseData(
        count: 3,
        items: [
          ListResponseItem(
            worktree: ListWorktree(
              id: "wt-1", name: "main",
              path: "/Projects/App", rootPath: "/Projects/App", kind: "git"
            ),
            tab: ListTab(id: "tab-a", title: "Tab A", selected: false),
            pane: ListPane(id: "pa1", title: "zsh", cwd: "/Projects/App", focused: false),
            task: ListTask(status: "idle")
          ),
          ListResponseItem(
            worktree: ListWorktree(
              id: "wt-1", name: "main",
              path: "/Projects/App", rootPath: "/Projects/App", kind: "git"
            ),
            tab: ListTab(id: "tab-b", title: "Tab B", selected: true),
            pane: ListPane(id: "pb1", title: "vim", cwd: "/Projects/App", focused: true),
            task: ListTask(status: "idle")
          ),
          ListResponseItem(
            worktree: ListWorktree(
              id: "wt-1", name: "main",
              path: "/Projects/App", rootPath: "/Projects/App", kind: "git"
            ),
            tab: ListTab(id: "tab-b", title: "Tab B", selected: true),
            pane: ListPane(id: "pb2", title: "htop", cwd: "/Projects/App", focused: false),
            task: ListTask(status: "idle")
          ),
        ]
      ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["list"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("Tab 1:"), "Missing Tab 1: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("Tab 2:"), "Missing Tab 2: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("Pane 1:"), "Missing Pane 1: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("Pane 2:"), "Missing Pane 2: \(result.stdout)")
  }

  func testListNoColorFlagProducesCleanOutput() throws {
    let socketPath = temporarySocketPath(suffix: "list-no-color")
    let response = try CommandResponse(
      ok: true,
      command: "list",
      schemaVersion: "prowl.cli.list.v1",
      data: RawJSON(encoding: ListResponseData(
        count: 1,
        items: [
          ListResponseItem(
            worktree: ListWorktree(
              id: "wt-1", name: "main",
              path: "/Projects/App", rootPath: "/Projects/App", kind: "git"
            ),
            tab: ListTab(id: "t1", title: "Tab A", selected: true),
            pane: ListPane(id: "p1", title: "zsh", cwd: "/Projects/App", focused: true),
            task: ListTask(status: "running")
          ),
        ]
      ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["list", "--no-color"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertFalse(result.stdout.contains("\u{1B}["), "Should not contain ANSI escape codes: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("App:main (running)"), "Missing header: \(result.stdout)")
  }

  // MARK: - Send command tests

  func testSendCommandRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "send")
    let response = try CommandResponse(
      ok: true,
      command: "send",
      schemaVersion: "prowl.cli.send.v1",
      data: RawJSON(encoding: SendResponseData(
        target: SendResponseTarget(
          worktree: ListWorktree(
            id: "Prowl:/Projects/Prowl", name: "Prowl",
            path: "/Projects/Prowl", rootPath: "/Projects/Prowl", kind: "git"
          ),
          tab: SendResponseTab(id: "2FC00CF0-3974-4E1B-BEF8-7A08A8E3B7C0", title: "Prowl 1", selected: true),
          pane: SendResponsePane(
            id: "6E1A2A10-D99F-4E3F-920C-D93AA3C05764",
            title: "zsh", cwd: "/Projects/Prowl", focused: true
          )
        ),
        input: SendResponseInput(source: "argv", characters: 10, bytes: 10, trailingEnterSent: true),
        createdTab: false,
        wait: SendResponseWait(exitCode: 0, durationMs: 1234)
      ))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["send", "echo hello", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .send(let input) = envelope.command {
      XCTAssertEqual(input.text, "echo hello")
      XCTAssertEqual(input.source, .argv)
      XCTAssertTrue(input.trailingEnter)
      XCTAssertTrue(input.wait)
    } else {
      XCTFail("Expected send command envelope")
    }

    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, true)
    XCTAssertEqual(payload["command"] as? String, "send")
    let data = try XCTUnwrap(payload["data"] as? [String: Any])
    let wait = try XCTUnwrap(data["wait"] as? [String: Any])
    XCTAssertEqual(wait["exit_code"] as? Int, 0)
    XCTAssertEqual(wait["duration_ms"] as? Int, 1234)
  }

  func testSendNoWaitJsonShowsNullWait() throws {
    let socketPath = temporarySocketPath(suffix: "send-no-wait")
    let response = try CommandResponse(
      ok: true,
      command: "send",
      schemaVersion: "prowl.cli.send.v1",
      data: RawJSON(encoding: SendResponseData(
        target: SendResponseTarget(
          worktree: ListWorktree(
            id: "wt-1", name: "main",
            path: "/Projects/App", rootPath: "/Projects/App", kind: "git"
          ),
          tab: SendResponseTab(id: "t1", title: "Tab 1", selected: true),
          pane: SendResponsePane(id: "p1", title: "zsh", cwd: "/Projects/App", focused: true)
        ),
        input: SendResponseInput(source: "argv", characters: 5, bytes: 5, trailingEnterSent: true),
        createdTab: false,
        wait: nil
      ))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["send", "hello", "--no-wait", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .send(let input) = envelope.command {
      XCTAssertFalse(input.wait)
    } else {
      XCTFail("Expected send command envelope")
    }

    let payload = try jsonObject(from: result.stdout)
    let data = try XCTUnwrap(payload["data"] as? [String: Any])
    XCTAssertTrue(data["wait"] is NSNull, "wait should be null: \(data["wait"] ?? "missing")")
  }

  func testSendTextRenderingFromSocket() throws {
    let socketPath = temporarySocketPath(suffix: "send-text")
    let response = try CommandResponse(
      ok: true,
      command: "send",
      schemaVersion: "prowl.cli.send.v1",
      data: RawJSON(encoding: SendResponseData(
        target: SendResponseTarget(
          worktree: ListWorktree(
            id: "wt-1", name: "main",
            path: "/Projects/App", rootPath: "/Projects/App", kind: "git"
          ),
          tab: SendResponseTab(id: "t1", title: "Tab 1", selected: true),
          pane: SendResponsePane(id: "p1", title: "zsh", cwd: "/Projects/App", focused: true)
        ),
        input: SendResponseInput(source: "argv", characters: 10, bytes: 10, trailingEnterSent: true),
        createdTab: false,
        wait: SendResponseWait(exitCode: 0, durationMs: 350)
      ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["send", "echo hello"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("Sent to"), "Missing 'Sent to' header: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("App:main"), "Missing worktree: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("zsh"), "Missing pane title: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("chars:"), "Missing chars label: \(result.stdout)")
  }

  func testSendNoColorProducesCleanOutput() throws {
    let socketPath = temporarySocketPath(suffix: "send-no-color")
    let response = try CommandResponse(
      ok: true,
      command: "send",
      schemaVersion: "prowl.cli.send.v1",
      data: RawJSON(encoding: SendResponseData(
        target: SendResponseTarget(
          worktree: ListWorktree(
            id: "wt-1", name: "main",
            path: "/Projects/App", rootPath: "/Projects/App", kind: "git"
          ),
          tab: SendResponseTab(id: "t1", title: "Tab 1", selected: true),
          pane: SendResponsePane(id: "p1", title: "zsh", cwd: "/Projects/App", focused: true)
        ),
        input: SendResponseInput(source: "argv", characters: 5, bytes: 5, trailingEnterSent: true),
        createdTab: false,
        wait: SendResponseWait(exitCode: 0, durationMs: 100)
      ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["send", "hello", "--no-color"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertFalse(result.stdout.contains("\u{1B}["), "Should not contain ANSI escape codes: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("Sent to"), "Missing header: \(result.stdout)")
  }

  func testSendEmptyInputReturnsError() throws {
    let result = try runProwl(args: ["send", "--json"])
    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, "EMPTY_INPUT")
  }

  func testSendTimeoutValidation() throws {
    let result = try runProwl(args: ["send", "hello", "--timeout", "0", "--json"])
    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, "INVALID_ARGUMENT")
  }

  // MARK: - Key command tests

  func testKeyCommandRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "key")
    let response = try CommandResponse(
      ok: true,
      command: "key",
      schemaVersion: "prowl.cli.key.v1",
      data: RawJSON(encoding: KeyResponseData(
        requested: KeyResponseRequested(token: "enter", repeat: 1),
        key: KeyResponseKey(normalized: "enter", category: "editing"),
        delivery: KeyResponseDelivery(attempted: 1, delivered: 1, mode: "keyDownUp"),
        target: KeyResponseTarget(
          worktree: ListWorktree(
            id: "Prowl:/Projects/Prowl", name: "Prowl",
            path: "/Projects/Prowl", rootPath: "/Projects/Prowl", kind: "git"
          ),
          tab: KeyResponseTab(id: "2FC00CF0-3974-4E1B-BEF8-7A08A8E3B7C0", title: "Prowl 1", selected: true),
          pane: KeyResponsePane(
            id: "6E1A2A10-D99F-4E3F-920C-D93AA3C05764",
            title: "zsh", cwd: "/Projects/Prowl", focused: true
          )
        )
      ))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["key", "enter", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .key(let input) = envelope.command {
      XCTAssertEqual(input.token, "enter")
      XCTAssertEqual(input.rawToken, "enter")
      XCTAssertEqual(input.repeatCount, 1)
      XCTAssertEqual(input.selector, .none)
    } else {
      XCTFail("Expected key command envelope")
    }

    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, true)
    XCTAssertEqual(payload["command"] as? String, "key")
    XCTAssertEqual(payload["schema_version"] as? String, "prowl.cli.key.v1")
    let data = try XCTUnwrap(payload["data"] as? [String: Any])
    let key = try XCTUnwrap(data["key"] as? [String: Any])
    XCTAssertEqual(key["normalized"] as? String, "enter")
    XCTAssertEqual(key["category"] as? String, "editing")
  }

  func testKeyCommandAliasNormalization() throws {
    let socketPath = temporarySocketPath(suffix: "key-alias")
    let response = CommandResponse(
      ok: true,
      command: "key",
      schemaVersion: "prowl.cli.key.v1"
    )

    let (requestData, _) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["key", "return", "--json"]
    )

    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .key(let input) = envelope.command {
      XCTAssertEqual(input.token, "enter", "Alias 'return' should normalize to 'enter'")
      XCTAssertEqual(input.rawToken, "return", "rawToken should preserve original input")
    } else {
      XCTFail("Expected key command envelope")
    }
  }

  func testKeyCommandCtrlAliasNormalization() throws {
    let socketPath = temporarySocketPath(suffix: "key-ctrl-alias")
    let response = CommandResponse(
      ok: true,
      command: "key",
      schemaVersion: "prowl.cli.key.v1"
    )

    let (requestData, _) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["key", "ctrl+c", "--json"]
    )

    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .key(let input) = envelope.command {
      XCTAssertEqual(input.token, "ctrl-c", "Alias 'ctrl+c' should normalize to 'ctrl-c'")
      XCTAssertEqual(input.rawToken, "ctrl+c")
    } else {
      XCTFail("Expected key command envelope")
    }
  }

  func testKeyCommandCaseInsensitive() throws {
    let socketPath = temporarySocketPath(suffix: "key-case")
    let response = CommandResponse(
      ok: true,
      command: "key",
      schemaVersion: "prowl.cli.key.v1"
    )

    let (requestData, _) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["key", "ENTER", "--json"]
    )

    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .key(let input) = envelope.command {
      XCTAssertEqual(input.token, "enter", "Token parsing should be case-insensitive")
    } else {
      XCTFail("Expected key command envelope")
    }
  }

  func testKeyCommandWithRepeatAndSelector() throws {
    let socketPath = temporarySocketPath(suffix: "key-repeat")
    let response = CommandResponse(
      ok: true,
      command: "key",
      schemaVersion: "prowl.cli.key.v1"
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["key", "--pane", "pane-abc", "up", "--repeat", "5", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .key(let input) = envelope.command {
      XCTAssertEqual(input.token, "up")
      XCTAssertEqual(input.repeatCount, 5)
      XCTAssertEqual(input.selector, .pane("pane-abc"))
    } else {
      XCTFail("Expected key command envelope")
    }
  }

  func testKeyCommandRejectInvalidRepeatZero() throws {
    let result = try runProwl(args: ["key", "enter", "--repeat", "0", "--json"])
    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "key")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidRepeat)
  }

  func testKeyCommandRejectInvalidRepeatOver100() throws {
    let result = try runProwl(args: ["key", "enter", "--repeat", "101", "--json"])
    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidRepeat)
  }

  func testKeyCommandRejectUnsupportedKey() throws {
    let result = try runProwl(args: ["key", "hyper-k", "--json"])
    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "key")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.unsupportedKey)
  }

  func testKeyCommandRejectMultipleSelectors() throws {
    let result = try runProwl(args: ["key", "enter", "--worktree", "Prowl", "--pane", "pane-123", "--json"])
    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "key")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  func testKeyCommandTextRenderingFromSocket() throws {
    let socketPath = temporarySocketPath(suffix: "key-text")
    let response = try CommandResponse(
      ok: true,
      command: "key",
      schemaVersion: "prowl.cli.key.v1",
      data: RawJSON(encoding: KeyResponseData(
        requested: KeyResponseRequested(token: "Ctrl+C", repeat: 3),
        key: KeyResponseKey(normalized: "ctrl-c", category: "control"),
        delivery: KeyResponseDelivery(attempted: 3, delivered: 3, mode: "keyDownUp"),
        target: KeyResponseTarget(
          worktree: ListWorktree(
            id: "Prowl:/Projects/Prowl", name: "Prowl",
            path: "/Projects/Prowl", rootPath: "/Projects/Prowl", kind: "git"
          ),
          tab: KeyResponseTab(id: "t1", title: "Prowl 1", selected: true),
          pane: KeyResponsePane(id: "p1", title: "Claude", cwd: "/Projects/Prowl", focused: true)
        )
      ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["key", "ctrl+c", "--repeat", "3"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("Key sent to"), "Missing header: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("Prowl:Prowl"), "Missing worktree: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("Claude"), "Missing pane title: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("token:"), "Missing token label: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("ctrl-c"), "Missing normalized token: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("category:"), "Missing category label: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("control"), "Missing category value: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("repeat:"), "Missing repeat label: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("delivered:"), "Missing delivered label: \(result.stdout)")
  }

  func testKeyCommandNoColorProducesCleanOutput() throws {
    let socketPath = temporarySocketPath(suffix: "key-no-color")
    let response = try CommandResponse(
      ok: true,
      command: "key",
      schemaVersion: "prowl.cli.key.v1",
      data: RawJSON(encoding: KeyResponseData(
        requested: KeyResponseRequested(token: "esc", repeat: 1),
        key: KeyResponseKey(normalized: "esc", category: "control"),
        delivery: KeyResponseDelivery(attempted: 1, delivered: 1, mode: "keyDownUp"),
        target: KeyResponseTarget(
          worktree: ListWorktree(
            id: "wt-1", name: "main",
            path: "/Projects/App", rootPath: "/Projects/App", kind: "git"
          ),
          tab: KeyResponseTab(id: "t1", title: "Tab 1", selected: true),
          pane: KeyResponsePane(id: "p1", title: "zsh", cwd: "/Projects/App", focused: true)
        )
      ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["key", "esc", "--no-color"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertFalse(result.stdout.contains("\u{1B}["), "Should not contain ANSI escape codes: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("Key sent to"), "Missing header: \(result.stdout)")
  }

  func testKeyCommandAllCanonicalTokensAccepted() throws {
    let canonicalTokens = [
      "enter", "esc", "tab", "backspace",
      "up", "down", "left", "right",
      "pageup", "pagedown", "home", "end",
      "ctrl-c", "ctrl-d", "ctrl-l",
    ]
    for token in canonicalTokens {
      let socketPath = temporarySocketPath(suffix: "key-canonical-\(token)")
      let response = CommandResponse(
        ok: true,
        command: "key",
        schemaVersion: "prowl.cli.key.v1"
      )

      let (requestData, result) = try runWithMockServer(
        socketPath: socketPath,
        response: response,
        args: ["key", token, "--json"]
      )

      XCTAssertEqual(result.exitCode, 0, "Token '\(token)' should be accepted")
      let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
      if case .key(let input) = envelope.command {
        XCTAssertEqual(input.token, token, "Canonical token '\(token)' should pass through unchanged")
      } else {
        XCTFail("Expected key command envelope for token '\(token)'")
      }
    }
  }

  func testKeyCommandAllAliasesNormalize() throws {
    let aliasMap: [(alias: String, canonical: String)] = [
      ("return", "enter"),
      ("escape", "esc"),
      ("arrow-up", "up"),
      ("arrow-down", "down"),
      ("arrow-left", "left"),
      ("arrow-right", "right"),
      ("pgup", "pageup"),
      ("pgdn", "pagedown"),
      ("ctrl+c", "ctrl-c"),
      ("ctrl+d", "ctrl-d"),
      ("ctrl+l", "ctrl-l"),
    ]
    for (alias, canonical) in aliasMap {
      let socketPath = temporarySocketPath(suffix: "key-alias-\(alias)")
      let response = CommandResponse(
        ok: true,
        command: "key",
        schemaVersion: "prowl.cli.key.v1"
      )

      let (requestData, _) = try runWithMockServer(
        socketPath: socketPath,
        response: response,
        args: ["key", alias, "--json"]
      )

      let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
      if case .key(let input) = envelope.command {
        XCTAssertEqual(input.token, canonical, "Alias '\(alias)' should normalize to '\(canonical)'")
        XCTAssertEqual(input.rawToken, alias, "rawToken should preserve '\(alias)'")
      } else {
        XCTFail("Expected key command envelope for alias '\(alias)'")
      }
    }
  }

  func testKeyCommandExpandedTokensAccepted() throws {
    let tokenCases: [(raw: String, normalized: String)] = [
      ("cmd-c", "cmd-c"),
      ("command-shift-k", "cmd-shift-k"),
      ("alt-enter", "opt-enter"),
      ("ctrl-z", "ctrl-z"),
      ("A", "shift-a"),
      ("Ctrl-A", "shift-ctrl-a"),
      ("CTRL-A", "shift-ctrl-a"),
      ("ctrl-left-bracket", "ctrl-left-bracket"),
      ("ctrl-backslash", "ctrl-backslash"),
      ("ctrl-right-bracket", "ctrl-right-bracket"),
      ("ctrl-shift-6", "shift-ctrl-6"),
      ("ctrl-shift-minus", "shift-ctrl-minus"),
      ("deleteforward", "delete-forward"),
      ("f12", "f12"),
      ("[", "left-bracket"),
    ]

    for (raw, normalized) in tokenCases {
      let socketPath = temporarySocketPath(suffix: "key-expanded-\(normalized.replacingOccurrences(of: "-", with: "_"))")
      let response = CommandResponse(
        ok: true,
        command: "key",
        schemaVersion: "prowl.cli.key.v1"
      )

      let (requestData, result) = try runWithMockServer(
        socketPath: socketPath,
        response: response,
        args: ["key", raw, "--json"]
      )

      XCTAssertEqual(result.exitCode, 0, "Token '\(raw)' should be accepted")
      let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
      if case .key(let input) = envelope.command {
        XCTAssertEqual(input.token, normalized)
        XCTAssertEqual(input.rawToken, raw)
      } else {
        XCTFail("Expected key command envelope for token '\(raw)'")
      }
    }
  }

  func testKeyCommandRejectsUnsupportedShiftedSymbolLiteral() throws {
    let result = try runProwl(args: ["key", "!", "--json"])
    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "key")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.unsupportedKey)
  }

  // MARK: - Read command tests

  func testReadCommandRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "read")
    let response = try CommandResponse(
      ok: true,
      command: "read",
      schemaVersion: "prowl.cli.read.v1",
      data: RawJSON(encoding: ReadResponseData(
        target: ReadResponseTarget(
          worktree: ListWorktree(
            id: "Prowl:/Projects/Prowl",
            name: "Prowl",
            path: "/Projects/Prowl",
            rootPath: "/Projects/Prowl",
            kind: "git"
          ),
          tab: ReadResponseTab(
            id: "2FC00CF0-3974-4E1B-BEF8-7A08A8E3B7C0",
            title: "Prowl 1",
            selected: true
          ),
          pane: ReadResponsePane(
            id: "6E1A2A10-D99F-4E3F-920C-D93AA3C05764",
            title: "zsh",
            cwd: "/Projects/Prowl",
            focused: true
          )
        ),
        mode: "last",
        last: 5,
        source: "scrollback",
        truncated: false,
        lineCount: 5,
        text: "1\n2\n3\n4\n5"
      ))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["read", "--pane", "pane-123", "--last", "5", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .read(let input) = envelope.command {
      XCTAssertEqual(input.selector, .pane("pane-123"))
      XCTAssertEqual(input.last, 5)
    } else {
      XCTFail("Expected read command envelope")
    }

    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, true)
    XCTAssertEqual(payload["command"] as? String, "read")
    XCTAssertEqual(payload["schema_version"] as? String, "prowl.cli.read.v1")
  }

  func testReadWithoutLastDefaultsToSnapshot() throws {
    let socketPath = temporarySocketPath(suffix: "read-snapshot")
    let response = CommandResponse(
      ok: true,
      command: "read",
      schemaVersion: "prowl.cli.read.v1"
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["read", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .read(let input) = envelope.command {
      XCTAssertEqual(input.selector, .none)
      XCTAssertNil(input.last)
    } else {
      XCTFail("Expected read command envelope")
    }
  }

  func testReadRejectsInvalidLastBeforeTransport() throws {
    let result = try runProwl(args: ["read", "--last", "0", "--json"])

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "read")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  func testReadRejectsMultipleSelectorsBeforeTransport() throws {
    let result = try runProwl(args: ["read", "--worktree", "Prowl", "--pane", "pane-123", "--json"])

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "read")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  func testReadTextRenderingFromSocket() throws {
    let socketPath = temporarySocketPath(suffix: "read-text")
    let response = try CommandResponse(
      ok: true,
      command: "read",
      schemaVersion: "prowl.cli.read.v1",
      data: RawJSON(encoding: ReadResponseData(
        target: ReadResponseTarget(
          worktree: ListWorktree(
            id: "wt-1",
            name: "main",
            path: "/Projects/App",
            rootPath: "/Projects/App",
            kind: "git"
          ),
          tab: ReadResponseTab(id: "t1", title: "Tab 1", selected: true),
          pane: ReadResponsePane(id: "p1", title: "zsh", cwd: "/Projects/App", focused: true)
        ),
        mode: "last",
        last: 3,
        source: "scrollback",
        truncated: false,
        lineCount: 3,
        text: "a\nb\nc"
      ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["read"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("Read from"), "Missing header: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("mode:"), "Missing mode line: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("source:"), "Missing source line: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("a\nb\nc"), "Missing text body: \(result.stdout)")
  }

  func testReadWaitStablePassesOptionsToEnvelope() throws {
    let socketPath = temporarySocketPath(suffix: "read-wait-stable")
    let response = CommandResponse(
      ok: true,
      command: "read",
      schemaVersion: "prowl.cli.read.v1"
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: [
        "read", "--wait-stable",
        "--stable-interval", "150",
        "--stable-period", "600",
        "--wait-timeout", "5",
        "--json",
      ]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .read(let input) = envelope.command {
      XCTAssertTrue(input.waitStable)
      XCTAssertEqual(input.stableIntervalMs, 150)
      XCTAssertEqual(input.stablePeriodMs, 600)
      XCTAssertEqual(input.waitTimeoutSeconds, 5)
    } else {
      XCTFail("Expected read command envelope")
    }
  }

  func testReadStabilityOptionsRequireWaitStable() throws {
    let result = try runProwl(args: ["read", "--stable-interval", "150", "--json"])

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  func testReadWaitStableRejectsOutOfRangeInterval() throws {
    let result = try runProwl(args: ["read", "--wait-stable", "--stable-interval", "10", "--json"])

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  // MARK: - Handoff command tests

  func testHandoffSaveRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "handoff-save")
    let response = try CommandResponse(
      ok: true,
      command: "handoff",
      schemaVersion: "prowl.cli.handoff.v2",
      data: RawJSON(encoding: makeHandoffPayload(action: .save))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["handoff", "save", "--worktree", "App", "--note", "wip", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .handoff(let input) = envelope.command {
      XCTAssertEqual(input.action, .save)
      XCTAssertEqual(input.selector, .worktree("App"))
      XCTAssertEqual(input.note, "wip")
      XCTAssertTrue(input.launch)
      XCTAssertNil(input.brief)
      XCTAssertFalse(input.contextOnly)
    } else {
      XCTFail("Expected handoff command envelope")
    }

    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, true)
    XCTAssertEqual(payload["command"] as? String, "handoff")
  }

  func testHandoffToSendsInlineBriefAndContextOnly() throws {
    let socketPath = temporarySocketPath(suffix: "handoff-brief")
    let response = try CommandResponse(
      ok: true,
      command: "handoff",
      schemaVersion: "prowl.cli.handoff.v2",
      data: RawJSON(encoding: makeHandoffPayload(action: .toAgent))
    )

    let brief = "# Handoff\n\n## Objective\nShip.\n\n## Current State\nGreen.\n\n## Next Steps\n1. Go."
    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["handoff", "to", "claude", "--brief", brief, "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .handoff(let input) = envelope.command {
      XCTAssertEqual(input.brief, brief)
      XCTAssertFalse(input.contextOnly)
    } else {
      XCTFail("Expected handoff command envelope")
    }

    let contextOnlySocket = temporarySocketPath(suffix: "handoff-no-brief")
    let (contextOnlyRequest, contextOnlyResult) = try runWithMockServer(
      socketPath: contextOnlySocket,
      response: response,
      args: ["handoff", "to", "claude", "--no-brief", "--json"]
    )
    XCTAssertEqual(contextOnlyResult.exitCode, 0)
    let contextOnlyEnvelope = try JSONDecoder().decode(CommandEnvelope.self, from: contextOnlyRequest)
    if case .handoff(let input) = contextOnlyEnvelope.command {
      XCTAssertNil(input.brief)
      XCTAssertTrue(input.contextOnly)
    } else {
      XCTFail("Expected handoff command envelope")
    }
  }

  func testHandoffBriefConflictFailsBeforeTransport() throws {
    let result = try runProwl(args: ["handoff", "to", "claude", "--brief", "x", "--no-brief", "--json"])

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  func testHandoffToRoundTripsOverSocket() throws {
    let socketPath = temporarySocketPath(suffix: "handoff-to")
    let response = try CommandResponse(
      ok: true,
      command: "handoff",
      schemaVersion: "prowl.cli.handoff.v2",
      data: RawJSON(encoding: makeHandoffPayload(action: .toAgent))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["handoff", "to", "claude", "--pane", "p1", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .handoff(let input) = envelope.command {
      XCTAssertEqual(input.action, .toAgent)
      XCTAssertEqual(input.toAgent, "claude")
      XCTAssertEqual(input.selector, .pane("p1"))
      XCTAssertTrue(input.launch)
    } else {
      XCTFail("Expected handoff command envelope")
    }
  }

  func testHandoffToProfileRoundTripsOverSocketWithoutSelector() throws {
    let profileID = UUID()
    let socketPath = temporarySocketPath(suffix: "handoff-to-profile")
    let response = try CommandResponse(
      ok: true,
      command: "handoff",
      schemaVersion: "prowl.cli.handoff.v2",
      data: RawJSON(encoding: HandoffCommandPayload(
        action: .toAgent,
        artifactPath: "/Projects/App/.prowl/handoff/current.md",
        outgoingAgent: "claude",
        toAgent: "codex",
        toProfileID: profileID,
        toProfileName: "Codex Work"
      ))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["handoff", "to", "--agent-profile-id", profileID.uuidString, "--no-launch", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .handoff(let input) = envelope.command {
      XCTAssertEqual(input.action, .toAgent)
      XCTAssertNil(input.toAgent)
      XCTAssertEqual(input.toProfileID, profileID)
      XCTAssertEqual(input.selector, .none)
      XCTAssertFalse(input.launch)
    } else {
      XCTFail("Expected handoff command envelope")
    }

    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["schema_version"] as? String, "prowl.cli.handoff.v2")
    let data = try XCTUnwrap(payload["data"] as? [String: Any])
    XCTAssertEqual(data["to_agent"] as? String, "codex")
    XCTAssertEqual(data["to_profile_id"] as? String, profileID.uuidString)
    XCTAssertEqual(data["to_profile_name"] as? String, "Codex Work")
  }

  func testHandoffToProfileAcceptsExplicitSelector() throws {
    let profileID = UUID()
    let socketPath = temporarySocketPath(suffix: "handoff-to-profile-pane")
    let response = try CommandResponse(
      ok: true,
      command: "handoff",
      schemaVersion: "prowl.cli.handoff.v2",
      data: RawJSON(encoding: makeHandoffPayload(action: .toAgent))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["handoff", "to", "--agent-profile-id", profileID.uuidString, "--pane", "p1", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .handoff(let input) = envelope.command {
      XCTAssertEqual(input.toProfileID, profileID)
      XCTAssertEqual(input.selector, .pane("p1"))
    } else {
      XCTFail("Expected handoff command envelope")
    }
  }

  func testHandoffToProfileValidationFailsBeforeTransport() throws {
    let profileID = UUID().uuidString
    let invalidArguments = [
      ["handoff", "to", "--json"],
      ["handoff", "to", "codex", "--agent-profile-id", profileID, "--json"],
      ["handoff", "to", "App", "--agent-profile-id", profileID, "--json"],
      ["handoff", "to", "--agent-profile-id", "not-a-uuid", "--json"],
    ]

    for arguments in invalidArguments {
      let result = try runProwl(args: arguments)

      XCTAssertNotEqual(result.exitCode, 0, "Expected failure for \(arguments)")
      let payload = try jsonObject(from: result.stdout)
      let error = try XCTUnwrap(payload["error"] as? [String: Any])
      XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
    }
  }

  func testHandoffToNormalizesAgentCaseAndNoLaunch() throws {
    let socketPath = temporarySocketPath(suffix: "handoff-to-no-launch")
    let response = try CommandResponse(
      ok: true,
      command: "handoff",
      schemaVersion: "prowl.cli.handoff.v2",
      data: RawJSON(encoding: makeHandoffPayload(action: .toAgent))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["handoff", "to", "CODEX", "--no-launch", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .handoff(let input) = envelope.command {
      XCTAssertEqual(input.toAgent, "codex")
      XCTAssertFalse(input.launch)
    } else {
      XCTFail("Expected handoff command envelope")
    }
  }

  func testHandoffToAcceptsDetectedAgentToken() throws {
    let socketPath = temporarySocketPath(suffix: "handoff-to-gemini")
    let response = try CommandResponse(
      ok: true,
      command: "handoff",
      schemaVersion: "prowl.cli.handoff.v2",
      data: RawJSON(encoding: makeHandoffPayload(action: .toAgent))
    )

    let (requestData, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["handoff", "to", "gemini", "--no-launch", "--json"]
    )

    XCTAssertEqual(result.exitCode, 0)
    let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: requestData)
    if case .handoff(let input) = envelope.command {
      XCTAssertEqual(input.toAgent, "gemini")
      XCTAssertFalse(input.launch)
    } else {
      XCTFail("Expected handoff command envelope")
    }
  }

  func testHandoffToRejectsUnknownAgentBeforeTransport() throws {
    let result = try runProwl(args: ["handoff", "to", "unknown-agent", "--json"])

    XCTAssertNotEqual(result.exitCode, 0)
    let payload = try jsonObject(from: result.stdout)
    XCTAssertEqual(payload["ok"] as? Bool, false)
    XCTAssertEqual(payload["command"] as? String, "handoff")
    let error = try XCTUnwrap(payload["error"] as? [String: Any])
    XCTAssertEqual(error["code"] as? String, CLIErrorCode.invalidArgument)
  }

  func testHandoffToTextRenderingFromSocket() throws {
    let socketPath = temporarySocketPath(suffix: "handoff-to-text")
    let response = try CommandResponse(
      ok: true,
      command: "handoff",
      schemaVersion: "prowl.cli.handoff.v2",
      data: RawJSON(encoding: HandoffCommandPayload(
        action: .toAgent,
        artifactPath: "/Projects/App/.prowl/handoff/current.md",
        outgoingAgent: "codex",
        toAgent: "claude",
        repos: [
          HandoffRepoPayload(name: "App", branch: "feature", isGit: true, changedFileCount: 3, insertions: 120, deletions: 14)
        ],
        changedFileCount: 3,
        archivedPath: "handoff/archive/2026-06-12T1430-codex-to-claude.md",
        sessionContext: HandoffSessionPayload(
          agent: "codex",
          sessionID: "codex-session",
          paneID: "pane-0",
          paneTitle: "codex",
          source: "terminal-scrollback",
          confidence: "fallback",
          excerptPath: "handoff/sessions/2026-06-12T1430-pane-0.md",
          transcriptPath: "/tmp/codex.jsonl"
        ),
        briefing: "inline",
        hasBriefing: true,
        launchedPane: HandoffPanePayload(
          worktreeID: "App:/Projects/App",
          worktreeName: "App",
          tabID: "tab-1",
          paneID: "pane-9",
          paneTitle: "claude"
        )
      ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["handoff", "to", "claude"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("codex → claude"), "Missing transition header: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("artifact:"), "Missing artifact line: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("briefing:"), "Missing briefing line: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("session:"), "Missing session line: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("launched:"), "Missing launched line: \(result.stdout)")
    XCTAssertTrue(result.stdout.contains("pane-9"), "Missing launched pane id: \(result.stdout)")
  }

  func testHandoffToWithoutLaunchTextExplainsExistingFlag() throws {
    let socketPath = temporarySocketPath(suffix: "handoff-to-no-launch-text")
    let response = try CommandResponse(
      ok: true,
      command: "handoff",
      schemaVersion: "prowl.cli.handoff.v2",
      data: RawJSON(encoding: HandoffCommandPayload(
        action: .toAgent,
        artifactPath: "/Projects/App/.prowl/handoff/current.md",
        outgoingAgent: "codex",
        toAgent: "claude",
        archivedPath: "handoff/archive/2026-06-12T1430-codex-to-claude.md"
      ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["handoff", "to", "claude", "--no-launch"]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("no (--no-launch); take over manually"), result.stdout)
    XCTAssertFalse(result.stdout.contains("use --no-launch handoff"), result.stdout)
  }

  func testHandoffToProfileTextIncludesProfileMetadataAndResolvedRuntime() throws {
    let profileID = UUID()
    let socketPath = temporarySocketPath(suffix: "handoff-to-profile-text")
    let response = try CommandResponse(
      ok: true,
      command: "handoff",
      schemaVersion: "prowl.cli.handoff.v2",
      data: RawJSON(encoding: HandoffCommandPayload(
        action: .toAgent,
        artifactPath: "/Projects/App/.prowl/handoff/current.md",
        outgoingAgent: "claude",
        toAgent: "codex",
        toProfileID: profileID,
        toProfileName: "Codex Work"
      ))
    )

    let (_, result) = try runWithMockServer(
      socketPath: socketPath,
      response: response,
      args: ["handoff", "to", "--agent-profile-id", profileID.uuidString]
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.stdout.contains("claude → codex"), result.stdout)
    XCTAssertTrue(result.stdout.contains("Codex Work"), result.stdout)
    XCTAssertTrue(result.stdout.contains(profileID.uuidString), result.stdout)
  }

  // MARK: - Helpers

  private func makeHandoffPayload(action: HandoffAction) -> HandoffCommandPayload {
    HandoffCommandPayload(
      action: action,
      artifactPath: "/Projects/App/.prowl/handoff/current.md",
      outgoingAgent: "codex",
      toAgent: action == .toAgent ? "claude" : nil,
      repos: [
        HandoffRepoPayload(name: "App", branch: "main", isGit: true, changedFileCount: 1, insertions: 8, deletions: 2)
      ],
      changedFileCount: 1
    )
  }

  private func runWithMockServer(
    socketPath: String,
    response: CommandResponse,
    args: [String]
  ) throws -> (Data, CommandResult) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let responseData = try encoder.encode(response)
    return try runWithMockServer(socketPath: socketPath, responseData: responseData, args: args)
  }

  private func runWithMockServer(
    socketPath: String,
    responseData: Data,
    args: [String]
  ) throws -> (Data, CommandResult) {
    let server = try MockSocketServer(socketPath: socketPath, responseData: responseData)
    defer { server.stop() }
    try server.start()

    let result = try runProwl(
      args: args,
      environment: [ProwlSocket.environmentKey: socketPath]
    )

    let requestData = try XCTUnwrap(server.waitForRequest(timeout: 2.0), "No request received by mock server")
    return (requestData, result)
  }

  private func makeTabPayload(action: TabAction) -> TabCommandPayload {
    TabCommandPayload(action: action, target: makeTabTarget())
  }

  private func makePanePayload(action: PaneAction) -> PaneCommandPayload {
    PaneCommandPayload(action: action, target: makeTabTarget())
  }

  private func makeAgentResponse(
    id: String,
    handle: Int? = nil,
    name: String,
    status: String,
    projectName: String,
    branch: String,
    tabTitle: String,
    session: AgentsResponseSession? = nil
  ) -> AgentsResponseAgent {
    AgentsResponseAgent(
      id: id,
      type: name,
      name: name,
      status: status,
      rawState: status,
      lastChangedAt: "2026-06-13T04:12:25Z",
      project: AgentsResponseProject(name: projectName, branch: branch, path: "/Projects/\(projectName)"),
      worktree: ListWorktree(
        id: "\(projectName):/Projects/\(projectName)",
        name: branch,
        path: "/Projects/\(projectName)",
        rootPath: "/Projects/\(projectName)",
        kind: "git"
      ),
      tab: ListTab(id: "\(id)-tab", title: tabTitle, selected: true),
      pane: AgentsResponsePane(
        id: id,
        handle: handle,
        index: 1,
        title: name,
        cwd: "/Projects/\(projectName)",
        focused: false
      ),
      session: session
    )
  }

  private func makeTabTarget() -> TabTarget {
    TabTarget(
      worktree: TabTargetWorktree(
        id: "App:/Projects/App",
        name: "App",
        path: "/Projects/App",
        rootPath: "/Projects/App",
        kind: "git"
      ),
      tab: TabTargetTab(id: "tab-123", title: "App 1", selected: true),
      pane: TabTargetPane(id: "pane-123", title: "zsh", cwd: "/Projects/App", focused: true)
    )
  }

  private func runProwl(
    args: [String],
    environment: [String: String] = [:],
    stdinData: Data? = nil
  ) throws -> CommandResult {
    let binaryPath = try ensureProwlBinary()
    var mergedEnvironment = ProcessInfo.processInfo.environment
    for (key, value) in environment {
      mergedEnvironment[key] = value
    }
    return try runProcess(
      executable: binaryPath,
      arguments: args,
      currentDirectory: repoRoot.path,
      environment: mergedEnvironment,
      stdinData: stdinData
    )
  }

  private func ensureProwlBinary() throws -> String {
    let candidates = [
      repoRoot.appendingPathComponent(".build/debug/prowl").path,
      repoRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/prowl").path,
      repoRoot.appendingPathComponent(".build/x86_64-apple-macosx/debug/prowl").path,
    ]

    if let existing = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
      return existing
    }

    throw NSError(
      domain: "ProwlCLITests",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "Could not find prowl binary. Checked: \(candidates.joined(separator: ", "))",
      ]
    )
  }

  private func runProcess(
    executable: String,
    arguments: [String],
    currentDirectory: String,
    environment: [String: String]? = nil,
    stdinData: Data? = nil
  ) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
    if let environment {
      process.environment = environment
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    if let stdinData {
      let stdinPipe = Pipe()
      process.standardInput = stdinPipe
      stdinPipe.fileHandleForWriting.write(stdinData)
      stdinPipe.fileHandleForWriting.closeFile()
    } else {
      // Use /dev/null so isatty(stdin) doesn't incorrectly report stdin data.
      process.standardInput = FileHandle.nullDevice
    }

    try process.run()
    process.waitUntilExit()

    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
  }

  private func jsonObject(from text: String) throws -> [String: Any] {
    let data = try XCTUnwrap(text.data(using: .utf8))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func assertNoRawJSONControlCharacters(
    in text: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let data = text.data(using: .utf8) else {
      XCTFail("Output is not UTF-8", file: file, line: line)
      return
    }

    for byte in data where byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D {
      XCTFail("Output contains raw control byte 0x\(String(byte, radix: 16))", file: file, line: line)
    }
  }

  /// Directory for mock-server socket files, kept deliberately short. AF_UNIX
  /// `sun_path` is capped at ~104 bytes; `NSTemporaryDirectory()` alone is ~49,
  /// so `prowl-cli-<suffix>-<uuid>.sock` overflows and `bind()` silently
  /// truncates the path. A truncated path would not match the string we pass to
  /// `unlink()`, leaking the socket file. `/tmp` keeps the full path well under
  /// the limit (and matches the CLI's own socket convention).
  private static let socketDirectory = "/tmp"

  private func temporarySocketPath(suffix: String) -> String {
    let uuid = UUID().uuidString.lowercased()
    let filename = "prowl-cli-\(suffix)-\(uuid).sock"
    let path = (Self.socketDirectory as NSString).appendingPathComponent(filename)
    // Fail fast if a future suffix pushes the path past the sun_path limit,
    // rather than letting bind() truncate and leak the socket again.
    precondition(path.utf8.count <= 103, "Socket path exceeds AF_UNIX sun_path limit: \(path)")
    return path
  }
}

private struct OpenResponseData: Encodable {
  let invocation: String
  let requestedPath: String?
  let resolvedPath: String?
  let resolution: String
  let appLaunched: Bool

  enum CodingKeys: String, CodingKey {
    case invocation
    case requestedPath = "requested_path"
    case resolvedPath = "resolved_path"
    case resolution
    case appLaunched = "app_launched"
    case broughtToFront = "brought_to_front"
  }

  let broughtToFront: Bool
}


private struct ListResponseData: Encodable {
  let count: Int
  let items: [ListResponseItem]
}

private struct ListResponseItem: Encodable {
  let worktree: ListWorktree
  let tab: ListTab
  let pane: ListPane
  let task: ListTask
}

private struct ListWorktree: Encodable {
  let id: String
  let name: String
  let path: String

  enum CodingKeys: String, CodingKey {
    case id
    case name
    case path
    case rootPath = "root_path"
    case kind
  }

  let rootPath: String
  let kind: String
}

private struct ListTab: Encodable {
  let id: String
  let handle: Int?
  let title: String
  let selected: Bool

  init(id: String, handle: Int? = nil, title: String, selected: Bool) {
    self.id = id
    self.handle = handle
    self.title = title
    self.selected = selected
  }
}

private struct ListPane: Encodable {
  let id: String
  let handle: Int?
  let title: String
  let cwd: String?
  let focused: Bool

  init(id: String, handle: Int? = nil, title: String, cwd: String?, focused: Bool) {
    self.id = id
    self.handle = handle
    self.title = title
    self.cwd = cwd
    self.focused = focused
  }
}

private struct ListTask: Encodable {
  let status: String?
}

private struct AgentsResponseData: Encodable {
  let count: Int
  let agents: [AgentsResponseAgent]
}

private struct AgentsResponseAgent: Encodable {
  let id: String
  let type: String
  let name: String
  let status: String

  enum CodingKeys: String, CodingKey {
    case id
    case type
    case name
    case status
    case rawState = "raw_state"
    case lastChangedAt = "last_changed_at"
    case project
    case worktree
    case tab
    case pane
    case session
  }

  let rawState: String
  let lastChangedAt: String
  let project: AgentsResponseProject
  let worktree: ListWorktree
  let tab: ListTab
  let pane: AgentsResponsePane
  let session: AgentsResponseSession?
}

private struct AgentsResponseSession: Encodable {
  let id: String
  let path: String?
  let confidence: String
  let source: String
}

private struct AgentsResponseProject: Encodable {
  let name: String
  let branch: String
  let path: String
}

private struct AgentsResponsePane: Encodable {
  let id: String
  let handle: Int?
  let index: Int
  let title: String
  let cwd: String?
  let focused: Bool

  init(id: String, handle: Int? = nil, index: Int, title: String, cwd: String?, focused: Bool) {
    self.id = id
    self.handle = handle
    self.index = index
    self.title = title
    self.cwd = cwd
    self.focused = focused
  }
}

private struct FocusResponseData: Encodable {
  let requested: FocusRequested

  enum CodingKeys: String, CodingKey {
    case requested
    case resolvedVia = "resolved_via"
    case broughtToFront = "brought_to_front"
    case target
  }

  let resolvedVia: String
  let broughtToFront: Bool
  let target: FocusResponseTarget
}

private struct FocusRequested: Encodable {
  let selector: String
  let value: String?
}

private struct FocusResponseTarget: Encodable {
  let worktree: ListWorktree
  let tab: FocusResponseTab
  let pane: FocusResponsePane
}

private struct FocusResponseTab: Encodable {
  let id: String
  let title: String
  let selected: Bool
}

private struct FocusResponsePane: Encodable {
  let id: String
  let title: String
  let cwd: String?
  let focused: Bool
}

private struct SendResponseData: Encodable {
  let target: SendResponseTarget
  let input: SendResponseInput

  enum CodingKeys: String, CodingKey {
    case target
    case input
    case createdTab = "created_tab"
    case wait
  }

  let createdTab: Bool
  let wait: SendResponseWait?

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(target, forKey: .target)
    try container.encode(input, forKey: .input)
    try container.encode(createdTab, forKey: .createdTab)
    if let wait {
      try container.encode(wait, forKey: .wait)
    } else {
      try container.encodeNil(forKey: .wait)
    }
  }
}

private struct SendResponseTarget: Encodable {
  let worktree: ListWorktree
  let tab: SendResponseTab
  let pane: SendResponsePane
}

private struct SendResponseTab: Encodable {
  let id: String
  let title: String
  let selected: Bool
}

private struct SendResponsePane: Encodable {
  let id: String
  let title: String
  let cwd: String?
  let focused: Bool
}

private struct SendResponseInput: Encodable {
  let source: String
  let characters: Int
  let bytes: Int

  enum CodingKeys: String, CodingKey {
    case source
    case characters
    case bytes
    case trailingEnterSent = "trailing_enter_sent"
  }

  let trailingEnterSent: Bool

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(source, forKey: .source)
    try container.encode(characters, forKey: .characters)
    try container.encode(bytes, forKey: .bytes)
    try container.encode(trailingEnterSent, forKey: .trailingEnterSent)
  }
}

private struct SendResponseWait: Encodable {
  let exitCode: Int?
  let durationMs: Int

  enum CodingKeys: String, CodingKey {
    case exitCode = "exit_code"
    case durationMs = "duration_ms"
  }
}

private struct KeyResponseData: Encodable {
  let requested: KeyResponseRequested
  let key: KeyResponseKey
  let delivery: KeyResponseDelivery
  let target: KeyResponseTarget
}

private struct KeyResponseRequested: Encodable {
  let token: String
  let `repeat`: Int
}

private struct KeyResponseKey: Encodable {
  let normalized: String
  let category: String
}

private struct KeyResponseDelivery: Encodable {
  let attempted: Int
  let delivered: Int
  let mode: String
}

private struct KeyResponseTarget: Encodable {
  let worktree: ListWorktree
  let tab: KeyResponseTab
  let pane: KeyResponsePane
}

private struct KeyResponseTab: Encodable {
  let id: String
  let title: String
  let selected: Bool
}

private struct KeyResponsePane: Encodable {
  let id: String
  let title: String
  let cwd: String?
  let focused: Bool
}

private struct ReadResponseData: Encodable {
  let target: ReadResponseTarget
  let mode: String
  let last: Int?
  let source: String
  let truncated: Bool

  enum CodingKeys: String, CodingKey {
    case target
    case mode
    case last
    case source
    case truncated
    case lineCount = "line_count"
    case text
  }

  let lineCount: Int
  let text: String
}

private struct ReadResponseTarget: Encodable {
  let worktree: ListWorktree
  let tab: ReadResponseTab
  let pane: ReadResponsePane
}

private struct ReadResponseTab: Encodable {
  let id: String
  let title: String
  let selected: Bool
}

private struct ReadResponsePane: Encodable {
  let id: String
  let title: String
  let cwd: String?
  let focused: Bool
}

private struct CommandResult {
  let exitCode: Int32
  let stdout: String
  let stderr: String
}

private final class MockSocketServer: @unchecked Sendable {
  private let socketPath: String
  private let responseData: Data

  private var serverFD: Int32 = -1
  private var receivedRequestData: Data?
  private let lock = NSLock()
  private let requestSemaphore = DispatchSemaphore(value: 0)

  init(socketPath: String, responseData: Data) throws {
    self.socketPath = socketPath
    self.responseData = responseData
  }

  deinit { stop() }

  /// Idempotent teardown: closes the listening socket and removes its file.
  /// Invoked via `defer` from the test helper so cleanup does not rely on
  /// non-deterministic `deinit` timing — the accept loop runs on a background
  /// queue, which can delay ARC release and leave the bound socket file behind.
  func stop() {
    if serverFD >= 0 {
      close(serverFD)
      serverFD = -1
    }
    unlink(socketPath)
  }

  func start() throws {
    unlink(socketPath)

    serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard serverFD >= 0 else {
      throw MockSocketError.socketCreateFailed
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)

    let pathBytes = Array(socketPath.utf8)
    let maxLength = MemoryLayout.size(ofValue: addr.sun_path) - 1
    let copyLength = min(pathBytes.count, maxLength)

    withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
      for index in 0..<copyLength {
        buffer[index] = pathBytes[index]
      }
      buffer[copyLength] = 0
    }

    let bindResult = withUnsafePointer(to: &addr) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPointer in
        bind(serverFD, addrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }

    guard bindResult == 0 else {
      throw MockSocketError.bindFailed
    }

    guard listen(serverFD, 1) == 0 else {
      throw MockSocketError.listenFailed
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let clientFD = accept(self.serverFD, nil, nil)
      guard clientFD >= 0 else { return }
      defer { close(clientFD) }

      do {
        let lengthData = try self.readExact(fd: clientFD, count: 4)
        let bodyLength = lengthData.withUnsafeBytes {
          UInt32(bigEndian: $0.load(as: UInt32.self))
        }
        let body = try self.readExact(fd: clientFD, count: Int(bodyLength))

        self.lock.lock()
        self.receivedRequestData = body
        self.lock.unlock()
        self.requestSemaphore.signal()

        var responseLength = UInt32(self.responseData.count).bigEndian
        try withUnsafeBytes(of: &responseLength) { lengthBytes in
          try self.writeAll(fd: clientFD, bytes: lengthBytes)
        }
        try self.responseData.withUnsafeBytes { bytes in
          try self.writeAll(fd: clientFD, bytes: bytes)
        }
      } catch {
        self.requestSemaphore.signal()
      }
    }
  }

  func waitForRequest(timeout: TimeInterval) -> Data? {
    let result = requestSemaphore.wait(timeout: .now() + timeout)
    guard result == .success else { return nil }

    lock.lock()
    defer { lock.unlock() }
    return receivedRequestData
  }

  private func readExact(fd: Int32, count: Int) throws -> Data {
    var data = Data(capacity: count)
    var remaining = count
    let bufferSize = min(count, 65536)
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 1)
    defer { buffer.deallocate() }

    while remaining > 0 {
      let toRead = min(remaining, bufferSize)
      let readCount = Darwin.read(fd, buffer, toRead)
      guard readCount > 0 else {
        throw MockSocketError.readFailed
      }
      data.append(buffer.assumingMemoryBound(to: UInt8.self), count: readCount)
      remaining -= readCount
    }

    return data
  }

  private func writeAll(fd: Int32, bytes: UnsafeRawBufferPointer) throws {
    var offset = 0
    while offset < bytes.count {
      let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
      guard written > 0 else {
        throw MockSocketError.writeFailed
      }
      offset += written
    }
  }
}

private enum MockSocketError: Error {
  case socketCreateFailed
  case bindFailed
  case listenFailed
  case readFailed
  case writeFailed
}

private final class PermissionDeniedSocket {
  private let socketPath: String
  private var serverFD: Int32 = -1

  init(socketPath: String) {
    self.socketPath = socketPath
  }

  deinit { stop() }

  func start() throws {
    unlink(socketPath)
    serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard serverFD >= 0 else {
      throw MockSocketError.socketCreateFailed
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    let maxLength = MemoryLayout.size(ofValue: addr.sun_path) - 1
    let copyLength = min(pathBytes.count, maxLength)
    withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
      for index in 0..<copyLength {
        buffer[index] = pathBytes[index]
      }
      buffer[copyLength] = 0
    }

    let bindResult = withUnsafePointer(to: &addr) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPointer in
        bind(serverFD, addrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bindResult == 0 else {
      throw MockSocketError.bindFailed
    }
    guard listen(serverFD, 1) == 0 else {
      throw MockSocketError.listenFailed
    }
    guard chmod(socketPath, 0) == 0 else {
      throw MockSocketError.bindFailed
    }
  }

  func stop() {
    if serverFD >= 0 {
      close(serverFD)
      serverFD = -1
    }
    chmod(socketPath, S_IRUSR | S_IWUSR)
    unlink(socketPath)
  }
}
