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

nonisolated struct WorkflowSettingsRunTarget: Equatable, Sendable, Identifiable {
  let id: String
  let name: String
  let repositoryName: String
  let rootPath: String
  let isPreferred: Bool

  var displayName: String {
    repositoryName == name ? name : "\(name) — \(repositoryName)"
  }

  static func visible(
    _ targets: [Self],
    in scope: WorkflowSettingsScope
  ) -> [Self] {
    switch scope {
    case .global:
      return targets
    case .repository(let repository):
      return targets.filter { $0.rootPath == repository.rootPath }
    }
  }
}

struct WorkflowSettingsClient: Sendable {
  var scan: @MainActor @Sendable (_ scope: WorkflowSettingsScope) throws -> WorkflowSettingsScan
  /// Writes `WorkflowStarterTemplate` into the selected workflow directory and returns the new file.
  var createWorkflow: @Sendable (_ directory: URL) throws -> URL
  /// Moves the selected source file to Trash, leaving it recoverable in Finder.
  var trashWorkflow: @Sendable (URL) throws -> Void = { _ in
    throw WorkflowSettingsError(message: "Workflow deletion is not available.")
  }
  var runTargets: @MainActor @Sendable (_ scope: WorkflowSettingsScope) -> [WorkflowSettingsRunTarget]
  var reveal: @Sendable (URL) -> Void
  /// One element per change to any of the paths — directories (entries added, removed, renamed)
  /// and files (in-place saves). A path that does not exist yet is watched through its nearest
  /// existing ancestor so its creation is noticed too.
  var watch: @Sendable (_ paths: [URL]) -> AsyncStream<Void>
}

extension WorkflowSettingsClient: DependencyKey {
  static let liveValue = WorkflowSettingsClient(
    scan: { _ in throw WorkflowSettingsError(message: "Workflow settings are not available.") },
    createWorkflow: { _ in
      throw WorkflowSettingsError(message: "Workflow settings are not available.")
    },
    runTargets: { _ in [] },
    reveal: { _ in },
    watch: { _ in AsyncStream { $0.finish() } }
  )

  static let testValue = WorkflowSettingsClient(
    scan: { _ in
      .empty(
        userDirectory: URL(
          filePath: "/tmp/prowl-test/.prowl/workflows", directoryHint: .isDirectory))
    },
    createWorkflow: { _ in
      throw WorkflowSettingsError(message: "No test workflow directory configured.")
    },
    runTargets: { _ in [] },
    reveal: { _ in },
    watch: { _ in AsyncStream { $0.finish() } }
  )

  nonisolated static func reveal(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  nonisolated static func watchPaths(_ paths: [URL]) -> AsyncStream<Void> {
    AsyncStream { continuation in
      let watcher = WorkflowChangeWatcher(paths: paths) { continuation.yield() }
      continuation.onTermination = { _ in watcher.cancel() }
    }
  }
}

/// One vnode source per path (file or directory, else its nearest existing ancestor), coalesced
/// into one callback. Directories report entries coming and going; files report in-place saves,
/// which never touch the directory's vnode.
nonisolated final class WorkflowChangeWatcher: @unchecked Sendable {
  private let sources: [DispatchSourceFileSystemObject]

  init(paths: [URL], fileManager: FileManager = .default, onChange: @escaping @Sendable () -> Void) {
    var watched: Set<String> = []
    var sources: [DispatchSourceFileSystemObject] = []
    for url in paths {
      guard let path = Self.existingPath(for: url, fileManager: fileManager),
        watched.insert(path).inserted
      else { continue }
      let descriptor = open(path, O_EVTONLY)
      guard descriptor >= 0 else { continue }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor,
        eventMask: [.write, .extend, .attrib, .rename, .delete],
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

  /// The path itself when it exists, else the closest existing ancestor (creating the missing
  /// entry is a write to that ancestor).
  static func existingPath(for url: URL, fileManager: FileManager) -> String? {
    var candidate = url.standardizedFileURL
    while true {
      let path = candidate.path(percentEncoded: false)
      if fileManager.fileExists(atPath: path) {
        return path
      }
      let parent = candidate.deletingLastPathComponent()
      guard parent.path(percentEncoded: false) != path else { return nil }
      candidate = parent
    }
  }
}
