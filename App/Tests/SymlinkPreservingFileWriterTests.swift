import Foundation
import Testing

@testable import supacode

struct SymlinkPreservingFileWriterTests {
  private let fileManager = FileManager.default

  private func makeTempDir() throws -> URL {
    let dir = fileManager.temporaryDirectory
      .appending(path: "symlink-writer-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func isSymlink(_ url: URL) -> Bool {
    (try? fileManager.destinationOfSymbolicLink(atPath: url.path(percentEncoded: false))) != nil
  }

  @Test func writesPlainFileWithContent() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    let url = dir.appending(path: "settings.json", directoryHint: .notDirectory)
    let payload = Data("{\"a\":1}".utf8)

    try SymlinkPreservingFileWriter.write(payload, to: url)

    #expect(try Data(contentsOf: url) == payload)
    #expect(!isSymlink(url))
  }

  @Test func writesOwnerOnlyPermissions() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    let url = dir.appending(path: "settings.json", directoryHint: .notDirectory)

    try SymlinkPreservingFileWriter.write(Data("{}".utf8), to: url)

    let attributes = try fileManager.attributesOfItem(atPath: url.path(percentEncoded: false))
    #expect(attributes[.posixPermissions] as? Int == 0o600)
  }

  @Test func createsMissingParentDirectories() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    let url = dir.appending(path: "nested/deep/settings.json", directoryHint: .notDirectory)
    let payload = Data("{}".utf8)

    try SymlinkPreservingFileWriter.write(payload, to: url)

    #expect(try Data(contentsOf: url) == payload)
  }

  @Test func preservesAbsoluteSymlinkAndWritesThrough() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    let target = dir.appending(path: "target.json", directoryHint: .notDirectory)
    let link = dir.appending(path: "settings.json", directoryHint: .notDirectory)
    try Data("old".utf8).write(to: target)
    try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
    let payload = Data("new".utf8)

    try SymlinkPreservingFileWriter.write(payload, to: link)

    #expect(isSymlink(link))
    #expect(try Data(contentsOf: target) == payload)
    #expect(try Data(contentsOf: link) == payload)
  }

  @Test func preservesRelativeSymlinkAndWritesThrough() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    let prowlDir = dir.appending(path: ".prowl", directoryHint: .isDirectory)
    let dotfilesDir = dir.appending(path: "dotfiles", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: prowlDir, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: dotfilesDir, withIntermediateDirectories: true)
    let target = dotfilesDir.appending(path: "settings.json", directoryHint: .notDirectory)
    try Data("old".utf8).write(to: target)
    let link = prowlDir.appending(path: "settings.json", directoryHint: .notDirectory)
    try fileManager.createSymbolicLink(
      atPath: link.path(percentEncoded: false),
      withDestinationPath: "../dotfiles/settings.json"
    )
    let payload = Data("new".utf8)

    try SymlinkPreservingFileWriter.write(payload, to: link)

    #expect(isSymlink(link))
    #expect(try Data(contentsOf: target) == payload)
  }

  @Test func createsTargetForDanglingSymlinkWhenParentExists() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    let prowlDir = dir.appending(path: ".prowl", directoryHint: .isDirectory)
    let dotfilesDir = dir.appending(path: "dotfiles", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: prowlDir, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: dotfilesDir, withIntermediateDirectories: true)
    let link = prowlDir.appending(path: "settings.json", directoryHint: .notDirectory)
    try fileManager.createSymbolicLink(
      atPath: link.path(percentEncoded: false),
      withDestinationPath: "../dotfiles/settings.json"
    )
    let payload = Data("new".utf8)

    try SymlinkPreservingFileWriter.write(payload, to: link)

    #expect(isSymlink(link))
    let target = dotfilesDir.appending(path: "settings.json", directoryHint: .notDirectory)
    #expect(try Data(contentsOf: target) == payload)
  }

  @Test func failsAndCreatesNoPhantomDirectoryForDanglingIntoMissingDir() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    let prowlDir = dir.appending(path: ".prowl", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: prowlDir, withIntermediateDirectories: true)
    let link = prowlDir.appending(path: "settings.json", directoryHint: .notDirectory)
    try fileManager.createSymbolicLink(
      atPath: link.path(percentEncoded: false),
      withDestinationPath: "../missing/settings.json"
    )

    #expect(throws: (any Error).self) {
      try SymlinkPreservingFileWriter.write(Data("new".utf8), to: link)
    }
    let missingDir = dir.appending(path: "missing", directoryHint: .isDirectory)
    #expect(!fileManager.fileExists(atPath: missingDir.path(percentEncoded: false)))
    #expect(isSymlink(link))
  }

  @Test func followsSymlinkChainToFinalTarget() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    let real = dir.appending(path: "real.json", directoryHint: .notDirectory)
    let mid = dir.appending(path: "mid.json", directoryHint: .notDirectory)
    let link = dir.appending(path: "link.json", directoryHint: .notDirectory)
    try Data("old".utf8).write(to: real)
    try fileManager.createSymbolicLink(atPath: mid.path(percentEncoded: false), withDestinationPath: "real.json")
    try fileManager.createSymbolicLink(atPath: link.path(percentEncoded: false), withDestinationPath: "mid.json")
    let payload = Data("new".utf8)

    try SymlinkPreservingFileWriter.write(payload, to: link)

    #expect(isSymlink(link))
    #expect(isSymlink(mid))
    #expect(try Data(contentsOf: real) == payload)
  }

  @Test func throwsOnSymlinkCycle() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    let linkA = dir.appending(path: "a.json", directoryHint: .notDirectory)
    let linkB = dir.appending(path: "b.json", directoryHint: .notDirectory)
    try fileManager.createSymbolicLink(atPath: linkA.path(percentEncoded: false), withDestinationPath: "b.json")
    try fileManager.createSymbolicLink(atPath: linkB.path(percentEncoded: false), withDestinationPath: "a.json")

    #expect(throws: SymlinkPreservingFileWriterError.self) {
      try SymlinkPreservingFileWriter.write(Data("x".utf8), to: linkA)
    }
    #expect(isSymlink(linkA))
    #expect(isSymlink(linkB))
  }

  @Test func throwsOnOverlyDeepSymlinkChain() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    // A 40-link chain (link0 -> link1 -> ... -> link40) exceeds the kernel's
    // symlink-resolution limit, so the loader could never read it back.
    for hop in 0..<40 {
      let here = dir.appending(path: "link\(hop).json", directoryHint: .notDirectory)
      try fileManager.createSymbolicLink(
        atPath: here.path(percentEncoded: false),
        withDestinationPath: "link\(hop + 1).json"
      )
    }
    let head = dir.appending(path: "link0.json", directoryHint: .notDirectory)

    #expect(throws: SymlinkPreservingFileWriterError.self) {
      try SymlinkPreservingFileWriter.write(Data("x".utf8), to: head)
    }
    #expect(isSymlink(head))
  }

  @Test func writeOverwritesExistingRealFile() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    let url = dir.appending(path: "settings.json", directoryHint: .notDirectory)
    try Data("old".utf8).write(to: url)
    let payload = Data("new".utf8)

    try SymlinkPreservingFileWriter.write(payload, to: url)

    #expect(try Data(contentsOf: url) == payload)
    #expect(!isSymlink(url))
  }

  @Test func writeLeavesNoTemporaryFilesBehind() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    let url = dir.appending(path: "settings.json", directoryHint: .notDirectory)

    try SymlinkPreservingFileWriter.write(Data("{}".utf8), to: url)

    let contents = try fileManager.contentsOfDirectory(atPath: dir.path(percentEncoded: false))
    #expect(contents == ["settings.json"])
  }

  @Test func overwritingLegacyPermissionsEndsOwnerOnly() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    let url = dir.appending(path: "settings.json", directoryHint: .notDirectory)
    try Data("old".utf8).write(to: url)
    try fileManager.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: url.path(percentEncoded: false)
    )

    try SymlinkPreservingFileWriter.write(Data("new".utf8), to: url)

    let attributes = try fileManager.attributesOfItem(atPath: url.path(percentEncoded: false))
    #expect(attributes[.posixPermissions] as? Int == 0o600)
  }

  @Test func restrictToOwnerOnlyMigratesLegacyFileThroughSymlink() throws {
    let dir = try makeTempDir()
    defer { try? fileManager.removeItem(at: dir) }
    let target = dir.appending(path: "target.json", directoryHint: .notDirectory)
    let link = dir.appending(path: "settings.json", directoryHint: .notDirectory)
    try Data("{}".utf8).write(to: target)
    try fileManager.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: target.path(percentEncoded: false)
    )
    try fileManager.createSymbolicLink(at: link, withDestinationURL: target)

    SymlinkPreservingFileWriter.restrictToOwnerOnly(link)

    let attributes = try fileManager.attributesOfItem(atPath: target.path(percentEncoded: false))
    #expect(attributes[.posixPermissions] as? Int == 0o600)
    #expect(isSymlink(link))
  }
}
