import Foundation
import Testing
@testable import ProwlCLIShared

struct WorkflowBundleTests {
  @Test func fingerprintIncludesHelpersAndAssets() throws {
    let root = try makeBundle()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try WorkflowBundleSnapshot.read(root)
    try Data("changed".utf8).write(to: root.appending(path: "helper.txt"))
    let second = try WorkflowBundleSnapshot.read(root)
    #expect(first.fingerprint != second.fingerprint)
    #expect(second.changes(from: first) == [.init(path: "helper.txt", kind: .modified)])
  }

  @Test func rejectsSymlinksEvenWhenTheyStayInsideBundle() throws {
    let root = try makeBundle()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(atPath: root.appending(path: "link").path, withDestinationPath: "helper.txt")
    #expect(throws: (any Error).self) { try WorkflowBundleSnapshot.read(root) }
  }

  @Test func fixedCopyHasSameFingerprintAndSourceEditsDoNotChangeIt() throws {
    let root = try makeBundle()
    let copy = root.deletingLastPathComponent().appending(path: UUID().uuidString + ".pwlworkflow")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: copy)
    }
    let snapshot = try WorkflowBundleSnapshot.read(root)
    try snapshot.copy(to: copy)
    let permissions = try FileManager.default.attributesOfItem(atPath: copy.appending(path: "helper.txt").path)
    #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o400)
    #expect(throws: (any Error).self) { try Data("edit".utf8).write(to: copy.appending(path: "helper.txt")) }
    try Data("edit".utf8).write(to: root.appending(path: "helper.txt"))
    #expect(try WorkflowBundleSnapshot.read(copy).fingerprint == snapshot.fingerprint)
    #expect(try WorkflowBundleSnapshot.read(root).fingerprint != snapshot.fingerprint)
  }

  @Test func discoversBundlesAndReportsLooseYAMLAsUnsupported() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let bundle = directory.appending(path: "demo.pwlworkflow")
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    let yaml = "schema: prowl.workflow/v1\nid: demo\nname: Demo\nsteps: [{id: done, notify: done}]"
    try Data(yaml.utf8).write(to: bundle.appending(path: "workflow.yaml"))
    try Data(yaml.utf8).write(to: directory.appending(path: "old.yaml"))
    let files = try WorkflowDiscovery.files(in: directory, scope: .user, context: .init(scope: .user))
    #expect(files.count == 2)
    #expect(files.first { $0.url.lastPathComponent == "demo.pwlworkflow" }?.isValid == true)
    #expect(files.first { $0.url.lastPathComponent == "old.yaml" }?.diagnostics.contains {
      $0.code == "unsupported_format"
    } == true)
  }

  private func makeBundle() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".pwlworkflow")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("schema: prowl.workflow/v1".utf8).write(to: root.appending(path: "workflow.yaml"))
    try Data("helper".utf8).write(to: root.appending(path: "helper.txt"))
    return root
  }
}
