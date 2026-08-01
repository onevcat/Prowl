import Foundation
import Synchronization

nonisolated struct UntrackedLineFileFingerprint: Equatable, Sendable {
  let byteCount: Int
  let modificationDate: Date
  let resourceIdentifier: String?
}

nonisolated struct UntrackedLineCacheFile: Sendable {
  let relativePath: String
  let fingerprint: UntrackedLineFileFingerprint
}

nonisolated enum CachedUntrackedLineCount: Equatable, Sendable {
  case text(Int)
  case binary
}

nonisolated struct UntrackedLineCacheUpdate: Sendable {
  let relativePath: String
  let fingerprint: UntrackedLineFileFingerprint
  let value: CachedUntrackedLineCount
}

nonisolated final class UntrackedLineCountCache: Sendable {
  static let shared = UntrackedLineCountCache()

  private struct Entry {
    let fingerprint: UntrackedLineFileFingerprint
    let value: CachedUntrackedLineCount
    let cachedPathByteCount: Int
    var accessSequence: UInt64
  }

  private struct EntryIdentifier {
    let worktreeKey: String
    let relativePath: String
  }

  private struct EntryCandidate {
    let identifier: EntryIdentifier
    let entry: Entry
  }

  private struct State {
    let maximumWorktreeCount: Int
    let maximumEntryCountPerWorktree: Int
    let maximumTotalEntryCount: Int
    let maximumCachedPathByteCount: Int
    var entriesByWorktree: [String: [String: Entry]] = [:]
    var lastAccessByWorktree: [String: UInt64] = [:]
    var cachedEntryCount = 0
    var cachedPathByteCount = 0
    var accessSequence: UInt64 = 0
  }

  private let state: Mutex<State>

  init(
    maximumWorktreeCount: Int = 128,
    maximumEntryCountPerWorktree: Int = 4_096,
    maximumTotalEntryCount: Int = 32_768,
    maximumCachedPathByteCount: Int = 4 * 1_024 * 1_024
  ) {
    precondition(maximumWorktreeCount > 0)
    precondition(maximumEntryCountPerWorktree > 0)
    precondition(maximumTotalEntryCount > 0)
    precondition(maximumCachedPathByteCount > 0)
    state = Mutex(
      State(
        maximumWorktreeCount: maximumWorktreeCount,
        maximumEntryCountPerWorktree: maximumEntryCountPerWorktree,
        maximumTotalEntryCount: maximumTotalEntryCount,
        maximumCachedPathByteCount: maximumCachedPathByteCount
      ))
  }

  func cachedValues(
    for files: [UntrackedLineCacheFile],
    worktreeKey: String
  ) -> [String: CachedUntrackedLineCount] {
    state.withLock { state in
      guard !files.isEmpty else {
        removeWorktree(worktreeKey, state: &state)
        return [:]
      }
      let currentPaths = Set(files.map(\.relativePath))
      var entries = state.entriesByWorktree[worktreeKey, default: [:]]
      for relativePath in Array(entries.keys) where !currentPaths.contains(relativePath) {
        remove(relativePath, from: &entries, state: &state)
      }

      var result: [String: CachedUntrackedLineCount] = [:]
      for file in files {
        guard var entry = entries[file.relativePath] else {
          continue
        }
        guard entry.fingerprint == file.fingerprint else {
          remove(file.relativePath, from: &entries, state: &state)
          continue
        }
        entry.accessSequence = nextAccess(state: &state)
        entries[file.relativePath] = entry
        result[file.relativePath] = entry.value
      }
      if entries.isEmpty {
        state.entriesByWorktree.removeValue(forKey: worktreeKey)
        state.lastAccessByWorktree.removeValue(forKey: worktreeKey)
      } else {
        state.entriesByWorktree[worktreeKey] = entries
        touch(worktreeKey, state: &state)
        trimIfNeeded(state: &state)
      }
      return result
    }
  }

  func store(
    _ updates: [UntrackedLineCacheUpdate],
    worktreeKey: String
  ) {
    guard !updates.isEmpty else { return }
    state.withLock { state in
      var entries = state.entriesByWorktree[worktreeKey, default: [:]]
      for update in updates {
        let entry = Entry(
          fingerprint: update.fingerprint,
          value: update.value,
          cachedPathByteCount: update.relativePath.utf8.count,
          accessSequence: nextAccess(state: &state)
        )
        if let replaced = entries.updateValue(entry, forKey: update.relativePath) {
          state.cachedPathByteCount += entry.cachedPathByteCount - replaced.cachedPathByteCount
        } else {
          state.cachedEntryCount += 1
          state.cachedPathByteCount += entry.cachedPathByteCount
        }
      }
      state.entriesByWorktree[worktreeKey] = entries
      touch(worktreeKey, state: &state)
      trimIfNeeded(state: &state)
    }
  }

  private func touch(_ worktreeKey: String, state: inout State) {
    state.lastAccessByWorktree[worktreeKey] = nextAccess(state: &state)
  }

  private func nextAccess(state: inout State) -> UInt64 {
    state.accessSequence &+= 1
    return state.accessSequence
  }

  private func trimIfNeeded(state: inout State) {
    while state.entriesByWorktree.count > state.maximumWorktreeCount,
      let leastRecentlyUsed = state.lastAccessByWorktree.min(by: { $0.value < $1.value })?.key
    {
      removeWorktree(leastRecentlyUsed, state: &state)
    }

    for worktreeKey in Array(state.entriesByWorktree.keys) {
      trimEntries(in: worktreeKey, state: &state)
    }

    while state.cachedEntryCount > state.maximumTotalEntryCount
      || state.cachedPathByteCount > state.maximumCachedPathByteCount
    {
      guard let leastRecentlyUsed = leastRecentlyUsedEntry(in: state) else {
        break
      }
      remove(leastRecentlyUsed, state: &state)
    }

  }

  private func trimEntries(in worktreeKey: String, state: inout State) {
    guard var entries = state.entriesByWorktree[worktreeKey] else {
      return
    }
    while entries.count > state.maximumEntryCountPerWorktree,
      let leastRecentlyUsed = leastRecentlyUsedEntry(in: entries)
    {
      remove(leastRecentlyUsed, from: &entries, state: &state)
    }
    if entries.isEmpty {
      state.entriesByWorktree.removeValue(forKey: worktreeKey)
      state.lastAccessByWorktree.removeValue(forKey: worktreeKey)
    } else {
      state.entriesByWorktree[worktreeKey] = entries
    }
  }

  private func leastRecentlyUsedEntry(in entries: [String: Entry]) -> String? {
    entries.min { lhs, rhs in
      if lhs.value.accessSequence != rhs.value.accessSequence {
        return lhs.value.accessSequence < rhs.value.accessSequence
      }
      return lhs.key < rhs.key
    }?.key
  }

  private func leastRecentlyUsedEntry(in state: State) -> EntryIdentifier? {
    var result: EntryCandidate?
    for (worktreeKey, entries) in state.entriesByWorktree {
      for (relativePath, entry) in entries {
        guard let current = result else {
          result = EntryCandidate(
            identifier: EntryIdentifier(worktreeKey: worktreeKey, relativePath: relativePath),
            entry: entry
          )
          continue
        }
        if entry.accessSequence < current.entry.accessSequence
          || (entry.accessSequence == current.entry.accessSequence
            && (worktreeKey < current.identifier.worktreeKey
              || (worktreeKey == current.identifier.worktreeKey
                && relativePath < current.identifier.relativePath)))
        {
          result = EntryCandidate(
            identifier: EntryIdentifier(worktreeKey: worktreeKey, relativePath: relativePath),
            entry: entry
          )
        }
      }
    }
    return result?.identifier
  }

  private func remove(
    _ entry: EntryIdentifier,
    state: inout State
  ) {
    guard var entries = state.entriesByWorktree[entry.worktreeKey] else {
      return
    }
    remove(entry.relativePath, from: &entries, state: &state)
    if entries.isEmpty {
      state.entriesByWorktree.removeValue(forKey: entry.worktreeKey)
      state.lastAccessByWorktree.removeValue(forKey: entry.worktreeKey)
    } else {
      state.entriesByWorktree[entry.worktreeKey] = entries
    }
  }

  private func remove(
    _ relativePath: String,
    from entries: inout [String: Entry],
    state: inout State
  ) {
    guard let removed = entries.removeValue(forKey: relativePath) else {
      return
    }
    state.cachedEntryCount -= 1
    state.cachedPathByteCount -= removed.cachedPathByteCount
  }

  private func removeWorktree(_ worktreeKey: String, state: inout State) {
    guard let entries = state.entriesByWorktree.removeValue(forKey: worktreeKey) else {
      return
    }
    state.cachedEntryCount -= entries.count
    state.cachedPathByteCount -= entries.values.reduce(into: 0) { count, entry in
      count += entry.cachedPathByteCount
    }
    state.lastAccessByWorktree.removeValue(forKey: worktreeKey)
  }
}
