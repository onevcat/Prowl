import ConcurrencyExtras
import DependenciesTestSupport
import Foundation
import GhosttyKit
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
