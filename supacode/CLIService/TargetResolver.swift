// supacode/CLIService/TargetResolver.swift
// Resolves target selectors against current app state.

import Foundation
import GhosttyKit
import ProwlCLIShared

/// Fully resolved target with metadata for response payload.
struct ResolvedTarget: Sendable {
  let worktreeID: String
  let worktreeName: String
  let worktreePath: String
  let worktreeRootPath: String
  let worktreeKind: ListCommandWorktree.Kind

  let tabID: UUID
  let tabTitle: String
  let tabSelected: Bool

  let paneID: UUID
  let paneTitle: String
  let paneCWD: String?
  let paneFocused: Bool

  let surfaceView: GhosttySurfaceView
}

enum TargetResolverError: Error {
  case notFound(String)
  case notUnique(String)
}

@MainActor
final class TargetResolver {
  typealias SnapshotProvider = @MainActor () -> TargetResolutionSnapshot

  private let snapshotProvider: SnapshotProvider

  init(snapshotProvider: @escaping SnapshotProvider) {
    self.snapshotProvider = snapshotProvider
  }

  func resolve(_ selector: TargetSelector) -> Result<ResolvedTarget, TargetResolverError> {
    let snapshot = snapshotProvider()
    switch selector {
    case .none:
      return resolveNone(snapshot)
    case .worktree(let value):
      return resolveWorktree(value, snapshot)
    case .tab(let value):
      return resolveTab(value, snapshot)
    case .pane(let value):
      return resolvePane(value, snapshot)
    case .auto(let value):
      return resolveAuto(value, snapshot)
    }
  }

  /// Resolves an explicit pane-or-tab lifecycle target without allowing worktree fallback.
  func resolveLifecycleTarget(_ selector: TargetSelector) -> Result<LifecycleResolvedTarget, TargetResolverError> {
    let snapshot = snapshotProvider()
    switch selector {
    case .pane(let value):
      return resolvePane(value, snapshot).map {
        LifecycleResolvedTarget(resource: .pane, target: TabResolvedTarget(from: $0))
      }
    case .tab(let value):
      return resolveTab(value, snapshot).map {
        LifecycleResolvedTarget(resource: .tab, target: TabResolvedTarget(from: $0))
      }
    case .auto(let value):
      if isPrefixedShortHandle(value, prefix: "p") {
        return resolvePane(value, snapshot).map {
          LifecycleResolvedTarget(resource: .pane, target: TabResolvedTarget(from: $0))
        }
      }
      if isPrefixedShortHandle(value, prefix: "t") {
        return resolveTab(value, snapshot).map {
          LifecycleResolvedTarget(resource: .tab, target: TabResolvedTarget(from: $0))
        }
      }
      guard UUID(uuidString: value) != nil else {
        return .failure(.notFound("Lifecycle target '\(value)' must be a pane/tab UUID or prefixed handle."))
      }
      if case .success(let target) = resolvePane(value, snapshot) {
        return .success(LifecycleResolvedTarget(resource: .pane, target: TabResolvedTarget(from: target)))
      }
      if case .success(let target) = resolveTab(value, snapshot) {
        return .success(LifecycleResolvedTarget(resource: .tab, target: TabResolvedTarget(from: target)))
      }
      return .failure(.notFound("Pane or tab '\(value)' not found."))
    case .none, .worktree:
      return .failure(.notFound("Lifecycle commands require an explicit pane or tab target."))
    }
  }

  // MARK: - .none: focused worktree → selected tab → focused pane

  private func resolveNone(_ snapshot: TargetResolutionSnapshot) -> Result<ResolvedTarget, TargetResolverError> {
    guard let focusedWorktreeID = snapshot.focusedWorktreeID else {
      return .failure(.notFound("No focused worktree."))
    }
    guard let worktree = snapshot.worktrees.first(where: { $0.id == focusedWorktreeID }) else {
      return .failure(.notFound("Focused worktree not found."))
    }
    guard let tab = worktree.tabs.first(where: { $0.selected }) else {
      return .failure(.notFound("No selected tab in focused worktree."))
    }
    guard let pane = tab.focusedPane else {
      return .failure(.notFound("No focused pane in selected tab."))
    }
    return .success(makeTarget(worktree: worktree, tab: tab, pane: pane, focusedWorktreeID: focusedWorktreeID))
  }

  // MARK: - .worktree: match by id, name, or path

