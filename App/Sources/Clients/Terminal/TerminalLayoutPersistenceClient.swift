import ComposableArchitecture
import Foundation

struct TerminalLayoutPersistenceClient {
  var loadSnapshot: @Sendable () async -> TerminalLayoutSnapshotPayload?
  var saveSnapshot: @Sendable (TerminalLayoutSnapshotPayload) async -> Bool
  var clearSnapshot: @Sendable () async -> Bool
}

extension TerminalLayoutPersistenceClient: DependencyKey {
  static let liveValue = TerminalLayoutPersistenceClient(
    loadSnapshot: {
      loadTerminalLayoutSnapshot(
        at: SupacodePaths.terminalLayoutSnapshotURL,
        fileManager: .default
      )
    },
    saveSnapshot: { payload in
      saveTerminalLayoutSnapshot(
        payload,
        at: SupacodePaths.terminalLayoutSnapshotURL,
        cacheDirectory: SupacodePaths.cacheDirectory,
        fileManager: .default
      )
    },
    clearSnapshot: {
      discardTerminalLayoutSnapshot(at: SupacodePaths.terminalLayoutSnapshotURL, fileManager: .default)
    }
  )

  static let testValue = TerminalLayoutPersistenceClient(
    loadSnapshot: { nil },
    saveSnapshot: { _ in true },
    clearSnapshot: { true }
  )
}

extension DependencyValues {
  var terminalLayoutPersistence: TerminalLayoutPersistenceClient {
    get { self[TerminalLayoutPersistenceClient.self] }
    set { self[TerminalLayoutPersistenceClient.self] = newValue }
  }
}

private nonisolated let terminalLayoutPersistenceLogger = SupaLogger("TerminalLayoutPersistence")

@discardableResult
nonisolated func discardTerminalLayoutSnapshot(
  at url: URL,
  fileManager: FileManager
) -> Bool {
  let path = url.path(percentEncoded: false)
  guard fileManager.fileExists(atPath: path) else {
    return true
  }
  do {
    try fileManager.removeItem(at: url)
    return true
  } catch {
    terminalLayoutPersistenceLogger.warning(
      "Unable to remove terminal layout snapshot: \(error.localizedDescription)"
    )
    return false
  }
}

nonisolated func loadTerminalLayoutSnapshot(
  at url: URL,
  fileManager: FileManager
) -> TerminalLayoutSnapshotPayload? {
  let path = url.path(percentEncoded: false)
  terminalLayoutPersistenceLogger.info("[LayoutRestore] load: path=\(path)")
  guard let data = try? Data(contentsOf: url) else {
    terminalLayoutPersistenceLogger.info("[LayoutRestore] load: file not found or unreadable")
    return nil
  }
  terminalLayoutPersistenceLogger.info("[LayoutRestore] load: read \(data.count) bytes")
  guard !data.isEmpty else {
    terminalLayoutPersistenceLogger.info("[LayoutRestore] load: empty file, discarding")
    _ = discardTerminalLayoutSnapshot(at: url, fileManager: fileManager)
    return nil
  }
  guard let payload = TerminalLayoutSnapshotPayload.decodeValidated(from: data) else {
    terminalLayoutPersistenceLogger.warning("[LayoutRestore] load: invalid payload, discarding")
    _ = discardTerminalLayoutSnapshot(at: url, fileManager: fileManager)
    return nil
  }
  terminalLayoutPersistenceLogger.info(
    "[LayoutRestore] load: decoded \(payload.worktrees.count) worktree(s), version=\(payload.version)"
  )
  return payload
}

nonisolated func saveTerminalLayoutSnapshot(
  _ payload: TerminalLayoutSnapshotPayload,
  at snapshotURL: URL,
  cacheDirectory: URL,
  fileManager: FileManager
) -> Bool {
  terminalLayoutPersistenceLogger.info(
    "[LayoutRestore] save: \(payload.worktrees.count) worktree(s) to \(snapshotURL.path(percentEncoded: false))"
  )
  guard payload.isValid else {
    terminalLayoutPersistenceLogger.warning("[LayoutRestore] save: payload is invalid, refusing to write")
    return false
  }
  if payload.worktrees.isEmpty {
    terminalLayoutPersistenceLogger.info("[LayoutRestore] save: empty payload, discarding")
    return discardTerminalLayoutSnapshot(at: snapshotURL, fileManager: fileManager)
  }
  do {
    try fileManager.createDirectory(
      at: cacheDirectory,
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(payload)
    guard data.count <= TerminalLayoutSnapshotPayload.maxSnapshotFileBytes else {
      terminalLayoutPersistenceLogger.warning("[LayoutRestore] save: \(data.count) bytes exceeds fuse")
      return false
    }
    try data.write(to: snapshotURL, options: .atomic)
    terminalLayoutPersistenceLogger.info("[LayoutRestore] save: wrote \(data.count) bytes successfully")
    return true
  } catch {
    terminalLayoutPersistenceLogger.warning(
      "[LayoutRestore] save: write failed: \(error.localizedDescription)"
    )
    return false
  }
}
