import Foundation
import Testing

@testable import Prowl

struct UserSettingsFileCreationTests {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "settings-create-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test(arguments: [false, true]) func exclusiveCreationDoesNotReplaceExistingPath(isLink: Bool) throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "settings.json")
    let target = directory.appending(path: "target.json")
    let original = Data("original".utf8)
    try original.write(to: target)
    if isLink {
      try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    } else {
      try original.write(to: url)
    }

    #expect(throws: SymlinkPreservingFileWriterError.self) {
      try SymlinkPreservingFileWriter.create(Data("new".utf8), to: url, preservingLinkAt: nil)
    }
    #expect(try Data(contentsOf: url) == original)
    #expect(try Data(contentsOf: target) == original)
    #expect(try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == isLink)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path()).count == 2)
  }

  @Test func symlinkMigrationDoesNotReplaceExistingDestination() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "old.json")
    let target = directory.appending(path: "target.json")
    let destination = directory.appending(path: "new.json")
    let original = Data("original".utf8)
    try original.write(to: target)
    try original.write(to: destination)
    try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)

    #expect(throws: CocoaError.self) {
      try SymlinkPreservingFileWriter.create(original, to: destination, preservingLinkAt: source)
    }
    #expect(try Data(contentsOf: destination) == original)
    #expect(try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
  }

  @Test func cyclicLegacySymlinkBlocksLoadAndSave() throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appending(path: "old.json")
    let destination = directory.appending(path: "new.json")
    try FileManager.default.createSymbolicLink(at: source, withDestinationURL: source)
    let storage = SettingsFileStorageKey.liveValue
    let file = UserSettingsFile<UserGlobalSettings>(
      url: destination, legacyURLs: [source], loadData: storage.load,
      saveData: storage.save, createData: storage.create
    )

    #expect(throws: (any Error).self) { try file.load(initialValue: .default) }
    #expect(throws: (any Error).self) { try file.save(.default) }
    #expect(!FileManager.default.fileExists(atPath: destination.path()))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: source.path()) == source.path())
  }
}
