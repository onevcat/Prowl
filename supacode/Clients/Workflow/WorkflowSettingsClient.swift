// supacode/Clients/Workflow/WorkflowSettingsClient.swift
// The filesystem side of Settings › Agents › Workflows (docs-ai 063 D1): scan every source,
// write a starter file, reveal a file, and watch the source directories so the page follows
// edits made in an editor. Row derivation is pure (`WorkflowSettingsCatalog`); the live scan is
// assembled in WorkflowSettingsComposition from the same validation inputs the CLI path uses.

import AppKit
import ComposableArchitecture
import Foundation

nonisolated struct WorkflowSettingsError: Error, Equatable, Sendable {
  let message: String
}

struct WorkflowSettingsClient: Sendable {
  var scan: @MainActor @Sendable () throws -> WorkflowSettingsScan
  /// Writes `WorkflowStarterTemplate` into the user directory and returns the new file.
  var createWorkflow: @Sendable () throws -> URL
  var reveal: @Sendable (URL) -> Void
  /// One element per change in any of the directories; a directory that does not exist yet is
  /// watched through its parent so its creation is noticed too.
  var watch: @Sendable (_ directories: [URL]) -> AsyncStream<Void>
}

extension WorkflowSettingsClient: DependencyKey {
  static let liveValue = WorkflowSettingsClient(
    scan: { throw WorkflowSettingsError(message: "Workflow settings are not available.") },
    createWorkflow: { throw WorkflowSettingsError(message: "Workflow settings are not available.") },
    reveal: { _ in },
    watch: { _ in AsyncStream { $0.finish() } }
  )

  static let testValue = WorkflowSettingsClient(
    scan: { .empty(userDirectory: URL(filePath: "/tmp/prowl-test/.prowl/workflows", directoryHint: .isDirectory)) },
    createWorkflow: { throw WorkflowSettingsError(message: "No test workflow directory configured.") },
    reveal: { _ in },
    watch: { _ in AsyncStream { $0.finish() } }
  )

  nonisolated static func reveal(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  nonisolated static func watchDirectories(_ directories: [URL]) -> AsyncStream<Void> {
    AsyncStream { continuation in
      let watcher = DirectoryChangeWatcher(directories: directories) { continuation.yield() }
      continuation.onTermination = { _ in watcher.cancel() }
    }
  }
}

/// vnode sources on each directory (or its nearest existing parent), coalesced into one callback.
nonisolated final class DirectoryChangeWatcher: @unchecked Sendable {
  private let sources: [DispatchSourceFileSystemObject]

  init(directories: [URL], fileManager: FileManager = .default, onChange: @escaping @Sendable () -> Void) {
    var watched: Set<String> = []
    var sources: [DispatchSourceFileSystemObject] = []
    for directory in directories {
      guard let path = Self.existingDirectory(for: directory, fileManager: fileManager),
        watched.insert(path).inserted
      else { continue }
      let descriptor = open(path, O_EVTONLY)
      guard descriptor >= 0 else { continue }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor,
        eventMask: [.write, .rename, .delete],
        queue: DispatchQueue.global(qos: .utility))
      source.setEventHandler(handler: onChange)
      source.setCancelHandler { close(descriptor) }
      source.activate()
      sources.append(source)
    }
    self.sources = sources
  }

  deinit {
    cancel()
  }

  func cancel() {
    for source in sources where !source.isCancelled {
      source.cancel()
    }
  }

  /// The directory itself, else the closest existing ancestor (creating the directory is a
  /// write to that ancestor).
  static func existingDirectory(for directory: URL, fileManager: FileManager) -> String? {
    var candidate = directory.standardizedFileURL
    while true {
      var isDirectory: ObjCBool = false
      let path = candidate.path(percentEncoded: false)
      if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
        return path
      }
      let parent = candidate.deletingLastPathComponent()
      guard parent.path(percentEncoded: false) != path else { return nil }
      candidate = parent
    }
  }
}
