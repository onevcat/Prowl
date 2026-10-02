import Foundation

nonisolated struct TerminalLayoutSnapshotPayload: Codable, Equatable, Sendable {
  nonisolated static let currentVersion = 2
  nonisolated static let minSupportedVersion = 1
  nonisolated static let maxSnapshotFileBytes = 2 * 1024 * 1024
  nonisolated static let maxWorktrees = 128
  nonisolated static let maxTabsPerWorktree = 128
  nonisolated static let maxSplitNodesPerTab = 1024
  nonisolated static let maxSplitDepth = 24

  let version: Int
  let selectedWorktreeID: String?
  let worktrees: [SnapshotWorktree]

  init(selectedWorktreeID: String? = nil, worktrees: [SnapshotWorktree]) {
    version = Self.currentVersion
    self.selectedWorktreeID = selectedWorktreeID
    self.worktrees = worktrees
  }

  init(version: Int, selectedWorktreeID: String? = nil, worktrees: [SnapshotWorktree]) {
    self.version = version
    self.selectedWorktreeID = selectedWorktreeID
    self.worktrees = worktrees
  }

  static func decodeValidated(from data: Data) -> TerminalLayoutSnapshotPayload? {
    guard !data.isEmpty, data.count <= Self.maxSnapshotFileBytes else {
      return nil
    }
    let decoder = JSONDecoder()
    guard let payload = try? decoder.decode(Self.self, from: data) else {
      return nil
    }
    let migrated = payload.migratedToCurrentVersion()
    return migrated.isValid ? migrated : nil
  }

  /// Upgrade v1 payloads to the current schema.
  ///
  /// In v1 the `title` field on `SnapshotTab` doubled as both the live shell
  /// title (which was frozen on restore) and the user's overridden title — they
  /// were indistinguishable on disk. After v2 the user override moves to
  /// `customTitle`, so promoting a v1 `title` to `customTitle` preserves what
  /// the user actually saw across the upgrade. The downside (a previously
  /// non-overridden tab now looks "pinned") is something the user can clear via
  /// the new inline rename.
  func migratedToCurrentVersion() -> TerminalLayoutSnapshotPayload {
    guard version < Self.currentVersion else { return self }
    let migratedWorktrees = worktrees.map { worktree -> SnapshotWorktree in
      let migratedTabs = worktree.tabs.map { tab -> SnapshotTab in
        guard tab.customTitle == nil, let title = tab.title else { return tab }
        return SnapshotTab(
          tabID: tab.tabID,
          title: nil,
          customTitle: title,
          icon: tab.icon,
          splitRoot: tab.splitRoot
        )
      }
      return SnapshotWorktree(
        worktreeID: worktree.worktreeID,
        selectedTabID: worktree.selectedTabID,
        tabs: migratedTabs
      )
    }
    return TerminalLayoutSnapshotPayload(
      version: Self.currentVersion,
      selectedWorktreeID: selectedWorktreeID,
      worktrees: migratedWorktrees
    )
  }

  var isValid: Bool {
    guard (Self.minSupportedVersion...Self.currentVersion).contains(version) else {
      return false
    }
    guard !worktrees.isEmpty, worktrees.count <= Self.maxWorktrees else {
      return false
    }
    guard
      worktrees.allSatisfy({
        $0.isValid(
          maxTabsPerWorktree: Self.maxTabsPerWorktree,
          maxSplitNodesPerTab: Self.maxSplitNodesPerTab,
          maxSplitDepth: Self.maxSplitDepth
        )
      })
    else {
      return false
    }
    if let selectedWorktreeID {
      guard worktrees.contains(where: { $0.worktreeID == selectedWorktreeID }) else {
        return false
      }
    }
    return true
  }
}

