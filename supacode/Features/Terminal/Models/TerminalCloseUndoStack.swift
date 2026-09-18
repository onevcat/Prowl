import Foundation
import ProwlCLIShared

/// Launch bookkeeping that `forgetSurface` drops but a restored surface needs
/// back: the Profile that launched it (name, config root) and the managed-hook
/// registration its still-running process keeps sending events under.
struct TerminalRetainedSurfaceContext {
  let launchProfile: WorktreeTerminalState.SurfaceLaunchProfile?
  let hookRegistration: AgentHookLaunchRegistration?
}

/// A tab that was closed but whose surfaces are still alive, so an undo can put
/// it back exactly where it was.
struct TerminalClosedTabRecord {
  let item: TerminalTabItem
  let index: Int
  let wasSelected: Bool
  let tree: SplitTree<GhosttySurfaceView>
  let focusedSurfaceID: UUID?
  let wasRunScriptTab: Bool
  let boundDirectoryKey: String?
  let contexts: [UUID: TerminalRetainedSurfaceContext]

  var tabID: TerminalTabID { item.id }

  /// Drops a leaf whose process exited during the grace window. Returns `nil`
  /// when nothing restorable remains.
  func removingSurface(id surfaceID: UUID) -> TerminalClosedTabRecord? {
    guard let node = tree.find(id: surfaceID) else { return self }
    let remaining = tree.removing(node)
    guard !remaining.isEmpty else { return nil }
    return TerminalClosedTabRecord(
      item: item,
      index: index,
      wasSelected: wasSelected,
      tree: remaining,
      focusedSurfaceID: focusedSurfaceID == surfaceID ? nil : focusedSurfaceID,
      wasRunScriptTab: wasRunScriptTab,
      boundDirectoryKey: boundDirectoryKey,
      contexts: contexts.filter { $0.key != surfaceID }
    )
  }
}

/// A split pane that was closed but whose surface is still alive. `previousTree`
/// is the tab's tree from before the close: restoring it brings the split
/// direction and ratio back without recomputing anything (Ghostty's approach).
struct TerminalClosedPaneRecord {
  let tabID: TerminalTabID
  let view: GhosttySurfaceView
  let previousTree: SplitTree<GhosttySurfaceView>
  let wasFocused: Bool
  let context: TerminalRetainedSurfaceContext
}

/// One undoable close. Batch closes (Close Other Tabs, Close All, ...) record
/// every tab in one entry so a single ⌘Z restores the whole batch.
enum TerminalCloseRecord {
  case pane(worktreeID: Worktree.ID, TerminalClosedPaneRecord)
  case tabs(worktreeID: Worktree.ID, [TerminalClosedTabRecord])

  var worktreeID: Worktree.ID {
    switch self {
    case .pane(let worktreeID, _), .tabs(let worktreeID, _):
      return worktreeID
    }
  }

  var retainedSurfaces: [GhosttySurfaceView] {
    switch self {
    case .pane(_, let record):
      return [record.view]
    case .tabs(_, let records):
      return records.flatMap { $0.tree.leaves() }
    }
  }

  /// The record without `surfaceID`, or `nil` when nothing restorable remains.
  func removingSurface(id surfaceID: UUID) -> TerminalCloseRecord? {
    switch self {
    case .pane(_, let record):
      return record.view.id == surfaceID ? nil : self
    case .tabs(let worktreeID, let records):
      let remaining = records.compactMap { $0.removingSurface(id: surfaceID) }
      return remaining.isEmpty ? nil : .tabs(worktreeID: worktreeID, remaining)
    }
  }
}

/// What a redo closes again after an undo restored it.
enum TerminalReopenRecord {
  case pane(worktreeID: Worktree.ID, surfaceID: UUID)
  case tabs(worktreeID: Worktree.ID, [TerminalTabID])

  var worktreeID: Worktree.ID {
    switch self {
    case .pane(let worktreeID, _), .tabs(let worktreeID, _):
      return worktreeID
    }
  }
}

