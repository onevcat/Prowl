import Foundation
import ProwlCLIShared

nonisolated struct WorkflowBundleReview: Equatable {
  let snapshot: WorkflowBundleSnapshot
  let scripts: [WorkflowScriptAction]
  let changes: [WorkflowBundleSnapshot.Change]
  var approved: Bool
  var selectedFile = "workflow.yaml"
  var error: String?

  var filePaths: [String] { Set(snapshot.files.keys).union(changes.map(\.path)).sorted() }

  var preview: String {
    guard let data = snapshot.files[selectedFile] else { return "This file was removed from the bundle." }
    guard data.count <= 131_072 else { return "This file is too large to preview. Open the bundle to inspect it." }
    return String(data: data, encoding: .utf8) ?? "Binary file. Open the bundle to inspect it."
  }

  static func load(url: URL, scope: WorkflowScope) throws -> Self {
    let file = WorkflowDiscovery.load(url: url, scope: scope, context: .init(scope: scope))
    guard let snapshot = file.snapshot, file.isValid else {
      throw WorkflowExpressionError.type(file.diagnostics.map(\.message).joined(separator: "\n"))
    }
    let previous = try WorkflowBundleApprovalStore().record(for: snapshot)
    return Self(
      snapshot: snapshot, scripts: file.actions.values.sorted { $0.id < $1.id },
      changes: WorkflowBundleSnapshot.changes(current: snapshot.fileFingerprints, previous: previous?.files ?? [:]),
      approved: previous?.fingerprint == snapshot.fingerprint)
  }
}
