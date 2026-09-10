import AppKit
import Foundation
import ProwlCLIShared

@MainActor
enum WorkflowHistoryOutput {
  static func open(
    _ intent: WorkflowHistoryOutputIntent, storage: WorkflowHistoryStorage,
    operations: WorkflowHistoryOperations
  ) async throws {
    switch intent {
    case .keep(let directory): try await operations.keep(directory, true)
    case .export(let directory): _ = try await operations.export(directory)
    case .openFile(let url):
      try storage.validate(url)
      guard NSWorkspace.shared.open(url) else { throw CocoaError(.fileReadUnknown) }
    case .reveal(let url):
      try storage.validate(url)
      NSWorkspace.shared.activateFileViewerSelecting([url])
    case .copyFile(let url):
      let data = try await Task.detached(priority: .utility) {
        try storage.read(url, limit: WorkflowHistoryTextPreview.maximumBytes)
      }.value
      guard let text = String(bytes: data, encoding: .utf8) else {
        throw CocoaError(.fileReadInapplicableStringEncoding)
      }
      copy(text)
    case .copyText(let text): copy(text)
    case .openArtifact(let url, let worktree):
      try WorkflowHistoryArtifact.validate(url, worktree: worktree, storage: storage)
      guard NSWorkspace.shared.open(url) else { throw CocoaError(.fileReadUnknown) }
    case .revealArtifact(let url, let worktree):
      try WorkflowHistoryArtifact.validate(url, worktree: worktree, storage: storage)
      NSWorkspace.shared.activateFileViewerSelecting([url])
    case .openText(let text, let name):
      try await openData(Data(text.utf8), name: name)
    case .openJSON(let output):
      let data = try await Task.detached(priority: .utility) { try encode(output) }.value
      try await openData(data, name: "output.json")
    case .copyJSON(let output):
      let data = try await Task.detached(priority: .utility) { try encode(output) }.value
      copy(String(bytes: data, encoding: .utf8) ?? "")
    }
  }

  nonisolated private static func encode(_ output: [String: WorkflowJSONValue]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(output)
  }

  private static func openData(_ data: Data, name: String) async throws {
    let url = try await Task.detached(priority: .utility) {
      let directory = FileManager.default.temporaryDirectory.appending(
        path: "Prowl-Workflow-Preview-\(UUID().uuidString)")
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let url = directory.appending(path: name)
      try data.write(to: url, options: .atomic)
      return url
    }.value
    guard NSWorkspace.shared.open(url) else { throw CocoaError(.fileReadUnknown) }
  }

  private static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
