import Foundation
import Testing

@testable import supacode

struct WorkflowChangeWatcherTests {
  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "prowl-change-watcher-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// Blocks the test thread on a real vnode event — the watcher is DispatchSource-backed, so no
  /// injected clock can stand in for the kernel here.
  private func expectChange(within seconds: Double = 3, _ body: (@escaping @Sendable () -> Void) throws -> Void) throws
    -> Bool
  {
    let fired = DispatchSemaphore(value: 0)
    try body { fired.signal() }
    return fired.wait(timeout: .now() + seconds) == .success
  }

  @Test func editingAWatchedFileInPlaceReportsAChange() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "review.yaml", directoryHint: .notDirectory)
    try Data("schema: prowl.workflow/v1\n".utf8).write(to: file)

    var watcher: WorkflowChangeWatcher?
    let fired = try expectChange { onChange in
      watcher = WorkflowChangeWatcher(paths: [directory, file], onChange: onChange)
      // An in-place write touches the file's vnode only, never the directory's.
      let handle = try FileHandle(forWritingTo: file)
      try handle.seekToEnd()
      try handle.write(contentsOf: Data("id: review\n".utf8))
      try handle.close()
    }
    watcher?.cancel()
    #expect(fired)
  }

  @Test func aMissingDirectoryIsWatchedThroughItsNearestAncestor() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workflows = root.appending(path: ".prowl/workflows", directoryHint: .isDirectory)

    var watcher: WorkflowChangeWatcher?
    let fired = try expectChange { onChange in
      watcher = WorkflowChangeWatcher(paths: [workflows], onChange: onChange)
      try FileManager.default.createDirectory(
        at: root.appending(path: ".prowl", directoryHint: .isDirectory), withIntermediateDirectories: true)
    }
    watcher?.cancel()
    #expect(fired)
    #expect(
      WorkflowChangeWatcher.existingPath(for: workflows, fileManager: .default)
        == root.appending(path: ".prowl", directoryHint: .isDirectory).standardizedFileURL.path(percentEncoded: false))
  }
}
