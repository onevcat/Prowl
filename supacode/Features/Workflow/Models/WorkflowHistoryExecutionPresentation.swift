import Foundation
import ProwlCLIShared

nonisolated enum WorkflowHistoryExecution {
  static func promptURL(_ invocation: WorkflowRunRecordInvocation, directory: URL) -> URL? {
    guard WorkflowSchema.isSlug(invocation.step), invocation.ordinal > 0, let path = invocation.promptPath else {
      return nil
    }
    let expected = WorkflowRunPaths.promptURL(
      runDirectory: directory, stepID: invocation.step, ordinal: invocation.ordinal)
    let recorded = path.hasPrefix("/") ? URL(filePath: path) : directory.appending(path: path)
    guard recorded.standardizedFileURL == expected.standardizedFileURL else { return nil }
    return expected
  }

  static func agentStatus(_ invocation: WorkflowRunRecordInvocation) -> String? {
    if invocation.kind == .launch {
      guard invocation.target?.pane != nil else { return "Agent has not started." }
      return "Agent started."
    }
    return nil
  }

  static func actionInput(_ data: Data) throws -> [String: WorkflowJSONValue] {
    struct Request: Decodable { let input: [String: WorkflowJSONValue] }
    let input = try JSONDecoder().decode(Request.self, from: data).input
    try WorkflowJSON.validate(.object(input))
    return input
  }
}
