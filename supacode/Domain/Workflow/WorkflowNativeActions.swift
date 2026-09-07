import Foundation
import ProwlCLIShared

nonisolated struct WorkflowActionContext: Sendable {
  let runID: UUID
  let rootURL: URL
  let roleAgents: [String: String?]
  let outgoingAgent: String?
  let sessionContext: HandoffStore.SessionContext?
  let now: Date
  let stepID: String
  let executionID: String
  let attempt: Int
  let bundle: WorkflowPreparedBundle?
  let values: [String: WorkflowJSONValue]
  let runDirectory: URL?

  init(
    runID: UUID, rootURL: URL, roleAgents: [String: String?], outgoingAgent: String?,
    sessionContext: HandoffStore.SessionContext? = nil, now: Date, stepID: String = "action",
    executionID: String = UUID().uuidString, attempt: Int = 1, bundle: WorkflowPreparedBundle? = nil,
    values: [String: WorkflowJSONValue] = [:], runDirectory: URL? = nil
  ) {
    self.runID = runID
    self.rootURL = rootURL
    self.roleAgents = roleAgents
    self.outgoingAgent = outgoingAgent
    self.sessionContext = sessionContext
    self.now = now
    self.stepID = stepID
    self.executionID = executionID
    self.attempt = attempt
    self.bundle = bundle
    self.values = values
    self.runDirectory = runDirectory
  }

  var directory: URL {
    (runDirectory ?? WorkflowRunPaths.runDirectory(root: rootURL, runID: runID))
      .appending(path: "actions/\(stepID)/\(executionID)")
  }
}

nonisolated enum WorkflowActionError: Error, Equatable, Sendable {
  case unknownAction(String)
  case missingInput(String)
  case unknownRole(String)
  case unreadableBriefing(path: String)
  case invalidBriefing(path: String)
  case unsafePath(String)
  case failed(String)

  var message: String { String(describing: self) }
}

protocol WorkflowActionExecuting: Sendable {
  func execute(actionID: String, inputs: [String: WorkflowJSONValue], context: WorkflowActionContext) async throws
    -> [String: WorkflowJSONValue]
}

