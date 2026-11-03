import Foundation
import Testing

@testable import Prowl

struct FolderOpenRequestTests {
  @Test func keepsOnlyPlainFoldersThatExist() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    // A package is a directory, but Finder shows it as a file and it is not a project.
    let package = root.appendingPathComponent("Tool.app")
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("file.txt")
    try Data().write(to: file)

    let urls = [
      folder, package, file, root.appendingPathComponent("missing"),
      try #require(URL(string: "https://example.com/folder")),
    ]
    #expect(FolderOpenRequest.folderURLs(in: urls) == [folder])
  }

  @Test func dockDeclaresFolderSupportWithoutTakingDefaultOwnership() throws {
    let types = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
    let folderType = try #require(types.first { ($0["LSItemContentTypes"] as? [String]) == ["public.folder"] })
    #expect(folderType["CFBundleTypeRole"] as? String == "Viewer")
    #expect(folderType["LSHandlerRank"] as? String == "Alternate")
  }
}