  private func resolveWorktree(
    _ value: String,
    _ snapshot: TargetResolutionSnapshot
  ) -> Result<ResolvedTarget, TargetResolverError> {
    let matches = snapshot.worktrees.filter { worktree in
      worktree.id == value || worktree.name == value || worktree.path == value
    }
    guard !matches.isEmpty else {
      return .failure(.notFound("Worktree '\(value)' not found."))
    }
    guard matches.count == 1 else {
      return .failure(.notUnique("Worktree '\(value)' matches \(matches.count) worktrees."))
    }
    let worktree = matches[0]
    guard let tab = worktree.tabs.first(where: { $0.selected }) ?? worktree.tabs.first else {
      return .failure(.notFound("No tabs in worktree '\(value)'."))
    }
    guard let pane = tab.focusedPane ?? tab.panes.first else {
      return .failure(.notFound("No panes in worktree '\(value)'."))
    }
    return .success(makeTarget(worktree: worktree, tab: tab, pane: pane, focusedWorktreeID: snapshot.focusedWorktreeID))
  }

  // MARK: - .tab: find by UUID or short handle

  private func resolveTab(
    _ value: String,
    _ snapshot: TargetResolutionSnapshot
  ) -> Result<ResolvedTarget, TargetResolverError> {
    for worktree in snapshot.worktrees {
      for tab in worktree.tabs where matches(tab: tab, selector: value) {
        guard let pane = tab.focusedPane ?? tab.panes.first else {
          return .failure(.notFound("No panes in tab '\(value)'."))
        }
        return .success(
          makeTarget(
            worktree: worktree,
            tab: tab,
            pane: pane,
            focusedWorktreeID: snapshot.focusedWorktreeID
          ))
      }
    }
    return .failure(.notFound("Tab '\(value)' not found."))
  }

  // MARK: - .pane: find by UUID or short handle across all worktrees/tabs

  private func resolvePane(
    _ value: String,
    _ snapshot: TargetResolutionSnapshot
  ) -> Result<ResolvedTarget, TargetResolverError> {
    for worktree in snapshot.worktrees {
      for tab in worktree.tabs {
        for pane in tab.panes where matches(pane: pane, selector: value) {
          return .success(
            makeTarget(
              worktree: worktree,
              tab: tab,
              pane: pane,
              focusedWorktreeID: snapshot.focusedWorktreeID
            ))
        }
      }
    }
    return .failure(.notFound("Pane '\(value)' not found."))
  }

  // MARK: - .auto: typed handle → UUID → worktree

  private func resolveAuto(
    _ value: String,
    _ snapshot: TargetResolutionSnapshot
  ) -> Result<ResolvedTarget, TargetResolverError> {
    if isPrefixedShortHandle(value, prefix: "p") {
      return resolvePane(value, snapshot)
    }
    if isPrefixedShortHandle(value, prefix: "t") {
      return resolveTab(value, snapshot)
    }

    // Try as pane UUID first (most specific)
    if UUID(uuidString: value) != nil {
      if case .success(let target) = resolvePane(value, snapshot) {
        return .success(target)
      }
      if case .success(let target) = resolveTab(value, snapshot) {
        return .success(target)
      }
    }
    // Fall back to worktree (id / name / path)
    if case .success(let target) = resolveWorktree(value, snapshot) {
      return .success(target)
    }
    return .failure(.notFound("Target '\(value)' not found as pane, tab, or worktree."))
  }

  // MARK: - Helpers

  private func matches(tab: TargetResolutionSnapshot.Tab, selector: String) -> Bool {
    guard let handle = shortHandle(in: selector, prefix: "t") else {
      return UUID(uuidString: selector) == tab.id
    }
    return tab.handle == handle
  }

  private func matches(pane: TargetResolutionSnapshot.Pane, selector: String) -> Bool {
    guard let handle = shortHandle(in: selector, prefix: "p") else {
      return UUID(uuidString: selector) == pane.id
    }
    return pane.handle == handle
  }

  private func isPrefixedShortHandle(_ selector: String, prefix: Character) -> Bool {
    selector.lowercased().first == prefix && shortHandle(in: selector, prefix: prefix) != nil
  }

  private func shortHandle(in selector: String, prefix: Character) -> Int? {
    let normalized = selector.lowercased()
    let digits: Substring
    if normalized.first == prefix {
      digits = normalized.dropFirst()
    } else {
      digits = normalized[...]
    }
    guard
      !digits.isEmpty,
      digits.allSatisfy({ $0.isASCII && $0.isNumber }),
      let handle = Int(digits),
      handle > 0
    else {
      return nil
    }
    return handle
  }

