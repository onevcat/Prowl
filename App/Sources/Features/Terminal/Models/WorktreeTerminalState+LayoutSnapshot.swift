import Foundation
import GhosttyKit

extension WorktreeTerminalState {
  func makeLayoutSnapshotWorktree() -> TerminalLayoutSnapshotPayload.SnapshotWorktree? {
    terminalStateLogger.info(
      "[LayoutRestore] makeSnapshot: worktree=\(worktree.id) tabs=\(tabManager.tabs.count)"
    )
    guard !tabManager.tabs.isEmpty else {
      terminalStateLogger.info("[LayoutRestore] makeSnapshot: no tabs, returning nil")
      return nil
    }

    var snapshotTabs: [TerminalLayoutSnapshotPayload.SnapshotTab] = []
    snapshotTabs.reserveCapacity(tabManager.tabs.count)
    for tab in tabManager.tabs {
      guard let tree = trees[tab.id], let root = tree.root else {
        terminalStateLogger.warning(
          "[LayoutRestore] makeSnapshot: no tree/root for tab \(tab.id.rawValue.uuidString)"
        )
        return nil
      }
      guard let splitRoot = makeLayoutSnapshotNode(from: root) else {
        terminalStateLogger.warning(
          "[LayoutRestore] makeSnapshot: failed to snapshot split tree for tab \(tab.id.rawValue.uuidString)"
        )
        return nil
      }
      // Skip title/icon for blocking-script tabs as they are transient.
      // Persist the icon only when the user has explicitly overridden it; otherwise
      // restore should pick up the current default ("terminal") or auto-detection.
      let isBlockingScriptTab = tab.id == runScriptTabId
      let snapshotIcon: String? = (isBlockingScriptTab || tab.iconLock != .user) ? nil : tab.icon
      snapshotTabs.append(
        TerminalLayoutSnapshotPayload.SnapshotTab(
          tabID: tab.id.rawValue.uuidString,
          title: isBlockingScriptTab ? nil : tab.title,
          customTitle: isBlockingScriptTab ? nil : tab.customTitle,
          icon: snapshotIcon,
          splitRoot: splitRoot
        )
      )
    }

    let result = TerminalLayoutSnapshotPayload.SnapshotWorktree(
      worktreeID: worktree.id,
      selectedTabID: tabManager.selectedTabId?.rawValue.uuidString,
      tabs: snapshotTabs
    )
    terminalStateLogger.info(
      "[LayoutRestore] makeSnapshot: success, \(snapshotTabs.count) tab(s) captured"
    )
    return result
  }

