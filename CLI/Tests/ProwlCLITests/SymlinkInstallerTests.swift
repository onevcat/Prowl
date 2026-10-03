import Foundation
import ProwlCLIShared
import XCTest

final class SymlinkInstallerTests: XCTestCase {
  func testStatusIsNotInstalledWhenNothingExists() throws {
    try withTemporaryDirectory { root in
      let source = try makeDirectory(root.appending(path: "source"))
      let link = root.appending(path: "bin/link").path(percentEncoded: false)

      XCTAssertEqual(SymlinkInstaller.status(linkPath: link, source: source), .notInstalled)
    }
  }

  func testStatusIsInstalledForSymlinkToExpectedSource() throws {
    try withTemporaryDirectory { root in
      let source = try makeDirectory(root.appending(path: "source"))
      let link = root.appending(path: "link").path(percentEncoded: false)
      try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: source)

      XCTAssertEqual(SymlinkInstaller.status(linkPath: link, source: source), .installed(path: link))
    }
  }

  func testStatusIsDifferentSourceForSymlinkToAnotherLiveSource() throws {
    try withTemporaryDirectory { root in
      let source = try makeDirectory(root.appending(path: "source"))
      let other = try makeDirectory(root.appending(path: "other"))
      let link = root.appending(path: "link").path(percentEncoded: false)
      try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: other)

      XCTAssertEqual(
        SymlinkInstaller.status(linkPath: link, source: source),
        .installedDifferentSource(path: link, destination: other)
      )
    }
  }

  func testStatusResolvesARelativeDifferentSourceAgainstTheLinkDirectory() throws {
    try withTemporaryDirectory { root in
      let source = try makeDirectory(root.appending(path: "source"))
      let other = try makeDirectory(root.appending(path: "bin/other"))
      let link = root.appending(path: "bin/link").path(percentEncoded: false)
      try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "other")

      XCTAssertEqual(
        SymlinkInstaller.status(linkPath: link, source: source),
        .installedDifferentSource(path: link, destination: other)
      )
    }
  }

  func testStatusIsDifferentSourceForRegularFileAndRealDirectory() throws {
    try withTemporaryDirectory { root in
      let source = try makeDirectory(root.appending(path: "source"))
      let file = root.appending(path: "file").path(percentEncoded: false)
      try Data("contents".utf8).write(to: URL(filePath: file))
      let directory = try makeDirectory(root.appending(path: "directory"))

      XCTAssertEqual(
        SymlinkInstaller.status(linkPath: file, source: source),
        .installedDifferentSource(path: file, destination: nil)
      )
      XCTAssertEqual(
        SymlinkInstaller.status(linkPath: directory, source: source),
        .installedDifferentSource(path: directory, destination: nil)
      )
    }
  }

  func testStatusIsBrokenForDanglingSymlink() throws {
    try withTemporaryDirectory { root in
      let source = try makeDirectory(root.appending(path: "source"))
      let missing = root.appending(path: "missing").path(percentEncoded: false)
      let link = root.appending(path: "link").path(percentEncoded: false)
      try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: missing)

      XCTAssertEqual(
        SymlinkInstaller.status(linkPath: link, source: source),
        .broken(path: link, destination: missing)
      )
    }
  }

  func testStatusIsBrokenForDanglingSymlinkThatNamesTheExpectedSource() throws {
    try withTemporaryDirectory { root in
      let source = root.appending(path: "moved-away").path(percentEncoded: false)
      let link = root.appending(path: "link").path(percentEncoded: false)
      try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: source)

      XCTAssertEqual(
        SymlinkInstaller.status(linkPath: link, source: source),
        .broken(path: link, destination: source)
      )
    }
  }

  func testInstallCreatesParentDirectoriesAndLink() throws {
    try withTemporaryDirectory { root in
      let source = try makeDirectory(root.appending(path: "source"))
      let link = root.appending(path: "a/b/c/link").path(percentEncoded: false)

      try SymlinkInstaller.install(source: source, linkPath: link)

      XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), source)
      XCTAssertEqual(SymlinkInstaller.status(linkPath: link, source: source), .installed(path: link))
    }
  }

  func testInstallReplacesLiveAndDanglingSymlinks() throws {
    try withTemporaryDirectory { root in
      let source = try makeDirectory(root.appending(path: "source"))
      let other = try makeDirectory(root.appending(path: "other"))
      let liveLink = root.appending(path: "live").path(percentEncoded: false)
      let danglingLink = root.appending(path: "dangling").path(percentEncoded: false)
      try FileManager.default.createSymbolicLink(atPath: liveLink, withDestinationPath: other)
      try FileManager.default.createSymbolicLink(
        atPath: danglingLink,
        withDestinationPath: root.appending(path: "missing").path(percentEncoded: false)
      )

      try SymlinkInstaller.install(source: source, linkPath: liveLink)
      try SymlinkInstaller.install(source: source, linkPath: danglingLink)

      XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: liveLink), source)
      XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: danglingLink), source)
      XCTAssertTrue(FileManager.default.fileExists(atPath: other), "Replacing a link must not touch its old target")
    }
  }

  func testInstallRefusesRegularFileAndRealDirectoryWithoutModifyingThem() throws {
    try withTemporaryDirectory { root in
      let source = try makeDirectory(root.appending(path: "source"))
      let file = root.appending(path: "file").path(percentEncoded: false)
      try Data("existing".utf8).write(to: URL(filePath: file))
      let directory = try makeDirectory(root.appending(path: "directory"))
      let marker = URL(filePath: directory).appending(path: "marker")
      try Data("keep".utf8).write(to: marker)

      XCTAssertThrowsError(try SymlinkInstaller.install(source: source, linkPath: file)) { error in
        XCTAssertEqual(error as? SymlinkInstallError, .conflict(path: file))
      }
      XCTAssertThrowsError(try SymlinkInstaller.install(source: source, linkPath: directory)) { error in
        XCTAssertEqual(error as? SymlinkInstallError, .conflict(path: directory))
      }

      XCTAssertEqual(FileManager.default.contents(atPath: file), Data("existing".utf8))
      XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
      XCTAssertFalse(isSymlink(file))
      XCTAssertFalse(isSymlink(directory))
    }
  }

  func testInstallRejectsMissingSource() throws {
    try withTemporaryDirectory { root in
      let source = root.appending(path: "missing-source").path(percentEncoded: false)
      let link = root.appending(path: "link").path(percentEncoded: false)

      XCTAssertThrowsError(try SymlinkInstaller.install(source: source, linkPath: link)) { error in
        XCTAssertEqual(error as? SymlinkInstallError, .sourceNotFound(path: source))
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: link))
    }
  }

  func testUninstallRemovesLiveAndDanglingSymlinks() throws {
    try withTemporaryDirectory { root in
      let target = try makeDirectory(root.appending(path: "target"))
      let liveLink = root.appending(path: "live").path(percentEncoded: false)
      let danglingLink = root.appending(path: "dangling").path(percentEncoded: false)
      try FileManager.default.createSymbolicLink(atPath: liveLink, withDestinationPath: target)
      try FileManager.default.createSymbolicLink(
        atPath: danglingLink,
        withDestinationPath: root.appending(path: "missing").path(percentEncoded: false)
      )

      try SymlinkInstaller.uninstall(linkPath: liveLink)
      try SymlinkInstaller.uninstall(linkPath: danglingLink)

      XCTAssertFalse(isSymlink(liveLink))
      XCTAssertFalse(isSymlink(danglingLink))
      XCTAssertTrue(FileManager.default.fileExists(atPath: target), "Uninstall must not follow the link")
    }
  }

  func testUninstallRefusesRegularFileAndRealDirectory() throws {
    try withTemporaryDirectory { root in
      let file = root.appending(path: "file").path(percentEncoded: false)
      try Data("existing".utf8).write(to: URL(filePath: file))
      let directory = try makeDirectory(root.appending(path: "directory"))

      XCTAssertThrowsError(try SymlinkInstaller.uninstall(linkPath: file)) { error in
        XCTAssertEqual(error as? SymlinkInstallError, .conflict(path: file))
      }
      XCTAssertThrowsError(try SymlinkInstaller.uninstall(linkPath: directory)) { error in
        XCTAssertEqual(error as? SymlinkInstallError, .conflict(path: directory))
      }
      XCTAssertEqual(FileManager.default.contents(atPath: file), Data("existing".utf8))
      XCTAssertTrue(FileManager.default.fileExists(atPath: directory))
    }
  }

  func testUninstallReportsNotInstalledWhenNothingExists() throws {
    try withTemporaryDirectory { root in
      let link = root.appending(path: "link").path(percentEncoded: false)

      XCTAssertThrowsError(try SymlinkInstaller.uninstall(linkPath: link)) { error in
        XCTAssertEqual(error as? SymlinkInstallError, .notInstalled(path: link))
      }
    }
  }

  // MARK: - Helpers

  private func withTemporaryDirectory(_ operation: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "prowl-symlink-installer-\(UUID().uuidString)", directoryHint: .isDirectory)
      .standardizedFileURL
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try operation(root)
  }

  @discardableResult
  private func makeDirectory(_ url: URL) throws -> String {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path(percentEncoded: false)
  }

  private func isSymlink(_ path: String) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink
  }
}
