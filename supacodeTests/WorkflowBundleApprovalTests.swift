import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct WorkflowBundleApprovalTests {
  @Test func approvalBindsLocationAndEveryFileAndCannotApproveChangedCandidate() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = root.appending(path: "test.pwlworkflow")
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    try Data("schema: prowl.workflow/v1".utf8).write(to: bundle.appending(path: "workflow.yaml"))
    let snapshot = try WorkflowBundleSnapshot.read(bundle)
    let store = WorkflowBundleApprovalStore(directory: root.appending(path: "approvals"))
    #expect(try !store.isApproved(snapshot))
    try store.approve(snapshot, now: Date(timeIntervalSince1970: 1))
    #expect(try store.isApproved(snapshot))
    try Data("helper".utf8).write(to: bundle.appending(path: "helper.py"))
    let edited = try WorkflowBundleSnapshot.read(bundle)
    #expect(try !store.isApproved(edited))
    #expect(throws: (any Error).self) { try store.approve(snapshot, now: Date()) }
    let other = root.appending(path: "other.pwlworkflow")
    try edited.copy(to: other)
    #expect(try !store.isApproved(WorkflowBundleSnapshot.read(other)))
  }
}