  func applyLayoutSnapshot(_ snapshot: TerminalLayoutSnapshotPayload.SnapshotWorktree) -> Bool {
    terminalStateLogger.info(
      "[LayoutRestore] applySnapshot: worktree=\(worktree.id)"
        + " snapshotWorktreeID=\(snapshot.worktreeID) tabs=\(snapshot.tabs.count)"
    )
    guard snapshot.worktreeID == worktree.id else {
      terminalStateLogger.warning("[LayoutRestore] applySnapshot: worktreeID mismatch")
      return false
    }

    // Validate snapshot structure before creating any surfaces.
    var validatedTabs: [(tabID: TerminalTabID, snapshotTab: TerminalLayoutSnapshotPayload.SnapshotTab)] = []
    var seenTabIDs: Set<TerminalTabID> = []
    for snapshotTab in snapshot.tabs {
      guard let tabUUID = UUID(uuidString: snapshotTab.tabID) else {
        terminalStateLogger.warning("[LayoutRestore] applySnapshot: invalid tab UUID \(snapshotTab.tabID)")
        return false
      }
      let tabID = TerminalTabID(rawValue: tabUUID)
      guard seenTabIDs.insert(tabID).inserted else {
        terminalStateLogger.warning("[LayoutRestore] applySnapshot: duplicate tab ID \(snapshotTab.tabID)")
        return false
      }
      validatedTabs.append((tabID: tabID, snapshotTab: snapshotTab))
    }

    let selectedTabID: TerminalTabID?
    if let selectedTabRaw = snapshot.selectedTabID {
      guard let selectedUUID = UUID(uuidString: selectedTabRaw) else {
        terminalStateLogger.warning("[LayoutRestore] applySnapshot: invalid selectedTab UUID \(selectedTabRaw)")
        return false
      }
      let candidate = TerminalTabID(rawValue: selectedUUID)
      guard seenTabIDs.contains(candidate) else {
        terminalStateLogger.warning("[LayoutRestore] applySnapshot: selectedTab not in restored tabs")
        return false
      }
      selectedTabID = candidate
    } else {
      selectedTabID = validatedTabs.first?.tabID
    }

    // Close existing surfaces BEFORE creating new ones so new surfaces
    // don't get destroyed by closeAllSurfaces().
    terminalStateLogger.info("[LayoutRestore] applySnapshot: closing existing surfaces before restore")
    closeAllSurfaces()

    // Now create new surfaces into the clean state.
    var restoredTabs: [TerminalTabItem] = []
    var restoredTrees: [TerminalTabID: SplitTree<GhosttySurfaceView>] = [:]
    var restoredFocusedSurfaceIDs: [TerminalTabID: UUID] = [:]

    for (index, entry) in validatedTabs.enumerated() {
      terminalStateLogger.info(
        "[LayoutRestore] applySnapshot: restoring tab[\(index)] id=\(entry.snapshotTab.tabID)"
      )
      guard
        let rootNode = restoreSplitNode(from: entry.snapshotTab.splitRoot, tabID: entry.tabID, isRoot: true)
      else {
        terminalStateLogger.warning("[LayoutRestore] applySnapshot: restoreSplitNode failed for tab[\(index)]")
        closeAllSurfaces()
        return false
      }
      let tree = SplitTree<GhosttySurfaceView>.restored(root: rootNode)
      restoredTrees[entry.tabID] = tree
      restoredFocusedSurfaceIDs[entry.tabID] = rootNode.leftmostLeaf().id
      restoredTabs.append(
        TerminalTabItem(
          id: entry.tabID,
          title: entry.snapshotTab.title ?? "\(worktree.name) \(index + 1)",
          customTitle: entry.snapshotTab.customTitle,
          icon: entry.snapshotTab.icon ?? "terminal",
          isTitleLocked: false,
          iconLock: entry.snapshotTab.icon != nil ? .user : .auto
        )
      )
    }

    trees = restoredTrees
    focusedSurfaceIdByTab = restoredFocusedSurfaceIDs
    tabIsRunningById = Dictionary(
      restoredTabs.map { ($0.id, false) },
      uniquingKeysWith: { first, _ in first }
    )
    tabManager.tabs = restoredTabs
    tabManager.selectedTabId = selectedTabID
    setRunScriptTabId(nil)

    for tab in restoredTabs {
      _ = registerTargetHandle(for: tab.id)
      for surface in restoredTrees[tab.id]?.leaves() ?? [] {
        _ = registerTargetHandle(for: surface.id)
      }
    }

    // Explicitly unfocus all restored surfaces so only the focused one blinks.
    for surface in surfaces.values {
      surface.focusDidChange(false)
    }
    if let selectedTabID {
      focusSurface(in: selectedTabID)
    } else {
      lastEmittedFocusSurfaceId = nil
    }
    emitTaskStatusIfChanged()
    // Signal "this worktree now has tabs" so downstream Shelf
    // bookkeeping (`markWorktreeOpened` via `terminalEvent(.tabCreated)`)
    // adds the restored worktree to `openedWorktreeIDs`. Without this
    // emit, only the active worktree (which goes through
    // `.selectWorktree` on `.layoutRestored`) shows as a book on the
    // Shelf - every other restored worktree is missing, even though
    // the sidebar lists it and its terminal state is live.
    if !restoredTabs.isEmpty {
      onTabCreated?()
    }
    terminalStateLogger.info(
      "[LayoutRestore] applySnapshot: success, restored \(restoredTabs.count) tab(s)"
        + " selectedTab=\(selectedTabID?.rawValue.uuidString ?? "nil")"
    )
    return true
  }

