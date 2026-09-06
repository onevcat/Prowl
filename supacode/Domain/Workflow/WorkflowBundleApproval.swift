import CryptoKit
import Foundation
import ProwlCLIShared

/// The only grant call site is the native bundle review reducer. CLI admission can only read.
nonisolated struct WorkflowBundleApprovalStore {
  struct Record: Codable, Equatable, Sendable {
    let source: String
    let fingerprint: String
    let files: [String: String]
    let approvedAt: Date
  }

  let directory: URL

  init(
    directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: "Prowl/WorkflowApprovals")
  ) {
    self.directory = directory
  }

  func record(for snapshot: WorkflowBundleSnapshot) throws -> Record? {
    let url = recordURL(snapshot)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
    return record.source == snapshot.source.path ? record : nil
  }

  func isApproved(_ snapshot: WorkflowBundleSnapshot) throws -> Bool {
    try record(for: snapshot)?.fingerprint == snapshot.fingerprint
  }

  func approve(_ snapshot: WorkflowBundleSnapshot, now: Date) throws {
    // Approval uses the displayed candidate. An edit while the sheet was open requires a new review.
    guard try WorkflowBundleSnapshot.read(snapshot.source).fingerprint == snapshot.fingerprint else {
      throw WorkflowExpressionError.type("Bundle changed while it was being reviewed. Reopen the review.")
    }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let record = Record(
      source: snapshot.source.path, fingerprint: snapshot.fingerprint,
      files: snapshot.fileFingerprints, approvedAt: now)
    try JSONEncoder().encode(record).write(to: recordURL(snapshot), options: .atomic)
  }

  private func recordURL(_ snapshot: WorkflowBundleSnapshot) -> URL {
    let key = SHA256.hash(data: Data(snapshot.source.path.utf8)).map { String(format: "%02x", $0) }.joined()
    return directory.appending(path: key + ".json")
  }
}
