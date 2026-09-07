import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct WorkflowNativeActionsTests {
  nonisolated private static let now = Date(timeIntervalSince1970: 1_760_000_000)

  private func makeRepo() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "workflow-actions-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    for arguments in [
      ["init", "-q", "-b", "main"], ["config", "user.email", "t@example.com"], ["config", "user.name", "T"],
    ] {
      try runGit(arguments, in: url)
    }
    try "hello\n".write(to: url.appending(path: "README.md"), atomically: true, encoding: .utf8)
    try runGit(["add", "."], in: url)
    try runGit(["commit", "-q", "-m", "init"], in: url)
    return url
  }

  private func runGit(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path(percentEncoded: false)] + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw NSError(domain: "WorkflowNativeActionsTests.Git", code: Int(process.terminationStatus))
    }
  }

  private func context(root: URL) -> WorkflowActionContext {
    WorkflowActionContext(
      runID: UUID(),
      rootURL: root,
      roleAgents: ["source": "claude", "receiver": "codex", "shell": nil],
      outgoingAgent: "claude",
      now: Self.now)
  }

  @Test func worktreeContextWritesInvocationArtifactsAndRecords() async throws {
    let root = try makeRepo()
    defer { try? FileManager.default.removeItem(at: root) }
    let invocation = context(root: root)
    let outputs = try await WorkflowNativeActionRunner().execute(
      actionID: "builtin:collect-worktree-context", inputs: [:], context: invocation)
    guard case .object(let output) = outputs["output"], case .string(let path) = output["path"] else {
      Issue.record("Missing typed repository result")
      return
    }
    #expect(output["branch"] == .string("main"))
    #expect(path.hasPrefix(invocation.directory.path + "/artifacts/"))
    #expect(try String(contentsOf: URL(filePath: path), encoding: .utf8).contains("Branch: main"))
    for file in ["request.json", "result.json", "execution.json"] {
      #expect(FileManager.default.fileExists(atPath: invocation.directory.appending(path: file).path))
    }
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".prowl/handoff").path))
  }

  @Test func explicitRootAcceptsItsCanonicalDirectoryWithoutATrailingSlash() async throws {
    let root = try makeRepo()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = WorkflowHistoryStorage.canonicalURL(root).path
    let output = try await WorkflowNativeActionRunner().execute(
      actionID: "builtin:collect-worktree-context", inputs: ["root": .string(path)], context: context(root: root))
    #expect(output["output"] != nil)
  }

  @Test func scriptPipelinePublishesOnlyValidatedResultsAndKeepsFailureRecords() async throws {
    let root = try makeRepo()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "sample.pwlworkflow")
    let action = source.appending(path: "actions/echo")
    try FileManager.default.createDirectory(at: action, withIntermediateDirectories: true)
    try """
    schema: prowl.workflow/v1
    id: sample
    name: Sample
    steps: [{id: echo, action: 'local:echo', with: {count: 3}}]
    """.write(to: source.appending(path: "workflow.yaml"), atomically: true, encoding: .utf8)
    try """
    schema: prowl.action/v1
    name: Echo
    input_schema: {type: object, properties: {count: {type: integer}}, required: [count]}
    output_schema: {type: object, properties: {count: {type: integer}}, required: [count]}
    backend: {type: script, interpreter: /bin/sh, entrypoint: main.sh}
    """.write(to: action.appending(path: "action.yaml"), atomically: true, encoding: .utf8)
    try "cat >/dev/null; printf diagnostic >&2; printf '{\"count\":3}'"
      .write(to: action.appending(path: "main.sh"), atomically: true, encoding: .utf8)
    let file = WorkflowDiscovery.load(url: source, scope: .repo, context: .init(scope: .repo))
    #expect(file.isValid)
    let prepared = try WorkflowPreparedBundle(source: file, directory: root.appending(path: "copy"), environment: [:])
    func invocation() -> WorkflowActionContext {
      .init(runID: UUID(), rootURL: root, roleAgents: [:], outgoingAgent: nil, now: Self.now, bundle: prepared)
    }
    let valid = invocation()
    let result = try await WorkflowNativeActionRunner().execute(
      actionID: "local:echo", inputs: ["count": .integer(3)], context: valid)
    #expect(result["output"] == .object(["count": .integer(3)]))
    let request = try JSONDecoder().decode(
      WorkflowJSONValue.self, from: Data(contentsOf: valid.directory.appending(path: "request.json")))
    guard case .object(let fields) = request, case .object(let context) = fields["context"],
      case .object(let metadata) = context["action"]
    else {
      Issue.record("Missing action request context")
      return
    }
    #expect(metadata["execution_id"] == .string(valid.executionID))
    #expect(metadata["id"] == nil)
    #expect(metadata["working_directory"] == .string(root.path))
    #expect(metadata["artifacts_directory"] == .string(valid.directory.appending(path: "artifacts").path))
    #expect(result["output_path"] == .string(valid.directory.appending(path: "result.json").path))
    #expect(try String(contentsOf: valid.directory.appending(path: "stderr.log"), encoding: .utf8) == "diagnostic")
    let invalid = invocation()
    await #expect(throws: (any Error).self) {
      try await WorkflowNativeActionRunner().execute(
        actionID: "local:echo", inputs: ["count": .string("wrong")], context: invalid)
    }
    #expect(!FileManager.default.fileExists(atPath: invalid.directory.appending(path: "result.json").path))
    #expect(
      try String(contentsOf: invalid.directory.appending(path: "execution.json"), encoding: .utf8).contains("failed"))
    try "changed".write(
      to: prepared.directory.appending(path: "actions/echo/main.sh"),
      atomically: true, encoding: .utf8)
    let modified = invocation()
    await #expect(throws: WorkflowBundleIntegrityError.self) {
      try await WorkflowNativeActionRunner().execute(
        actionID: "local:echo", inputs: ["count": .integer(3)], context: modified)
    }
  }

  @Test func pythonHelpersDoNotMutateTheFixedBundle() async throws {
    let root = try makeRepo()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "python.pwlworkflow")
    let action = source.appending(path: "actions/report")
    try FileManager.default.createDirectory(at: action, withIntermediateDirectories: true)
    try """
    schema: prowl.workflow/v1
    id: python
    name: Python
    steps: [{id: report, action: 'local:report'}]
    """.write(to: source.appending(path: "workflow.yaml"), atomically: true, encoding: .utf8)
    try """
    schema: prowl.action/v1
    name: Report
    input_schema: {type: object}
    output_schema: {type: object, properties: {count: {type: integer}}, required: [count]}
    backend: {type: script, interpreter: /usr/bin/python3, entrypoint: main.py}
    """.write(to: action.appending(path: "action.yaml"), atomically: true, encoding: .utf8)
    // Apple Python redirects caches globally; use the standard CPython cache location.
    try "import sys; sys.pycache_prefix = None; import json, helpers; print(json.dumps({'count': helpers.count}))"
      .write(to: action.appending(path: "main.py"), atomically: true, encoding: .utf8)
    try "count = 3\n".write(to: action.appending(path: "helpers.py"), atomically: true, encoding: .utf8)
    let file = WorkflowDiscovery.load(url: source, scope: .repo, context: .init(scope: .repo))
    let prepared = try WorkflowPreparedBundle(source: file, directory: root.appending(path: "copy"), environment: [:])
    for _ in 0..<2 {
      let invocation = WorkflowActionContext(
        runID: UUID(), rootURL: root, roleAgents: [:], outgoingAgent: nil, now: Self.now, bundle: prepared)
      let result = try await WorkflowNativeActionRunner().execute(
        actionID: "local:report", inputs: [:], context: invocation)
      #expect(result["output"] == .object(["count": .integer(3)]))
      try prepared.verifyIntegrity()
    }
  }

  @Test func failedScriptsRetainRawOutputWithoutPublishingAResult() async throws {
    let root = try makeRepo()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "failure.pwlworkflow")
    let action = source.appending(path: "actions/report")
    try FileManager.default.createDirectory(at: action, withIntermediateDirectories: true)
    try """
    schema: prowl.workflow/v1
    id: failure
    name: Failure
    steps: [{id: report, action: 'local:report'}]
    """.write(to: source.appending(path: "workflow.yaml"), atomically: true, encoding: .utf8)
    try """
    schema: prowl.action/v1
    name: Report
    input_schema: {type: object}
    output_schema: {type: object}
    backend: {type: script, interpreter: /bin/sh, entrypoint: main.sh}
    """.write(to: action.appending(path: "action.yaml"), atomically: true, encoding: .utf8)
    for script in ["printf broken; printf diagnostic >&2", "printf broken; printf diagnostic >&2; exit 7"] {
      try script.write(to: action.appending(path: "main.sh"), atomically: true, encoding: .utf8)
      let file = WorkflowDiscovery.load(url: source, scope: .repo, context: .init(scope: .repo))
      let prepared = try WorkflowPreparedBundle(
        source: file, directory: root.appending(path: UUID().uuidString), environment: [:])
      let invocation = WorkflowActionContext(
        runID: UUID(), rootURL: root, roleAgents: [:], outgoingAgent: nil, now: Self.now, bundle: prepared)
      await #expect(throws: (any Error).self) {
        try await WorkflowNativeActionRunner().execute(actionID: "local:report", inputs: [:], context: invocation)
      }
      #expect(
        (try? String(contentsOf: invocation.directory.appending(path: "stdout.log"), encoding: .utf8)) == "broken")
      #expect(
        (try? String(contentsOf: invocation.directory.appending(path: "stderr.log"), encoding: .utf8)) == "diagnostic")
      #expect(!FileManager.default.fileExists(atPath: invocation.directory.appending(path: "result.json").path))
      for name in ["request.json", "execution.json"] {
        #expect(FileManager.default.fileExists(atPath: invocation.directory.appending(path: name).path))
      }
    }
  }

  @Test func nativeActionRejectsOutsideRootAndRemovedActions() async throws {
    let root = try makeRepo()
    defer { try? FileManager.default.removeItem(at: root) }
    await #expect(throws: WorkflowActionError.unsafePath("/tmp")) {
      try await WorkflowNativeActionRunner().execute(
        actionID: "builtin:collect-worktree-context", inputs: ["root": "/tmp"], context: context(root: root))
    }
    await #expect(throws: WorkflowActionError.unknownAction("handoff.transition")) {
      try await WorkflowNativeActionRunner().execute(
        actionID: "handoff.transition", inputs: [:], context: context(root: root))
    }
  }
}