  static func resolveSnapshotWorkingDirectory(
    from snapshotPath: String?,
    worktreeRoot: URL,
    fileManager: FileManager = .default
  ) -> URL? {
    guard let snapshotPath,
      let normalizedPath = PathPolicy.normalizePath(snapshotPath, relativeTo: worktreeRoot)
    else {
      return nil
    }

    let normalizedURL = URL(fileURLWithPath: normalizedPath).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: normalizedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
      return nil
    }
    guard PathPolicy.contains(normalizedURL, in: worktreeRoot) else {
      return nil
    }
    return normalizedURL
  }

  func makeLayoutSnapshotNode(
    from node: SplitTree<GhosttySurfaceView>.Node
  ) -> TerminalLayoutSnapshotPayload.SnapshotSplitNode? {
    switch node {
    case .leaf(let view):
      let cwdPath = inheritedSurfaceConfig(
        fromSurfaceId: view.id,
        context: GHOSTTY_SURFACE_CONTEXT_TAB
      ).workingDirectory?.path(percentEncoded: false)
      return .leaf(surfaceID: view.id.uuidString, cwdPath: cwdPath)
    case .split(let split):
      guard let left = makeLayoutSnapshotNode(from: split.left) else {
        return nil
      }
      guard let right = makeLayoutSnapshotNode(from: split.right) else {
        return nil
      }
      return .split(
        direction: snapshotSplitDirection(from: split.direction),
        ratio: split.ratio,
        children: [left, right]
      )
    }
  }

  func restoreSplitNode(
    from snapshotNode: TerminalLayoutSnapshotPayload.SnapshotSplitNode,
    tabID: TerminalTabID,
    isRoot: Bool
  ) -> SplitTree<GhosttySurfaceView>.Node? {
    switch snapshotNode.kind {
    case .leaf:
      guard let surfaceID = snapshotNode.surfaceID,
        !surfaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        return nil
      }
      let context: ghostty_surface_context_e = isRoot ? GHOSTTY_SURFACE_CONTEXT_TAB : GHOSTTY_SURFACE_CONTEXT_SPLIT
      let restoredWorkingDirectory = Self.resolveSnapshotWorkingDirectory(
        from: snapshotNode.cwdPath,
        worktreeRoot: worktree.workingDirectory
      )
      let view = createSurface(
        tabId: tabID,
        initialInput: nil,
        inheritingFromSurfaceId: nil,
        workingDirectoryOverride: restoredWorkingDirectory,
        context: context
      )
      return .leaf(view: view)
    case .split:
      guard let direction = snapshotNode.direction else {
        return nil
      }
      guard let ratio = snapshotNode.ratio, ratio > 0, ratio < 1 else {
        return nil
      }
      let clampedRatio = max(0.1, min(0.9, ratio))
      guard let children = snapshotNode.children, children.count == 2 else {
        return nil
      }
      guard let left = restoreSplitNode(from: children[0], tabID: tabID, isRoot: false) else {
        return nil
      }
      guard let right = restoreSplitNode(from: children[1], tabID: tabID, isRoot: false) else {
        return nil
      }
      return .split(
        .init(
          direction: splitDirection(from: direction),
          ratio: clampedRatio,
          left: left,
          right: right
        )
      )
    }
  }

  func snapshotSplitDirection(
    from direction: SplitTree<GhosttySurfaceView>.Direction
  ) -> TerminalLayoutSnapshotSplitDirection {
    switch direction {
    case .horizontal:
      .horizontal
    case .vertical:
      .vertical
    }
  }

  func splitDirection(
    from direction: TerminalLayoutSnapshotSplitDirection
  ) -> SplitTree<GhosttySurfaceView>.Direction {
    switch direction {
    case .horizontal:
      .horizontal
    case .vertical:
      .vertical
    }
  }
}