  private func makeTarget(
    worktree: TargetResolutionSnapshot.Worktree,
    tab: TargetResolutionSnapshot.Tab,
    pane: TargetResolutionSnapshot.Pane,
    focusedWorktreeID: String?
  ) -> ResolvedTarget {
    let isFocusedWorktree = worktree.id == focusedWorktreeID
    return ResolvedTarget(
      worktreeID: worktree.id,
      worktreeName: worktree.name,
      worktreePath: worktree.path,
      worktreeRootPath: worktree.rootPath,
      worktreeKind: worktree.kind,
      tabID: tab.id,
      tabTitle: tab.title,
      tabSelected: tab.selected,
      paneID: pane.id,
      paneTitle: pane.title,
      paneCWD: pane.cwd,
      paneFocused: isFocusedWorktree && tab.selected && pane.isFocusedInTab,
      surfaceView: pane.surfaceView
    )
  }
}

// MARK: - Snapshot model (decouples from live state)

struct TargetResolutionSnapshot: Sendable {
  struct Worktree: Sendable {
    let id: String
    let name: String
    let path: String
    let rootPath: String
    let kind: ListCommandWorktree.Kind
    let tabs: [Tab]
  }

  struct Tab: Sendable {
    let id: UUID
    let handle: Int?
    let title: String
    let selected: Bool
    let panes: [Pane]
    let focusedPaneID: UUID?

    init(
      id: UUID,
      handle: Int? = nil,
      title: String,
      selected: Bool,
      panes: [Pane],
      focusedPaneID: UUID?
    ) {
      self.id = id
      self.handle = handle
      self.title = title
      self.selected = selected
      self.panes = panes
      self.focusedPaneID = focusedPaneID
    }

    var focusedPane: Pane? {
      guard let focusedPaneID else { return nil }
      return panes.first { $0.id == focusedPaneID }
    }
  }

  struct Pane: @unchecked Sendable {
    let id: UUID
    let handle: Int?
    let title: String
    let cwd: String?
    let isFocusedInTab: Bool
    let surfaceView: GhosttySurfaceView

    init(
      id: UUID,
      handle: Int? = nil,
      title: String,
      cwd: String?,
      isFocusedInTab: Bool,
      surfaceView: GhosttySurfaceView
    ) {
      self.id = id
      self.handle = handle
      self.title = title
      self.cwd = cwd
      self.isFocusedInTab = isFocusedInTab
      self.surfaceView = surfaceView
    }
  }

  let worktrees: [Worktree]
  let focusedWorktreeID: String?
}

// MARK: - Snapshot builder

@MainActor
enum TargetResolutionSnapshotBuilder {
  static func makeSnapshot(
    repositoriesState: RepositoriesFeature.State,
    terminalManager: WorktreeTerminalManager
  ) -> TargetResolutionSnapshot {
    var activeSnapshots: [String: WorktreeTerminalState] = [:]
    activeSnapshots.reserveCapacity(terminalManager.activeWorktreeStates.count)
    for state in terminalManager.activeWorktreeStates {
      activeSnapshots[state.worktreeID] = state
    }

    let orderedContexts = ListRuntimeSnapshotBuilder.orderedWorktreeContexts(from: repositoriesState)
    let focusedWorktreeID = terminalManager.selectedWorktreeID ?? terminalManager.canvasFocusedWorktreeID

    let worktrees: [TargetResolutionSnapshot.Worktree] = orderedContexts.compactMap { context in
      guard let state = activeSnapshots[context.id] else { return nil }
      let selectedTabID = state.tabManager.selectedTabId
      let tabs: [TargetResolutionSnapshot.Tab] = state.tabManager.tabs.compactMap { tab in
        let snapshot = state.makeCLISendSnapshot(for: tab.id)
        guard let snapshot else { return nil }
        return TargetResolutionSnapshot.Tab(
          id: tab.id.rawValue,
          handle: state.registerTargetHandle(for: tab.id),
          title: tab.displayTitle,
          selected: tab.id == selectedTabID,
          panes: snapshot.panes,
          focusedPaneID: snapshot.focusedPaneID
        )
      }
      guard !tabs.isEmpty else { return nil }
      return TargetResolutionSnapshot.Worktree(
        id: context.id,
        name: context.name,
        path: context.path,
        rootPath: context.rootPath,
        kind: context.kind,
        tabs: tabs
      )
    }

    return TargetResolutionSnapshot(worktrees: worktrees, focusedWorktreeID: focusedWorktreeID)
  }
}