extension TerminalLayoutSnapshotPayload {
  nonisolated struct SnapshotWorktree: Codable, Equatable, Sendable {
    let worktreeID: String
    let selectedTabID: String?
    let tabs: [SnapshotTab]

    func isValid(
      maxTabsPerWorktree: Int,
      maxSplitNodesPerTab: Int,
      maxSplitDepth: Int
    ) -> Bool {
      guard hasContent(worktreeID) else {
        return false
      }
      guard !tabs.isEmpty, tabs.count <= maxTabsPerWorktree else {
        return false
      }

      var tabIDs: Set<String> = []
      for tab in tabs {
        guard tabIDs.insert(tab.tabID).inserted else {
          return false
        }
        guard tab.isValid(maxSplitNodesPerTab: maxSplitNodesPerTab, maxSplitDepth: maxSplitDepth) else {
          return false
        }
      }

      if let selectedTabID {
        return tabIDs.contains(selectedTabID)
      }
      return true
    }
  }

  nonisolated struct SnapshotTab: Codable, Equatable, Sendable {
    let tabID: String
    let title: String?
    let customTitle: String?
    let icon: String?
    let splitRoot: SnapshotSplitNode

    init(
      tabID: String,
      title: String?,
      customTitle: String? = nil,
      icon: String?,
      splitRoot: SnapshotSplitNode
    ) {
      self.tabID = tabID
      self.title = title
      self.customTitle = customTitle
      self.icon = icon
      self.splitRoot = splitRoot
    }

    func isValid(maxSplitNodesPerTab: Int, maxSplitDepth: Int) -> Bool {
      guard hasContent(tabID) else {
        return false
      }
      if let customTitle, !hasContent(customTitle) {
        return false
      }
      var nodeCount = 0
      return splitRoot.isValid(
        depth: 1,
        maxDepth: maxSplitDepth,
        nodeCount: &nodeCount,
        maxNodes: maxSplitNodesPerTab
      )
    }
  }

  nonisolated struct SnapshotSplitNode: Codable, Equatable, Sendable {
    let kind: TerminalLayoutSnapshotNodeKind
    let surfaceID: String?
    let cwdPath: String?
    let direction: TerminalLayoutSnapshotSplitDirection?
    let ratio: Double?
    let children: [SnapshotSplitNode]?

    static func leaf(surfaceID: String, cwdPath: String? = nil) -> SnapshotSplitNode {
      SnapshotSplitNode(
        kind: .leaf,
        surfaceID: surfaceID,
        cwdPath: cwdPath,
        direction: nil,
        ratio: nil,
        children: nil
      )
    }

    static func split(
      direction: TerminalLayoutSnapshotSplitDirection,
      ratio: Double,
      children: [SnapshotSplitNode]
    ) -> SnapshotSplitNode {
      SnapshotSplitNode(
        kind: .split,
        surfaceID: nil,
        cwdPath: nil,
        direction: direction,
        ratio: ratio,
        children: children
      )
    }

    func isValid(
      depth: Int,
      maxDepth: Int,
      nodeCount: inout Int,
      maxNodes: Int
    ) -> Bool {
      nodeCount += 1
      guard nodeCount <= maxNodes else {
        return false
      }

      switch kind {
      case .leaf:
        guard hasContent(surfaceID) else {
          return false
        }
        if let cwdPath, !hasContent(cwdPath) {
          return false
        }
        guard direction == nil, ratio == nil else {
          return false
        }
        return children == nil || children?.isEmpty == true

      case .split:
        guard depth < maxDepth else {
          return false
        }
        guard surfaceID == nil, cwdPath == nil else {
          return false
        }
        guard direction != nil else {
          return false
        }
        guard let ratio, ratio > 0, ratio < 1 else {
          return false
        }
        guard let children, children.count == 2 else {
          return false
        }
        return children.allSatisfy {
          $0.isValid(
            depth: depth + 1,
            maxDepth: maxDepth,
            nodeCount: &nodeCount,
            maxNodes: maxNodes
          )
        }
      }
    }
  }
}

nonisolated enum TerminalLayoutSnapshotNodeKind: String, Codable, Sendable {
  case leaf
  case split
}

nonisolated enum TerminalLayoutSnapshotSplitDirection: String, Codable, Sendable {
  case horizontal
  case vertical
}

private nonisolated func hasContent(_ value: String?) -> Bool {
  guard let value else {
    return false
  }
  return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