nonisolated struct WorkflowNativeActionRunner: WorkflowActionExecuting {
  func execute(actionID: String, inputs: [String: WorkflowJSONValue], context: WorkflowActionContext) async throws
    -> [String: WorkflowJSONValue]
  {
    try Task.checkCancellation()
    guard WorkflowSchema.isSlug(context.stepID), UUID(uuidString: context.executionID) != nil else {
      throw WorkflowActionError.unsafePath(context.executionID)
    }
    defer { WorkflowActionProcessRegistry().remove(executionID: context.executionID) }
    let directory = context.directory
    let artifacts = try prepareDirectory(context)
    var snapshot = context.values["context"] ?? .object([:])
    if case .object(var fields) = snapshot {
      fields["action"] = .object([
        "execution_id": .string(context.executionID), "step_id": .string(context.stepID),
        "attempt": .integer(context.attempt), "working_directory": .string(context.rootURL.path),
        "artifacts_directory": .string(artifacts.path),
      ])
      snapshot = .object(fields)
    }
    let request = WorkflowJSONValue.object([
      "protocol": .string("prowl.action/v1"),
      "input": WorkflowJSON.object(inputs), "context": snapshot,
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard try encoder.encode(WorkflowJSON.object(inputs)).count <= WorkflowSizeLimits.payload else {
      throw WorkflowActionError.failed("Action input exceeds 16 MiB.")
    }
    let requestData = try encoder.encode(request)
    try requestData.write(to: directory.appending(path: "request.json"), options: .atomic)
    try Data().write(to: directory.appending(path: "stdout.log"), options: .atomic)
    try Data().write(to: directory.appending(path: "stderr.log"), options: .atomic)
    try record(context, state: "running", detail: nil)
    do {
      try context.bundle?.verifyIntegrity()
      let output: WorkflowJSONValue
      if actionID == "builtin:collect-worktree-context" {
        try WorkflowActionRegistry.worktreeContextInput.validate(.object(inputs))
        output = try await collectWorktreeContext(inputs: inputs, context: context, artifacts: artifacts)
        try WorkflowActionRegistry.worktreeContextOutput.validate(output)
      } else {
        output = try await script(actionID: actionID, inputs: inputs, context: context, request: requestData)
      }
      try Task.checkCancellation()
      try context.bundle?.verifyIntegrity()
      let resultURL = directory.appending(path: "result.json")
      try encoder.encode(output).write(to: resultURL, options: .atomic)
      try record(context, state: "succeeded", detail: nil)
      return ["output": output, "output_path": .string(resultURL.path)]
    } catch {
      if let processError = error as? WorkflowScriptExecutionError {
        try? processError.stdout.write(to: directory.appending(path: "stdout.log"), options: .atomic)
        try? processError.stderr.write(to: directory.appending(path: "stderr.log"), options: .atomic)
      }
      try? record(
        context,
        state: (error is CancellationError || (error as? WorkflowScriptExecutionError)?.code == "cancelled")
          ? "cancelled" : "failed", detail: "\(error)")
      throw error
    }
  }

  private func prepareDirectory(_ context: WorkflowActionContext) throws -> URL {
    let store = WorkflowRunStore(rootURL: context.rootURL, directory: context.runDirectory)
    try store.ensureLayout(runID: context.runID)
    var directory = try store.containedRunDirectory(runID: context.runID)
    for component in ["actions", context.stepID, context.executionID, "artifacts"] {
      directory = directory.appending(path: component, directoryHint: .isDirectory)
      if let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path) {
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
          component != context.executionID
        else { throw WorkflowActionError.unsafePath(directory.path) }
      } else {
        try FileManager.default.createDirectory(
          at: directory, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
      }
    }
    return directory
  }

  private func script(
    actionID: String, inputs: [String: WorkflowJSONValue], context: WorkflowActionContext,
    request: Data
  ) async throws -> WorkflowJSONValue {
    guard actionID.hasPrefix("local:"), let bundle = context.bundle,
      let action = bundle.actions[String(actionID.dropFirst(6))], let interpreter = bundle.interpreters[action.id]
    else { throw WorkflowActionError.unknownAction(actionID) }
    try action.validateInput(WorkflowJSON.object(inputs))
    let entrypoint = bundle.directory.appending(path: "actions/\(action.id)/\(action.entrypoint)")
    let result = try await WorkflowScriptExecutor.run(
      .init(
        executable: interpreter,
        arguments: [entrypoint.path] + action.arguments, directory: context.rootURL,
        environment: WorkflowPreparedBundle.environment(for: action, inherited: ProcessInfo.processInfo.environment)
      ).limits(timeout: TimeInterval(action.timeoutSeconds)),
      request: request,
      onSpawn: { pid in
        try WorkflowActionProcessRegistry().register(executionID: context.executionID, pid: pid)
      })
    try result.stdout.write(to: context.directory.appending(path: "stdout.log"), options: .atomic)
    try result.stderr.write(to: context.directory.appending(path: "stderr.log"), options: .atomic)
    let output = try JSONDecoder().decode(WorkflowJSONValue.self, from: result.stdout)
    try action.validateOutput(output)
    return output
  }

  private func collectWorktreeContext(
    inputs: [String: WorkflowJSONValue], context: WorkflowActionContext, artifacts: URL
  )
    async throws -> WorkflowJSONValue
  {
    guard Set(inputs.keys).isSubset(of: ["root"]) else {
      throw WorkflowActionError.failed("Unknown collect-worktree-context input.")
    }
    var root = WorkflowHistoryStorage.canonicalURL(context.rootURL)
    if let input = inputs["root"] {
      guard case .string(let path) = input else { throw WorkflowActionError.failed("root must be a string.") }
      let candidate = WorkflowHistoryStorage.canonicalURL(URL(filePath: path, relativeTo: root))
      guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
        throw WorkflowActionError.unsafePath(path)
      }
      root = candidate
    }
    let branch = try await git(["branch", "--show-current"], root: root, executionID: context.executionID)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let status = try await git(["status", "--short"], root: root, executionID: context.executionID)
    let diff = try await git(["diff", "--stat"], root: root, executionID: context.executionID)
    let path = artifacts.appending(path: "context.md")
    try "# Repository Context\n\nBranch: \(branch)\n\n## Status\n\n\(status)\n## Diff\n\n\(diff)"
      .write(to: path, atomically: true, encoding: .utf8)
    return .object(["path": .string(path.path), "branch": .string(branch)])
  }

  private func git(_ arguments: [String], root: URL, executionID: String) async throws -> String {
    let result = try await WorkflowScriptExecutor.run(
      .init(
        executable: "/usr/bin/git", arguments: arguments,
        directory: root, environment: ["PATH": "/usr/bin:/bin", "GIT_TERMINAL_PROMPT": "0"]
      ).limits(timeout: 30),
      request: Data(),
      onSpawn: { pid in
        try WorkflowActionProcessRegistry().register(executionID: executionID, pid: pid)
      })
    return String(bytes: result.stdout, encoding: .utf8) ?? ""
  }

  private func record(_ context: WorkflowActionContext, state: String, detail: String?) throws {
    let record = WorkflowJSONValue.object([
      "id": .string(context.executionID), "step_id": .string(context.stepID),
      "attempt": .integer(context.attempt), "state": .string(state),
      "started_at": .string(context.now.ISO8601Format()),
      "finished_at": state == "running" ? .null : .string(Date().ISO8601Format()),
      "detail": detail.map(WorkflowJSONValue.string) ?? .null,
    ])
    try JSONEncoder().encode(record).write(to: context.directory.appending(path: "execution.json"), options: .atomic)
  }
}
