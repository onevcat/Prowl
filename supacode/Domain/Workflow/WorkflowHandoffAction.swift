import Foundation
import ProwlCLIShared

nonisolated enum WorkflowHandoffAction {
  static func save(inputs: [String: WorkflowJSONValue], context: WorkflowActionContext) async throws
    -> WorkflowJSONValue
  {
    guard Set(inputs.keys) == ["briefing"], case .string(let path) = inputs["briefing"] else {
      throw WorkflowActionError.missingInput("briefing")
    }
    let runDirectory =
      context.runDirectory
      ?? WorkflowRunPaths.runDirectory(root: context.rootURL, runID: context.runID)
    let source = URL(filePath: path).standardizedFileURL
    let canonicalRun = WorkflowHistoryStorage.canonicalURL(runDirectory)
    let canonicalSource = WorkflowHistoryStorage.canonicalURL(source)
    guard canonicalSource.path.hasPrefix(canonicalRun.path + "/"),
      try FileManager.default.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType == .typeRegular
    else { throw WorkflowActionError.unsafePath(path) }
    let handle = try FileHandle(forReadingFrom: source)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: WorkflowSizeLimits.payload + 1) ?? Data()
    guard data.count <= WorkflowSizeLimits.payload, let text = String(data: data, encoding: .utf8),
      let briefing = HandoffStore.validatedBriefing(from: text)
    else { throw WorkflowActionError.invalidBriefing(path: path) }

    let store = HandoffStore(rootURL: context.rootURL)
    try validateDestinations(store)
    try Task.checkCancellation()
    let result = try await HandoffCoordinator(store: store).makeCheckpoint(
      outgoingAgent: context.outgoingAgent, sessionContext: context.sessionContext,
      note: "workflow=\(context.runID.uuidString)", briefing: briefing, now: context.now)
    // Build this packet from this save's values, not the shared current/context files:
    // another handoff may already have replaced those while the receiver is starting.
    let appendix = store.buildAppendix(
      outgoingAgent: context.outgoingAgent, sessionContext: result.sessionContext,
      repos: result.repos, changedFiles: result.changedFiles, now: context.now)
    let packet = try HandoffStore.reserveFileURL(
      in: store.archiveDirectory, stem: "workflow-\(context.runID.uuidString)", fileExtension: "md")
    try (briefing + "\n" + appendix + "\n").write(to: packet, atomically: true, encoding: .utf8)
    return .object([
      "path": .string(packet.path), "current_path": .string(store.currentURL.path),
      "context_path": .string(store.contextURL.path),
    ])
  }

  private static func validateDestinations(_ store: HandoffStore) throws {
    for directory in [
      store.rootURL.appending(path: ".prowl"), store.handoffDirectory,
      store.archiveDirectory, store.sessionDirectory,
    ] {
      if let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path),
        attributes[.type] as? FileAttributeType != .typeDirectory
      {
        throw WorkflowActionError.unsafePath(directory.path)
      }
    }
    for file in [store.currentURL, store.contextURL, store.logURL, store.ignoreURL] {
      if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
        attributes[.type] as? FileAttributeType != .typeRegular
      {
        throw WorkflowActionError.unsafePath(file.path)
      }
    }
  }
}
