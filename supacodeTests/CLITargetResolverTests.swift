import Foundation
import GhosttyKit
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct CLITargetResolverTests {
  @Test func explicitTabAndPaneSelectorsAcceptUUIDsAndShortHandles() throws {
    let tabID = UUID()
    let firstPaneID = UUID()
    let focusedPaneID = UUID()
    let snapshot = makeSnapshot(
      worktreeID: "worktree",
      worktreeName: "main",
      tab: (id: tabID, handle: 4),
      panes: [(id: firstPaneID, handle: 5), (id: focusedPaneID, handle: 6)],
      focusedPaneID: focusedPaneID
    )
    let resolver = TargetResolver { snapshot }

    for selector in [tabID.uuidString, "4", "t4"] {
      let target = try resolvedTarget(from: resolver.resolve(.tab(selector)))
      #expect(target.tabID == tabID)
      #expect(target.paneID == focusedPaneID)
    }

    for selector in [firstPaneID.uuidString, "5", "p5"] {
      let target = try resolvedTarget(from: resolver.resolve(.pane(selector)))
      #expect(target.paneID == firstPaneID)
    }
  }

  @Test func autoSelectorResolvesPrefixedHandlesAndKeepsBareNumbersForWorktrees() throws {
    let tabID = UUID()
    let paneID = UUID()
    let paneSnapshot = makeSnapshot(
      worktreeID: "pane-worktree",
      worktreeName: "other",
      tab: (id: tabID, handle: 1),
      panes: [(id: paneID, handle: 3)],
      focusedPaneID: nil
    )
    let numericWorktreeSnapshot = makeSnapshot(
      worktreeID: "numeric-worktree",
      worktreeName: "3",
      tab: (id: UUID(), handle: 4),
      panes: [(id: UUID(), handle: 5)],
      focusedPaneID: nil
    )
    let resolver = TargetResolver {
      TargetResolutionSnapshot(
        worktrees: [paneSnapshot.worktrees[0], numericWorktreeSnapshot.worktrees[0]],
        focusedWorktreeID: nil
      )
    }

    let paneTarget = try resolvedTarget(from: resolver.resolve(.auto("p3")))
    #expect(paneTarget.paneID == paneID)

    let tabTarget = try resolvedTarget(from: resolver.resolve(.auto("t1")))
    #expect(tabTarget.tabID == tabID)

    let numericTarget = try resolvedTarget(from: resolver.resolve(.auto("3")))
    #expect(numericTarget.worktreeID == "numeric-worktree")
  }

  @Test func lifecycleResolverRoutesOnlyTabsAndPanes() throws {
    let tabID = UUID()
    let paneID = UUID()
    let snapshot = makeSnapshot(
      worktreeID: "worktree",
      worktreeName: "main",
      tab: (id: tabID, handle: 6),
      panes: [(id: paneID, handle: 12)],
      focusedPaneID: paneID
    )
    let resolver = TargetResolver { snapshot }

    let pane = try lifecycleTarget(from: resolver.resolveLifecycleTarget(.auto("p12")))
    #expect(pane.resource == .pane)
    #expect(pane.target.paneID == paneID.uuidString)

    let tab = try lifecycleTarget(from: resolver.resolveLifecycleTarget(.auto("t6")))
    #expect(tab.resource == .tab)
    #expect(tab.target.tabID == tabID.uuidString)

    if case .failure(.notFound) = resolver.resolveLifecycleTarget(.worktree("main")) {
      // Expected: lifecycle operations never project a worktree to a tab or pane.
    } else {
      Issue.record("Lifecycle commands must reject worktree targets.")
    }
  }

  @Test func stalePrefixedHandleDoesNotFallBackToWorktree() {
    let snapshot = makeSnapshot(
      worktreeID: "p3-worktree",
      worktreeName: "p3",
      tab: (id: UUID(), handle: 1),
      panes: [(id: UUID(), handle: 2)],
      focusedPaneID: nil
    )
    let resolver = TargetResolver { snapshot }

    guard case .failure(.notFound(let message)) = resolver.resolve(.auto("p3")) else {
      Issue.record("A stale prefixed handle must not resolve as a worktree.")
      return
    }
    #expect(message.contains("Pane 'p3' not found"))
  }

  private func lifecycleTarget(
    from result: Result<LifecycleResolvedTarget, TargetResolverError>
  ) throws -> LifecycleResolvedTarget {
    switch result {
    case .success(let target):
      return target
    case .failure(let error):
      Issue.record("Unexpected lifecycle resolution failure: \(error)")
      throw error
    }
  }

  private func makeSnapshot(
    worktreeID: String,
    worktreeName: String,
    tab tabInfo: (id: UUID, handle: Int),
    panes: [(id: UUID, handle: Int)],
    focusedPaneID: UUID?
  ) -> TargetResolutionSnapshot {
    let runtime = GhosttyRuntime()
    let surfaceView = GhosttySurfaceView(
      runtime: runtime,
      workingDirectory: nil,
      context: GHOSTTY_SURFACE_CONTEXT_TAB,
      skipsSurfaceCreationForTesting: true
    )
    let targetPanes = panes.map { pane in
      TargetResolutionSnapshot.Pane(
        id: pane.id,
        handle: pane.handle,
        title: "shell",
        cwd: "/tmp/\(worktreeID)",
        isFocusedInTab: pane.id == focusedPaneID,
        surfaceView: surfaceView
      )
    }
    let tab = TargetResolutionSnapshot.Tab(
      id: tabInfo.id,
      handle: tabInfo.handle,
      title: "Tab",
      selected: true,
      panes: targetPanes,
      focusedPaneID: focusedPaneID
    )
    return TargetResolutionSnapshot(
      worktrees: [
        .init(
          id: worktreeID,
          name: worktreeName,
          path: "/tmp/\(worktreeID)",
          rootPath: "/tmp/\(worktreeID)",
          kind: .git,
          tabs: [tab]
        )
      ],
      focusedWorktreeID: worktreeID
    )
  }

  private func resolvedTarget(
    from result: Result<ResolvedTarget, TargetResolverError>
  ) throws -> ResolvedTarget {
    switch result {
    case .success(let target):
      return target
    case .failure(let error):
      Issue.record("Unexpected resolution failure: \(error)")
      throw error
    }
  }
}
