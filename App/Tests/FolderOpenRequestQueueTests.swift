import Foundation
import Testing

@testable import Prowl

struct FolderOpenRequestQueueTests {
  @Test func acceptsOnlyExistingLocalDirectories() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("file.txt")
    try Data().write(to: file)
    var queue = FolderOpenRequestQueue()
    queue.append([
      root, file, root.appendingPathComponent("missing"),
      try #require(URL(string: "https://example.com/folder")),
    ])
    #expect(queue.takePending(isReady: true) == [root])
  }

  @Test func retainsColdLaunchRequestsUntilRepositoriesAreReady() {
    let folder = FileManager.default.temporaryDirectory
    var queue = FolderOpenRequestQueue()
    queue.append([folder])
    #expect(queue.takePending(isReady: false).isEmpty)
    queue.append([folder])
    #expect(queue.takePending(isReady: true) == [folder, folder])
    #expect(queue.takePending(isReady: true).isEmpty)
  }

  @Test func dockDeclaresFolderSupportWithoutTakingDefaultOwnership() throws {
    let types = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
    let folderType = try #require(types.first { ($0["LSItemContentTypes"] as? [String]) == ["public.folder"] })
    #expect(folderType["CFBundleTypeRole"] as? String == "Viewer")
    #expect(folderType["LSHandlerRank"] as? String == "Alternate")
  }
}
