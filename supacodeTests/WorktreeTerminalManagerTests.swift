import ConcurrencyExtras
import DependenciesTestSupport
import Foundation
import GhosttyKit
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct WorktreeTerminalManagerTests {
  @Test func buffersEventsUntilStreamCreated() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.onSetupScriptConsumed?()

    let stream = manager.eventStream()
    let event = await nextEvent(stream) { event in
      if case .setupScriptConsumed = event {
        return true
      }
      return false
    }

    #expect(event == .setupScriptConsumed(worktreeID: worktree.id))
  }

  @Test func emitsEventsAfterStreamCreated() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let stream = manager.eventStream()
    let eventTask = Task {
      await nextEvent(stream) { event in
        if case .setupScriptConsumed = event {
          return true
        }
        return false
      }
    }

    state.onSetupScriptConsumed?()

    let event = await eventTask.value
    #expect(event == .setupScriptConsumed(worktreeID: worktree.id))
  }

  @Test func syncPreferredFontSizeNoOpForMissingState() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let stream = manager.eventStream()
    var iterator = stream.makeAsyncIterator()

    manager.syncPreferredFontSize(from: "/nonexistent")

    // Should not emit font event; only the notification indicator event
    let first = await iterator.next()
    #expect(first == .notificationIndicatorChanged(count: 0))
  }

  @Test func onFontSizeAdjustedCallbackIsWired() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    #expect(state.onFontSizeAdjusted != nil)
  }

  @Test func closeTargetAvailabilityFollowsTerminalModelState() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    #expect(state.canCloseFocusedTab == false)
    #expect(state.canCloseFocusedSurface == false)

    let tabId = state.createTab()

    #expect(tabId != nil)
    #expect(state.canCloseFocusedTab == true)
    #expect(state.canCloseFocusedSurface == true)

    if let tabId {
      state.closeTab(tabId)
    }

    #expect(state.canCloseFocusedTab == false)
    #expect(state.canCloseFocusedSurface == false)
  }

  @Test func newEmptyTabStartsColdAgentDetection() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let tabId = try #require(state.createTab())
    let surfaceId = try #require(state.focusedSurfaceId(in: tabId))

    #expect(state.agentDetectionSchedules[surfaceId] == nil)
    #expect(state.agentDetectionTasks[surfaceId] == nil)
  }

  @Test func wakingSurfaceStartsWarmAgentDetection() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let tabId = try #require(state.createTab())
    let surfaceId = try #require(state.focusedSurfaceId(in: tabId))

    state.wakeAgentDetection(forSurfaceID: surfaceId)

    let schedule = try #require(state.agentDetectionSchedules[surfaceId])
    #expect(schedule.nextInterval(now: Date()) != nil)
    #expect(state.agentDetectionTasks[surfaceId] != nil)

    state.cleanupAllAgentDetectionState()
  }

  @Test func initialInputStartsWarmAgentDetection() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let tabId = try #require(state.createTab(initialInput: "codex\n"))
    let surfaceId = try #require(state.focusedSurfaceId(in: tabId))

    let schedule = try #require(state.agentDetectionSchedules[surfaceId])
    #expect(schedule.nextInterval(now: Date()) != nil)
    #expect(state.agentDetectionTasks[surfaceId] != nil)

    state.cleanupAllAgentDetectionState()
  }

  @Test func backgroundProfileSplitInHiddenWorktreePreservesVisibleSelection() throws {
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      skipsSurfaceCreationForTesting: true
    )
    let visibleWorktree = makeWorktree(id: "/tmp/repo/visible", name: "visible")
    let hiddenWorktree = makeWorktree(id: "/tmp/repo/hidden", name: "hidden")
    let visibleState = manager.state(for: visibleWorktree)
    let hiddenState = manager.state(for: hiddenWorktree)
    defer {
      visibleState.cleanupAllAgentDetectionState()
      hiddenState.cleanupAllAgentDetectionState()
    }

    let visibleTab = try #require(visibleState.createTab())
    let visiblePane = try #require(visibleState.focusedSurfaceId(in: visibleTab))
    let hiddenTab = try #require(hiddenState.createTab())
    let hiddenAnchor = try #require(hiddenState.focusedSurfaceId(in: hiddenTab))
    manager.selectedWorktreeID = visibleWorktree.id
    let profileID = UUID()
    let plan = AgentProfileLaunchPlan(
      profileID: profileID,
      profileName: "Reviewer",
      runtime: .claude,
      invocation: AgentInvocation(executable: ":", arguments: []),
      commandEnvironmentTokens: [],
      placement: .split,
      splitDirection: .right,
      surfaceEnvironment: [:],
      dedicatedHome: nil
    )

    let launched = try manager.launchAgentProfile(
      AgentProfileLaunchRequest(
        plan: plan,
        placement: .split(anchor: hiddenAnchor, direction: .right, background: true)
      ),
      in: hiddenWorktree
    ).get()

    #expect(manager.selectedWorktreeID == visibleWorktree.id)
    #expect(visibleState.tabManager.selectedTabId == visibleTab)
    #expect(visibleState.currentFocusedSurfaceId() == visiblePane)
    #expect(hiddenState.tabManager.selectedTabId == hiddenTab)
    #expect(hiddenState.focusedSurfaceId(in: hiddenTab) == hiddenAnchor)
    #expect(launched.tabID == hiddenTab)
  }

  @Test func startupHookMaintenanceSweepsAgedCrashForwardingRecords() throws {
    let base = FileManager.default.temporaryDirectory.appending(
      path: "prowl-tests-forward-startup-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: base) }
    var oldStore: CodexForwardingRecordStore? = try CodexForwardingRecordStore(
      baseDirectory: base,
      orphanMaximumAge: 60,
      now: { Date(timeIntervalSince1970: 100) }
    )
    let oldRecord = try #require(oldStore).create(argv: ["/tmp/notifier"])
    oldStore = nil
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      forwardingRecordBaseDirectory: base
    )

    manager.startAgentHookRuntimeMaintenance()

    #expect(!FileManager.default.fileExists(atPath: oldRecord.locator.path(percentEncoded: false)))
  }

  @Test func menuSplitProfileFallsBackToATabWhenNoAnchorExists() async throws {
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      hookResourcesProvider: { nil },
      skipsSurfaceCreationForTesting: true
    )
    let worktree = makeWorktree()
    let profileID = UUID()
    let plan = AgentProfileLaunchPlan(
      profileID: profileID,
      profileName: "Codex",
      runtime: .codex,
      invocation: AgentInvocation(executable: "codex", arguments: []),
      commandEnvironmentTokens: [],
      placement: .split,
      splitDirection: .right,
      surfaceEnvironment: [:],
      dedicatedHome: nil
    )
    let stream = manager.eventStream()

    manager.handleCommand(.launchAgentProfile(worktree, plan: plan))
    let event = await nextEvent(stream) {
      switch $0 {
      case .agentProfileLaunched, .agentProfileLaunchFailed: true
      default: false
      }
    }

    #expect(event == .agentProfileLaunched(worktreeID: worktree.id, profileID: profileID))
    #expect(manager.state(for: worktree).tabManager.tabs.count == 1)
  }

  @Test func unavailableHookResourcesWarnOnceAndLaunchTheOriginalInvocation() async throws {
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      hookResourcesProvider: { nil },
      skipsSurfaceCreationForTesting: true
    )
    let worktree = makeWorktree()
    let original = AgentProfileLaunchPlan(
      profileID: UUID(),
      profileName: "Codex",
      runtime: .codex,
      invocation: AgentInvocation(executable: "codex", arguments: ["Prompt"]),
      commandEnvironmentTokens: [],
      placement: .tab,
      splitDirection: .right,
      surfaceEnvironment: [AgentProfileLaunchPlanner.promptCarrierName: "Prompt"],
      dedicatedHome: nil
    )
    let request = AgentProfileLaunchRequest(plan: original, placement: .tab(background: false))

    let preparation = try await manager.prepareAgentProfileLaunch(request, in: worktree).get()

    #expect(preparation.warnings.count == 1)
    #expect(preparation.warnings[0].code == .managedHookDegraded)
    #expect(preparation.context.request.plan.invocation == original.invocation)
    #expect(preparation.context.request.plan.hookRegistration == nil)
    let launched = try manager.launchPreparedAgentProfile(preparation, in: worktree).get()
    #expect(manager.state(for: worktree).surfaceView(for: launched.surfaceID) != nil)
    manager.state(for: worktree).cleanupAllAgentDetectionState()
  }

  @Test func promptedManagedHookLaunchBindsDispatchToTheRegistrationEpoch() throws {
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      skipsSurfaceCreationForTesting: true
    )
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let base = AgentProfileLaunchPlan(
      profileID: UUID(),
      profileName: "Codex",
      runtime: .codex,
      invocation: AgentInvocation(executable: "codex", arguments: ["Prompt"]),
      commandEnvironmentTokens: [],
      placement: .tab,
      splitDirection: .right,
      surfaceEnvironment: [AgentProfileLaunchPlanner.promptCarrierName: "Prompt"],
      dedicatedHome: nil
    )
    let plan = base.applyingManagedHook(
      AgentHookPreparedInvocation(
        invocation: AgentInvocation(executable: "codex", arguments: ["-c", "notify=[]", "Prompt"]),
        argumentValues: [1: "notify=[]"]
      ),
      resources: AgentHookResources(bundledCLIPath: "/bundle/prowl", socketPath: "/tmp/prowl.sock"),
      launchCWD: worktree.workingDirectory,
      token: "token",
      nativeEvents: ["agent-turn-complete": .turnEnded],
      coveredEvents: [.turnEnded]
    )
    let launched = try manager.launchAgentProfile(
      AgentProfileLaunchRequest(plan: plan, placement: .tab(background: false)),
      in: worktree
    ).get()
    let registrationEpoch = try #require(manager.agentEvidenceEpochForTesting(surfaceID: launched.surfaceID))
    let dispatch = try manager.issueAgentDispatch()
    let dispatchID = dispatch.record.id
    let target = TabResolvedTarget(
      worktreeID: worktree.id,
      worktreeName: worktree.name,
      worktreePath: worktree.workingDirectory.path,
      worktreeRootPath: worktree.repositoryRootURL.path,
      worktreeKind: "git",
      tabID: launched.tabID.rawValue.uuidString,
      tabTitle: "Codex",
      tabSelected: true,
      paneID: launched.surfaceID.uuidString,
      paneTitle: "codex",
      paneCWD: worktree.workingDirectory.path,
      paneFocused: true
    )

    try manager.bindAgentDispatch(dispatchID: dispatchID, target: target)

    #expect(manager.agentDispatchSnapshot(dispatchID: dispatchID)?.binding?.evidenceEpoch == registrationEpoch)
    state.cleanupAllAgentDetectionState()
  }

  @Test func firstTabUsesTabSurfaceContext() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let tabId = try #require(state.createTab())
    let surfaceId = try #require(state.focusedSurfaceId(in: tabId))
    let surface = try #require(state.surfaceView(for: surfaceId))

    #expect(surface.surfaceContextForTesting == GHOSTTY_SURFACE_CONTEXT_TAB)
  }

  @Test func splitTreeDoesNotRecreateSurfaceForClosedTab() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let tabId = try #require(state.createTab())
    let surfaceId = try #require(state.focusedSurfaceId(in: tabId))

    state.closeTab(tabId)
    let staleTree = state.splitTree(for: tabId)

    #expect(staleTree.isEmpty)
    #expect(state.surfaceView(for: surfaceId) == nil)
    #expect(state.surfaceView(for: tabId) == nil)
  }

  @Test func ghosttyCloseRequestDoesNotRecreateSurfaceForClosedTab() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let tabId = try #require(state.createTab())
    let surfaceId = try #require(state.focusedSurfaceId(in: tabId))
    let surface = try #require(state.surfaceView(for: surfaceId))

    surface.bridge.closeSurface(processAlive: false)
    let staleTree = state.splitTree(for: tabId)

    #expect(staleTree.isEmpty)
    #expect(state.tabManager.tabs.isEmpty)
    #expect(state.surfaceView(for: surfaceId) == nil)
    #expect(state.surfaceView(for: tabId) == nil)
  }

  @Test func closeSurfaceReturnsActualRemovalResult() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let tabId = try #require(state.createTab())
    let surfaceId = try #require(state.focusedSurfaceId(in: tabId))

    #expect(state.closeSurface(id: surfaceId, confirmation: .skip) == true)
    #expect(state.surfaceView(for: surfaceId) == nil)
    #expect(state.tabManager.tabs.isEmpty)
    #expect(state.closeSurface(id: surfaceId, confirmation: .skip) == false)
  }

  @Test func targetHandlesAreGlobalAndReassignedAfterClose() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let firstWorktree = makeWorktree()
    let secondWorktree = makeWorktree(id: "/tmp/repo/wt-2", name: "wt-2")
    let firstState = manager.state(for: firstWorktree)
    let secondState = manager.state(for: secondWorktree)

    let firstTabID = try #require(firstState.createTab())
    let firstPaneID = try #require(firstState.focusedSurfaceId(in: firstTabID))
    let secondTabID = try #require(secondState.createTab())
    let secondPaneID = try #require(secondState.focusedSurfaceId(in: secondTabID))

    #expect(firstState.tabHandle(for: firstTabID) == 1)
    #expect(firstState.paneHandle(for: firstPaneID) == 2)
    #expect(secondState.tabHandle(for: secondTabID) == 3)
    #expect(secondState.paneHandle(for: secondPaneID) == 4)

    #expect(firstState.closeTab(firstTabID, confirmation: .skip))
    #expect(firstState.tabHandle(for: firstTabID) == nil)
    #expect(firstState.paneHandle(for: firstPaneID) == nil)

    let replacementTabID = try #require(firstState.createTab())
    let replacementPaneID = try #require(firstState.focusedSurfaceId(in: replacementTabID))

    #expect(firstState.tabHandle(for: replacementTabID) == 5)
    #expect(firstState.paneHandle(for: replacementPaneID) == 6)
  }

  @Test func layoutRestoreReassignsHandlesForRestoredTabIDs() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let tabID = try #require(state.createTab())
    let originalPaneID = try #require(state.focusedSurfaceId(in: tabID))
    let originalTabHandle = try #require(state.tabHandle(for: tabID))
    let originalPaneHandle = try #require(state.paneHandle(for: originalPaneID))
    let snapshot = try #require(state.makeLayoutSnapshotWorktree())

    #expect(state.applyLayoutSnapshot(snapshot))

    let restoredTabID = try #require(state.tabManager.tabs.first?.id)
    let restoredPaneID = try #require(state.focusedSurfaceId(in: restoredTabID))
    let restoredTabHandle = try #require(state.tabHandle(for: restoredTabID))
    let restoredPaneHandle = try #require(state.paneHandle(for: restoredPaneID))

    #expect(restoredTabID == tabID)
    #expect(restoredTabHandle > originalTabHandle)
    #expect(restoredPaneHandle > originalPaneHandle)
    #expect(state.paneHandle(for: originalPaneID) == nil)
  }

  @Test func notificationIndicatorUsesCurrentCountOnStreamStart() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.notifications = [
      WorktreeTerminalNotification(
        surfaceId: UUID(),
        title: "Unread",
        body: "body",
        isRead: false
      )
    ]
    state.onNotificationIndicatorChanged?()
    state.notifications = [
      WorktreeTerminalNotification(
        surfaceId: UUID(),
        title: "Read",
        body: "body",
        isRead: true
      )
    ]

    let stream = manager.eventStream()
    var iterator = stream.makeAsyncIterator()

    let first = await iterator.next()
    state.onSetupScriptConsumed?()
    let second = await iterator.next()

    #expect(first == .notificationIndicatorChanged(count: 0))
    #expect(second == .setupScriptConsumed(worktreeID: worktree.id))
  }

  @Test func taskStatusReflectsAnyRunningTab() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    #expect(manager.taskStatus(for: worktree.id) == .idle)

    let tab1 = TerminalTabID()
    let tab2 = TerminalTabID()
    state.tabIsRunningById[tab1] = false
    state.tabIsRunningById[tab2] = false
    #expect(manager.taskStatus(for: worktree.id) == .idle)

    state.tabIsRunningById[tab2] = true
    #expect(manager.taskStatus(for: worktree.id) == .running)

    state.tabIsRunningById[tab1] = true
    #expect(manager.taskStatus(for: worktree.id) == .running)

    state.tabIsRunningById[tab2] = false
    #expect(manager.taskStatus(for: worktree.id) == .running)

    state.tabIsRunningById[tab1] = false
    #expect(manager.taskStatus(for: worktree.id) == .idle)
  }

  @Test func hasUnseenNotificationsReflectsUnreadEntries() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.notifications = [
      makeNotification(isRead: true),
      makeNotification(isRead: true),
    ]

    #expect(manager.hasUnseenNotifications(for: worktree.id) == false)

    state.notifications.append(makeNotification(isRead: false))

    #expect(manager.hasUnseenNotifications(for: worktree.id) == true)
  }

  @Test func markAllNotificationsReadEmitsUpdatedIndicatorCount() async {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.notifications = [
      makeNotification(isRead: false),
      makeNotification(isRead: true),
    ]

    let stream = manager.eventStream()
    var iterator = stream.makeAsyncIterator()

    let first = await iterator.next()
    state.markAllNotificationsRead()
    let second = await iterator.next()

    #expect(first == .notificationIndicatorChanged(count: 1))
    #expect(second == .notificationIndicatorChanged(count: 0))
    #expect(state.notifications.map(\.isRead) == [true, true])
  }

  @Test func markNotificationsReadOnlyAffectsMatchingSurface() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let surfaceA = UUID()
    let surfaceB = UUID()

    state.notifications = [
      makeNotification(surfaceId: surfaceA, isRead: false),
      makeNotification(surfaceId: surfaceB, isRead: false),
      makeNotification(surfaceId: surfaceB, isRead: true),
    ]

    state.markNotificationsRead(forSurfaceID: surfaceB)

    let aNotifications = state.notifications.filter { $0.surfaceId == surfaceA }
    let bNotifications = state.notifications.filter { $0.surfaceId == surfaceB }

    #expect(aNotifications.map(\.isRead) == [false])
    #expect(bNotifications.map(\.isRead) == [true, true])
    #expect(manager.hasUnseenNotifications(for: worktree.id) == true)

    state.markNotificationsRead(forSurfaceID: surfaceA)

    #expect(manager.hasUnseenNotifications(for: worktree.id) == false)
  }

  @Test func markNotificationReadOnlyAffectsMatchingID() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let notificationA = UUID()
    let notificationB = UUID()
    let surfaceID = UUID()

    state.notifications = [
      makeNotification(id: notificationA, surfaceId: surfaceID, isRead: false),
      makeNotification(id: notificationB, surfaceId: surfaceID, isRead: false),
    ]

    state.markNotificationRead(id: notificationB)

    #expect(state.notifications.map(\.isRead) == [false, true])
    #expect(manager.hasUnseenNotifications(for: worktree.id) == true)
  }

  @Test func latestUnreadNotificationLocationChoosesNewestFocusableAcrossWorktrees() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktreeA = makeWorktree(id: "/tmp/repo/wt-a", name: "wt-a")
    let worktreeB = makeWorktree(id: "/tmp/repo/wt-b", name: "wt-b")
    let stateA = manager.state(for: worktreeA)
    let stateB = manager.state(for: worktreeB)
    let tabA = stateA.createTab()!
    let tabB = stateB.createTab()!
    let surfaceA = stateA.focusedSurfaceId(in: tabA)!
    let surfaceB = stateB.focusedSurfaceId(in: tabB)!
    let notificationA = UUID()
    let notificationB = UUID()

    stateA.notifications = [
      makeNotification(
        id: notificationA,
        surfaceId: surfaceA,
        createdAt: Date(timeIntervalSince1970: 10),
        isRead: false
      )
    ]
    stateB.notifications = [
      makeNotification(
        id: notificationB,
        surfaceId: surfaceB,
        createdAt: Date(timeIntervalSince1970: 20),
        isRead: false
      )
    ]

    #expect(
      manager.latestUnreadNotificationLocation()
        == NotificationLocation(
          worktreeID: worktreeB.id,
          tabID: tabB,
          surfaceID: surfaceB,
          notificationID: notificationB
        )
    )
  }

  @Test func latestUnreadNotificationLocationSkipsClosedSurfaces() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let tabID = state.createTab()!
    let surfaceID = state.focusedSurfaceId(in: tabID)!
    let focusableNotification = UUID()

    state.notifications = [
      makeNotification(
        surfaceId: UUID(),
        createdAt: Date(timeIntervalSince1970: 20),
        isRead: false
      ),
      makeNotification(
        id: focusableNotification,
        surfaceId: surfaceID,
        createdAt: Date(timeIntervalSince1970: 10),
        isRead: false
      ),
    ]

    #expect(
      manager.latestUnreadNotificationLocation()
        == NotificationLocation(
          worktreeID: worktree.id,
          tabID: tabID,
          surfaceID: surfaceID,
          notificationID: focusableNotification
        )
    )
  }

  @Test func setNotificationsDisabledMarksAllRead() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.notifications = [
      makeNotification(isRead: false),
      makeNotification(isRead: false),
    ]

    state.setNotificationsEnabled(false)

    #expect(state.notifications.map(\.isRead) == [true, true])
    #expect(manager.hasUnseenNotifications(for: worktree.id) == false)
  }

  @Test func dismissAllNotificationsClearsState() {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    state.notifications = [
      makeNotification(isRead: false),
      makeNotification(isRead: true),
    ]

    state.dismissAllNotifications()

    #expect(state.notifications.isEmpty)
    #expect(manager.hasUnseenNotifications(for: worktree.id) == false)
  }

  @Test func makeLayoutSnapshotPersistsCustomTabTitle() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let tabID = try #require(state.createTab())

    state.tabManager.updateTitle(tabID, title: "npm test")
    state.tabManager.setCustomTitle(tabID, title: "Build")

    let snapshot = try #require(state.makeLayoutSnapshotWorktree())

    #expect(snapshot.tabs.first?.title == "npm test")
    #expect(snapshot.tabs.first?.customTitle == "Build")
  }

  @Test func applyLayoutSnapshotRestoresCustomTabTitle() throws {
    let tabID = UUID()
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)
    let snapshot = TerminalLayoutSnapshotPayload.SnapshotWorktree(
      worktreeID: worktree.id,
      selectedTabID: tabID.uuidString,
      tabs: [
        TerminalLayoutSnapshotPayload.SnapshotTab(
          tabID: tabID.uuidString,
          title: "npm test",
          customTitle: "Build",
          icon: nil,
          splitRoot: .leaf(surfaceID: UUID().uuidString)
        )
      ]
    )

    #expect(state.applyLayoutSnapshot(snapshot))
    let restored = try #require(state.tabManager.tabs.first)

    #expect(restored.title == "npm test")
    #expect(restored.customTitle == "Build")
    #expect(restored.displayTitle == "Build")
    #expect(restored.isTitleLocked == false)
  }

  @Test func restoreLayoutSnapshotFailClosedClearsSnapshotWhenWorktreeMissing() async {
    let clearCount = LockIsolated(0)
    let snapshot = TerminalLayoutSnapshotPayload(
      worktrees: [
        TerminalLayoutSnapshotPayload.SnapshotWorktree(
          worktreeID: "/tmp/repo/wt-1",
          selectedTabID: "F96839F5-1371-4841-9E41-49124D918A67",
          tabs: [
            TerminalLayoutSnapshotPayload.SnapshotTab(
              tabID: "F96839F5-1371-4841-9E41-49124D918A67",
              title: nil,
              icon: nil,
              splitRoot: .leaf(surfaceID: "9B2F6D8C-44A4-42C5-8F9E-962108301901")
            )
          ]
        )
      ]
    )
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      layoutPersistence: TerminalLayoutPersistenceClient(
        loadSnapshot: { snapshot },
        saveSnapshot: { _ in true },
        clearSnapshot: {
          clearCount.withValue { $0 += 1 }
          return true
        }
      )
    )
    let stream = manager.eventStream()

    await manager.restoreLayoutSnapshot(from: [])

    let event = await nextEvent(stream) { event in
      if case .layoutRestoreFailed = event {
        return true
      }
      return false
    }

    #expect(clearCount.value == 1)
    #expect(event == .layoutRestoreFailed(message: "Saved terminal layout was invalid and has been reset"))
  }

  @Test func restoreLayoutSnapshotEmitsRestoredNilWhenSnapshotMissing() async {
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      layoutPersistence: TerminalLayoutPersistenceClient(
        loadSnapshot: { nil },
        saveSnapshot: { _ in true },
        clearSnapshot: { true }
      )
    )
    let stream = manager.eventStream()

    await manager.restoreLayoutSnapshot(from: [makeWorktree()])

    let event = await nextEvent(stream) { event in
      event == .layoutRestored(selectedWorktreeID: nil)
    }

    #expect(event == .layoutRestored(selectedWorktreeID: nil))
  }

  @Test func persistLayoutSnapshotWithoutTabsClearsSnapshot() async {
    let clearCount = LockIsolated(0)
    let saveCount = LockIsolated(0)
    let manager = WorktreeTerminalManager(
      runtime: GhosttyRuntime(),
      layoutPersistence: TerminalLayoutPersistenceClient(
        loadSnapshot: { nil },
        saveSnapshot: { _ in
          saveCount.withValue { $0 += 1 }
          return true
        },
        clearSnapshot: {
          clearCount.withValue { $0 += 1 }
          return true
        }
      )
    )

    await manager.persistLayoutSnapshot()

    #expect(saveCount.value == 0)
    #expect(clearCount.value == 1)
  }

  private func makeWorktree(
    id: Worktree.ID = "/tmp/repo/wt-1",
    name: String = "wt-1"
  ) -> Worktree {
    Worktree(
      id: id,
      name: name,
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: id),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo")
    )
  }

  @Test func busyAgentFoldsIntoTaskStatusAndEmits() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let tabId = try #require(state.createTab())
    let surfaceId = try #require(state.focusedSurfaceId(in: tabId))

    #expect(state.taskStatus == .idle)

    var emissions: [WorktreeTaskStatus] = []
    state.onTaskStatusChanged = { emissions.append($0) }

    // A working agent on the tab makes the worktree run, with one emission.
    state.surfaceAgentStates[surfaceId] = PaneAgentState(detectedAgent: .claude, state: .working)
    state.updateTabAgentBusyState(for: tabId)
    #expect(state.taskStatus == .running)
    #expect(emissions == [.running])

    // Idempotent while it stays busy — no duplicate emission.
    state.updateTabAgentBusyState(for: tabId)
    #expect(emissions == [.running])

    // Returning to idle clears the indicator and emits once more.
    state.surfaceAgentStates[surfaceId] = PaneAgentState(detectedAgent: .claude, state: .idle)
    state.updateTabAgentBusyState(for: tabId)
    #expect(state.taskStatus == .idle)
    #expect(emissions == [.running, .idle])

    state.cleanupAllAgentDetectionState()
  }

  @Test func tabTeardownClearsAgentBusyTaskStatus() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let tabId = try #require(state.createTab())
    let surfaceId = try #require(state.focusedSurfaceId(in: tabId))

    state.surfaceAgentStates[surfaceId] = PaneAgentState(detectedAgent: .claude, state: .working)
    state.updateTabAgentBusyState(for: tabId)
    #expect(state.taskStatus == .running)

    state.closeAllSurfaces()
    #expect(state.tabAgentBusyById.isEmpty)
    #expect(state.taskStatus == .idle)
  }

  @MainActor
  @Test func blockedAgentIsTrackedSeparatelyFromBusy() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let tabId = try #require(state.createTab())
    let surfaceId = try #require(state.focusedSurfaceId(in: tabId))

    // Working: busy, but nothing is waiting on the user.
    state.surfaceAgentStates[surfaceId] = PaneAgentState(detectedAgent: .claude, state: .working)
    state.updateTabAgentBusyState(for: tabId)
    #expect(state.taskStatus == .running)
    #expect(state.hasBlockedAgent == false)

    // working → blocked leaves the busy aggregate unchanged, so the blocked
    // flag is the only thing that can tell the sidebar to stop spinning.
    state.surfaceAgentStates[surfaceId] = PaneAgentState(detectedAgent: .claude, state: .blocked)
    state.updateTabAgentBusyState(for: tabId)
    #expect(state.taskStatus == .running)
    #expect(state.hasBlockedAgent)
    #expect(manager.hasBlockedAgent(for: worktree.id))

    // Answered: back to working, attention affordance clears.
    state.surfaceAgentStates[surfaceId] = PaneAgentState(detectedAgent: .claude, state: .working)
    state.updateTabAgentBusyState(for: tabId)
    #expect(state.hasBlockedAgent == false)

    state.closeAllSurfaces()
    #expect(state.tabAgentBlockedById.isEmpty)
    #expect(state.hasBlockedAgent == false)
  }

  @MainActor
  @Test func blockedFlagIgnoresPanesWithoutADetectedAgent() throws {
    let manager = WorktreeTerminalManager(runtime: GhosttyRuntime())
    let worktree = makeWorktree()
    let state = manager.state(for: worktree)

    let tabId = try #require(state.createTab())
    let surfaceId = try #require(state.focusedSurfaceId(in: tabId))

    // A bare shell can carry a stale raw state; without a detected agent it
    // must not light up the sidebar.
    state.surfaceAgentStates[surfaceId] = PaneAgentState(detectedAgent: nil, state: .blocked)
    state.updateTabAgentBusyState(for: tabId)
    #expect(state.hasBlockedAgent == false)
    #expect(state.taskStatus == .idle)
  }

  private func nextEvent(
    _ stream: AsyncStream<TerminalClient.Event>,
    matching predicate: (TerminalClient.Event) -> Bool
  ) async -> TerminalClient.Event? {
    for await event in stream where predicate(event) {
      return event
    }
    return nil
  }

  private func makeNotification(
    id: UUID = UUID(),
    surfaceId: UUID = UUID(),
    createdAt: Date = .distantPast,
    isRead: Bool
  ) -> WorktreeTerminalNotification {
    WorktreeTerminalNotification(
      id: id,
      surfaceId: surfaceId,
      title: "Title",
      body: "Body",
      createdAt: createdAt,
      isRead: isRead
    )
  }

}
