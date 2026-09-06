import Foundation
import ProwlCLIShared
import XCTest

final class WorkflowDiscoveryTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-workflow-discovery-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func directory(_ name: String) throws -> URL {
    let url = root.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func write(_ yaml: String, to directory: URL, name: String) throws {
    try FileManager.default.createDirectory(at: directory.appending(path: name), withIntermediateDirectories: true)
    try Data(yaml.utf8).write(to: directory.appending(path: name + "/workflow.yaml"))
  }

  private func context(_ scope: WorkflowScope) -> WorkflowValidationContext {
    WorkflowValidationContext(scope: scope, bundledSkillIDs: ["prowl.adversarial-reviewer"])
  }

  func testUnreadableDirectoriesThrowInsteadOfHidingTheirFiles() throws {
    let user = try directory("user")
    try write(WorkflowFixtures.minimal(id: "demo"), to: user, name: "demo.pwlworkflow")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: user.path(percentEncoded: false))
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: user.path(percentEncoded: false)) }
    XCTAssertThrowsError(try WorkflowDiscovery.files(in: user, scope: .user, context: context(.user)))
    XCTAssertThrowsError(
      try WorkflowDiscovery.catalog(sources: WorkflowSources(bundle: nil, user: user, repo: nil), context: context))
  }

  func testMissingDirectoriesYieldNoFiles() throws {
    let catalog = try WorkflowDiscovery.catalog(
      sources: WorkflowSources(bundle: nil, user: root.appending(path: "absent"), repo: nil), context: context)
    XCTAssertEqual(catalog, [])
  }

  func testFilesAreParsedValidatedAndOrderedByName() throws {
    let user = try directory("user")
    try write(WorkflowFixtures.minimal(id: "zeta"), to: user, name: "zeta.pwlworkflow")
    try write(WorkflowFixtures.minimal(id: "alpha"), to: user, name: "alpha.pwlworkflow")
    try write("not: [valid", to: user, name: "broken.pwlworkflow")
    try write("ignored", to: user, name: "notes.txt")
    try write(WorkflowFixtures.minimal(id: "hidden"), to: user, name: ".hidden.pwlworkflow")

    let files = try WorkflowDiscovery.files(in: user, scope: .user, context: context(.user))
    XCTAssertEqual(files.map(\.url.lastPathComponent), ["alpha.pwlworkflow", "broken.pwlworkflow", "zeta.pwlworkflow"])
    XCTAssertEqual(files.map(\.id), ["alpha", nil, "zeta"])
    XCTAssertEqual(files.map(\.isValid), [true, false, true])
    XCTAssertEqual(files[1].diagnostics.map(\.code), ["yaml_syntax"])
    XCTAssertEqual(files.map(\.scope), [.user, .user, .user])
  }

  func testValidationDiagnosticsFollowParseDiagnostics() throws {
    let user = try directory("user")
    try write(WorkflowFixtures.minimal(id: "prowl.mine"), to: user, name: "mine.pwlworkflow")
    let files = try WorkflowDiscovery.files(in: user, scope: .user, context: context(.user))
    XCTAssertEqual(files.map(\.isValid), [false])
    XCTAssertEqual(files[0].diagnostics.map(\.code), ["reserved_id"])
    XCTAssertNotNil(files[0].definition, "A file that parses keeps its definition even when validation fails")
  }

  func testPrecedenceAndShadowing() throws {
    let bundle = try directory("bundle")
    let user = try directory("user")
    let repo = try directory("repo")
    try write(WorkflowFixtures.adversarialReview, to: bundle, name: "adversarial-review.pwlworkflow")
    try write(WorkflowFixtures.minimal(id: "shared"), to: bundle, name: "shared.pwlworkflow")
    try write(WorkflowFixtures.minimal(id: "shared"), to: user, name: "shared.pwlworkflow")
    try write(WorkflowFixtures.minimal(id: "demo"), to: user, name: "demo.pwlworkflow")
    try write(WorkflowFixtures.minimal(id: "demo"), to: user, name: "demo-copy.pwlworkflow")
    try write(WorkflowFixtures.adversarialReview, to: user, name: "override.pwlworkflow")
    try write(WorkflowFixtures.minimal(id: "demo"), to: repo, name: "demo.pwlworkflow")

    let catalog = try WorkflowDiscovery.catalog(
      sources: WorkflowSources(bundle: bundle, user: user, repo: repo), context: context)
    let rows = catalog.map { "\($0.file.id ?? "-") \($0.file.scope.rawValue) \($0.file.url.lastPathComponent) \($0.shadowed ? "shadowed" : ($0.file.isValid ? "wins" : "invalid"))" }
    XCTAssertEqual(
      rows,
      [
        "demo repo demo.pwlworkflow wins",
        "demo user demo-copy.pwlworkflow shadowed",
        "demo user demo.pwlworkflow shadowed",
        "prowl.adversarial-review bundle adversarial-review.pwlworkflow wins",
        "prowl.adversarial-review user override.pwlworkflow invalid",
        "shared user shared.pwlworkflow wins",
        "shared bundle shared.pwlworkflow shadowed",
      ]
    )
  }

  func testSameSourceDuplicatesKeepTheFirstFileByName() throws {
    let user = try directory("user")
    try write(WorkflowFixtures.minimal(id: "demo"), to: user, name: "b.pwlworkflow")
    try write(WorkflowFixtures.minimal(id: "demo"), to: user, name: "a.pwlworkflow")
    let catalog = try WorkflowDiscovery.catalog(
      sources: WorkflowSources(bundle: nil, user: user, repo: nil), context: context)
    XCTAssertEqual(catalog.map { "\($0.file.url.lastPathComponent) \($0.shadowed)" }, ["a.pwlworkflow false", "b.pwlworkflow true"])
  }

  func testInvalidFilesNeverShadowValidOnes() throws {
    let user = try directory("user")
    let repo = try directory("repo")
    try write(WorkflowFixtures.minimal(id: "demo"), to: user, name: "demo.pwlworkflow")
    try write(WorkflowFixtures.minimal(id: "demo", extraSteps: "  - id: x\n    close: ghost"), to: repo, name: "demo.pwlworkflow")
    let catalog = try WorkflowDiscovery.catalog(
      sources: WorkflowSources(bundle: nil, user: user, repo: repo), context: context)
    XCTAssertEqual(
      catalog.map { "\($0.file.scope.rawValue) valid=\($0.file.isValid) shadowed=\($0.shadowed)" },
      ["user valid=true shadowed=false", "repo valid=false shadowed=false"])
  }

  func testSymlinksAndSpecialFilesAreReportedAsInvalidBundles() throws {
    let user = try directory("user")
    try write(WorkflowFixtures.minimal(id: "real"), to: user, name: "real.pwlworkflow")
    try FileManager.default.createDirectory(at: user.appending(path: "folder.pwlworkflow"), withIntermediateDirectories: true)
    let elsewhere = try directory("elsewhere")
    try write(WorkflowFixtures.minimal(id: "linked"), to: elsewhere, name: "source.pwlworkflow")
    try FileManager.default.createSymbolicLink(
      at: user.appending(path: "link.pwlworkflow"), withDestinationURL: elsewhere.appending(path: "source.pwlworkflow"))
    try FileManager.default.createSymbolicLink(
      at: user.appending(path: "dangling.pwlworkflow"), withDestinationURL: elsewhere.appending(path: "missing.pwlworkflow"))

    XCTAssertEqual(mkfifo(user.appending(path: "pipe.pwlworkflow").path(percentEncoded: false), 0o644), 0)

    let files = try WorkflowDiscovery.files(in: user, scope: .user, context: context(.user))
    XCTAssertEqual(files.map(\.url.lastPathComponent), ["dangling.pwlworkflow", "folder.pwlworkflow", "link.pwlworkflow", "pipe.pwlworkflow", "real.pwlworkflow"])
    XCTAssertEqual(files.map(\.id), [nil, nil, nil, nil, "real"])
  }

  func testSourceDirectoryHelpers() {
    let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)
    XCTAssertEqual(WorkflowSources.userDirectory(home: home).path(percentEncoded: false), "/Users/me/.prowl/workflows/")
    let repo = URL(filePath: "/Projects/App", directoryHint: .isDirectory)
    XCTAssertEqual(WorkflowSources.repoDirectory(root: repo).path(percentEncoded: false), "/Projects/App/.prowl/workflows/")
    let resources = URL(filePath: "/Applications/Prowl.app/Contents/Resources", directoryHint: .isDirectory)
    XCTAssertEqual(
      WorkflowSources.bundleDirectory(resourcesURL: resources).path(percentEncoded: false),
      "/Applications/Prowl.app/Contents/Resources/workflows/")
  }
}