/// App-wide, time-ordered undo stack for pane and tab closes.
///
/// Ports the shape of Ghostty's `ExpiringUndoManager`: every entry carries its
/// own expiry, a later close never extends an earlier one, and a record that
/// leaves the stack without being restored hands its surfaces to `onExpire`
/// for freeing. Timers run on an injected clock so tests drive them with
/// `TestClock`.
@MainActor
final class TerminalCloseUndoStack {
  private struct Slot<Value> {
    let id: UUID
    var value: Value
    var expiry: Task<Void, Never>?
  }

  let timeout: Duration
  private let clock: any Clock<Duration>
  private var undoSlots: [Slot<TerminalCloseRecord>] = []
  private var redoSlots: [Slot<TerminalReopenRecord>] = []
  /// Receives surfaces that can no longer be restored and must be freed.
  var onExpire: (([GhosttySurfaceView]) -> Void)?

  init(timeout: Duration, clock: any Clock<Duration> = ContinuousClock()) {
    self.timeout = timeout
    self.clock = clock
  }

  var isEnabled: Bool { timeout > .zero }
  var canUndo: Bool { !undoSlots.isEmpty }
  var canRedo: Bool { !redoSlots.isEmpty }

  /// Records a close. A new close clears the redo history (UndoManager
  /// semantics) unless it happens while a redo is re-closing.
  func recordClose(_ record: TerminalCloseRecord, clearingRedo: Bool = true) {
    guard isEnabled else {
      onExpire?(record.retainedSurfaces)
      return
    }
    if clearingRedo {
      for slot in redoSlots {
        slot.expiry?.cancel()
      }
      redoSlots.removeAll()
    }
    let id = UUID()
    undoSlots.append(Slot(id: id, value: record, expiry: nil))
    undoSlots[undoSlots.count - 1].expiry = expiryTask { [weak self] in
      guard let self, let index = undoSlots.firstIndex(where: { $0.id == id }) else { return }
      let slot = undoSlots.remove(at: index)
      onExpire?(slot.value.retainedSurfaces)
    }
  }

  func recordReopen(_ record: TerminalReopenRecord) {
    guard isEnabled else { return }
    let id = UUID()
    redoSlots.append(Slot(id: id, value: record, expiry: nil))
    redoSlots[redoSlots.count - 1].expiry = expiryTask { [weak self] in
      self?.redoSlots.removeAll { $0.id == id }
    }
  }

  func popUndo() -> TerminalCloseRecord? {
    guard let slot = undoSlots.popLast() else { return nil }
    slot.expiry?.cancel()
    return slot.value
  }

  func popRedo() -> TerminalReopenRecord? {
    guard let slot = redoSlots.popLast() else { return nil }
    slot.expiry?.cancel()
    return slot.value
  }

  /// A retained surface's process exited: drop it from its record and free it.
  /// The record itself goes when nothing restorable remains.
  func discardSurface(id surfaceID: UUID) {
    guard
      let index = undoSlots.firstIndex(where: { slot in
        slot.value.retainedSurfaces.contains { $0.id == surfaceID }
      }),
      let view = undoSlots[index].value.retainedSurfaces.first(where: { $0.id == surfaceID })
    else { return }
    if let remaining = undoSlots[index].value.removingSurface(id: surfaceID) {
      undoSlots[index].value = remaining
    } else {
      undoSlots[index].expiry?.cancel()
      undoSlots.remove(at: index)
    }
    onExpire?([view])
  }

  /// Drops every entry of the matching worktrees, freeing their surfaces.
  func discard(where shouldDiscard: (Worktree.ID) -> Bool) {
    var freed: [GhosttySurfaceView] = []
    undoSlots.removeAll { slot in
      guard shouldDiscard(slot.value.worktreeID) else { return false }
      slot.expiry?.cancel()
      freed.append(contentsOf: slot.value.retainedSurfaces)
      return true
    }
    redoSlots.removeAll { slot in
      guard shouldDiscard(slot.value.worktreeID) else { return false }
      slot.expiry?.cancel()
      return true
    }
    if !freed.isEmpty {
      onExpire?(freed)
    }
  }

  private func expiryTask(_ body: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    let clock = clock
    let timeout = timeout
    return Task { @MainActor in
      try? await clock.sleep(for: timeout)
      guard !Task.isCancelled else { return }
      body()
    }
  }
}
