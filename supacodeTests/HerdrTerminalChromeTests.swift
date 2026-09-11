import AppKit
import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

@Suite(.serialized)
@MainActor
struct HerdrTerminalChromeTests {
  @Test func paneSetChangesRequireLifecycleRestart() {
    #expect(
      HerdrTerminalChromeFeature.paneSetRequiresLifecycleRestart(
        subscribedPaneIDs: ["p1"],
        snapshotPaneIDs: ["p1", "p2"]
      )
    )
    #expect(
      !HerdrTerminalChromeFeature.paneSetRequiresLifecycleRestart(
        subscribedPaneIDs: ["p1", "p2"],
        snapshotPaneIDs: ["p2", "p1"]
      )
    )
  }

  @Test(.dependencies) func focusEventInvalidatesInFlightRefreshGeneration() async {
    let clock = TestClock()
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connected
    initialState.snapshot = makeSnapshot(focusedPaneID: "p1")

    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.herdrTerminalChromeClient = HerdrTerminalChromeClient(
        snapshot: { .empty },
        subscribeEvents: { _ in
          HerdrEventSubscription(stream: AsyncStream { $0.finish() }, cancel: {})
        },
        focusWorkspace: { _ in },
        focusTab: { _ in },
        focusPane: { _ in },
        createWorkspace: {},
        createTab: { _, _, _ in },
        renameTab: { _, _ in },
        moveTab: { _, _ in },
        closeTab: { _ in },
        closeWorkspace: { _ in }
      )
    }

    await store.send(
      .eventStream(
        .event(
          HerdrEventEnvelope(
            event: "pane_focused",
            focus: HerdrFocusEvent(workspaceID: "w1", tabID: "t1", paneID: "p2")
          )
        )
      )
    ) {
      $0.refreshGeneration = 1
      $0.selectedWorkspaceID = "w1"
      $0.selectedTabID = "t1"
      $0.selectedPaneID = "p2"
    }
    await store.send(.refreshResponseWithGeneration(0, .success(makeSnapshot(focusedPaneID: "p1"))))
    #expect(store.state.selectedPaneID == "p2")
    #expect(store.state.snapshot.focusedPaneID == "p1")
    await store.send(.stop) {
      $0.connection = .hidden
      $0.snapshot = .empty
      $0.selectedWorkspaceID = nil
      $0.selectedTabID = nil
      $0.selectedPaneID = nil
      $0.refreshGeneration = 2
      $0.mutationGeneration = 1
    }
  }

  @Test func spacesMenuUsesANativeButtonHitTarget() {
    let button = HerdrSpacesMenuControl(menuProvider: { NSMenu() })
    button.frame = NSRect(x: 0, y: 0, width: 24, height: 24)

    #expect(button.target === button)
    #expect(button.action == #selector(HerdrSpacesMenuControl.presentMenu(_:)))
    #expect(button.hitTest(NSPoint(x: 12, y: 12)) === button)
  }

  @Test func lifecycleEventsUseHerdrWireNamesForImmediateRefresh() {
    for eventName in [
      "workspace_created", "workspace_closed", "workspace_metadata_updated", "worktree_created", "worktree_opened",
      "worktree_removed", "tab_created", "tab_closed", "pane_created", "pane_closed",
    ] {
      #expect(HerdrTerminalChromeFeature.shouldRefreshImmediately(for: eventName))
    }
    #expect(HerdrTerminalChromeFeature.shouldRefreshImmediately(for: "workspace.created"))
    #expect(!HerdrTerminalChromeFeature.shouldRefreshImmediately(for: "pane_updated"))
  }

  @Test(.dependencies) func lifecycleEventRefreshesEvenWhileFocusIsPending() async {
    let snapshotCalls = LockIsolated(0)
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connected
    initialState.snapshot = makeSnapshot(focusedPaneID: "p1")
    initialState.selectedWorkspaceID = "w1"
    initialState.selectedTabID = "t1"
    initialState.selectedPaneID = "p1"
    initialState.pendingFocus = .tab("t1")

    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.herdrTerminalChromeClient = HerdrTerminalChromeClient(
        snapshot: {
          snapshotCalls.withValue { $0 += 1 }
          return .empty
        },
        subscribeEvents: { _ in
          HerdrEventSubscription(stream: AsyncStream { $0.finish() }, cancel: {})
        },
        focusWorkspace: { _ in },
        focusTab: { _ in },
        focusPane: { _ in },
        createWorkspace: {},
        createTab: { _, _, _ in },
        renameTab: { _, _ in },
        moveTab: { _, _ in },
        closeTab: { _ in },
        closeWorkspace: { _ in }
      )
    }

    await store.send(.eventStream(.event(HerdrEventEnvelope(event: "tab_closed")))) {
      $0.refreshGeneration = 1
    }
    await store.receive(.refreshResponseWithGeneration(1, .success(.empty))) {
      $0.snapshot = .empty
      $0.selectedWorkspaceID = nil
      $0.selectedTabID = nil
      $0.selectedPaneID = nil
      $0.pendingFocus = nil
      $0.subscribedPaneIDs = []
    }
    #expect(snapshotCalls.value == 1)
  }

  @Test(.dependencies) func paneExitEventImmediatelyRemovesLastTabAndWorkspace() async {
    let snapshotCalls = LockIsolated(0)
    let clock = TestClock()
    let snapshot = makeSnapshot(focusedPaneID: "p1", includesSecondaryPane: false)
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connected
    initialState.snapshot = snapshot
    initialState.selectedWorkspaceID = "w1"
    initialState.selectedTabID = "t1"
    initialState.selectedPaneID = "p1"
    initialState.subscribedPaneIDs = ["p1"]
    let projectedSnapshot = HerdrTerminalChromeFeature.snapshotByRemovingPanes(
      initialState.snapshot,
      paneIDs: ["p1"]
    )
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.herdrTerminalChromeClient = HerdrTerminalChromeClient(
        snapshot: {
          snapshotCalls.withValue { $0 += 1 }
          return .empty
        },
        subscribeEvents: { _ in
          HerdrEventSubscription(stream: AsyncStream { $0.finish() }, cancel: {})
        },
        focusWorkspace: { _ in },
        focusTab: { _ in },
        focusPane: { _ in },
        createWorkspace: {},
        createTab: { _, _, _ in },
        renameTab: { _, _ in },
        moveTab: { _, _ in },
        closeTab: { _ in },
        closeWorkspace: { _ in }
      )
    }

    await store.send(
      .eventStream(
        .event(
          HerdrEventEnvelope(
            event: "pane.exited",
            focus: HerdrFocusEvent(workspaceID: "w1", tabID: "t1", paneID: "p1")
          )
        )
      )
    ) {
      $0.snapshot = projectedSnapshot
      $0.selectedWorkspaceID = nil
      $0.selectedTabID = nil
      $0.selectedPaneID = nil
      $0.pendingPaneExitIDs = ["p1"]
      $0.refreshGeneration = 1
    }
    await store.receive(.refreshResponseWithGeneration(1, .success(.empty))) {
      $0.snapshot = .empty
      $0.selectedWorkspaceID = nil
      $0.selectedTabID = nil
      $0.selectedPaneID = nil
      $0.pendingPaneExitIDs = []
      $0.subscribedPaneIDs = []
    }
    await store.receive(.subscriptionPrepared([])) {
      $0.subscriptionAwaitingSnapshot = true
    }
    await store.receive(.snapshotResponse(.success(.empty))) {
      $0.subscriptionAwaitingSnapshot = false
    }
    await store.send(.stop) {
      $0.connection = .hidden
      $0.refreshGeneration = 2
      $0.mutationGeneration = 1
    }
    #expect(snapshotCalls.value == 3)
  }
  @Test func stalePaneExitSnapshotDoesNotRestoreLastTab() async {
    let snapshot = makeSnapshot(focusedPaneID: "p1", includesSecondaryPane: false)
    let projectedSnapshot = HerdrTerminalChromeFeature.snapshotByRemovingPanes(
      snapshot,
      paneIDs: ["p1"]
    )
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connected
    initialState.snapshot = snapshot
    initialState.selectedWorkspaceID = "w1"
    initialState.selectedTabID = "t1"
    initialState.selectedPaneID = "p1"
    initialState.pendingPaneExitIDs = ["p1"]
    initialState.refreshGeneration = 1
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    }

    await store.send(.refreshResponseWithGeneration(1, .success(snapshot))) {
      $0.snapshot = projectedSnapshot
      $0.selectedWorkspaceID = nil
      $0.selectedTabID = nil
      $0.selectedPaneID = nil
      $0.pendingPaneExitIDs = ["p1"]
    }
  }

  @Test func tabMutationParamsUseHerdrWireNames() throws {
    let encoder = JSONEncoder()
    let create =
      try JSONSerialization.jsonObject(
        with: encoder.encode(
          HerdrTabCreateParams(workspaceID: "w1", focus: true, label: "logs")
        )
      ) as? [String: Any]
    let move =
      try JSONSerialization.jsonObject(
        with: encoder.encode(HerdrTabMoveParams(tabID: "w1:t1", insertIndex: 2))
      ) as? [String: Any]
    let rename =
      try JSONSerialization.jsonObject(
        with: encoder.encode(HerdrTabRenameParams(tabID: "w1:t1", label: "Backend"))
      ) as? [String: Any]
    let reset =
      try JSONSerialization.jsonObject(
        with: encoder.encode(HerdrTabRenameParams(tabID: "w1:t1", label: nil))
      ) as? [String: Any]
    let workspace =
      try JSONSerialization.jsonObject(
        with: encoder.encode(HerdrWorkspaceCreateParams(focus: true))
      ) as? [String: Any]

    #expect(create?["workspace_id"] as? String == "w1")
    #expect(create?["focus"] as? Bool == true)
    #expect(create?["label"] as? String == "logs")
    #expect(move?["tab_id"] as? String == "w1:t1")
    #expect(move?["insert_index"] as? Int == 2)
    #expect(rename?["tab_id"] as? String == "w1:t1")
    #expect(rename?["label"] as? String == "Backend")
    #expect(reset?["tab_id"] as? String == "w1:t1")
    #expect(reset?.keys.contains("label") == true)
    #expect(reset?["label"] is NSNull)
    #expect(workspace?["focus"] as? Bool == true)
  }

  @Test(arguments: [
    (nil, HerdrAgentStatusKind.unknown),
    ("unknown", HerdrAgentStatusKind.unknown),
    ("working", HerdrAgentStatusKind.working),
    ("blocked", HerdrAgentStatusKind.blocked),
    ("done", HerdrAgentStatusKind.done),
    ("idle", HerdrAgentStatusKind.idle),
  ])
  func mapsServerStatusToNativeMarker(
    status: String?,
    expected: HerdrAgentStatusKind
  ) {
    #expect(HerdrAgentStatusKind(status) == expected)
  }

  @Test func markerShapesPreserveUnreadSemantics() {
    #expect(HerdrAgentStatusKind.unknown.isSmall)
    #expect(HerdrAgentStatusKind.done.isFilled)
    #expect(!HerdrAgentStatusKind.idle.isFilled)
    #expect(HerdrAgentStatusKind.working.isFilled)
    #expect(HerdrAgentStatusKind.blocked.isFilled)
  }

  @Test func statusMarkersShareOneCenteredColumn() {
    #expect(HerdrSidebarLayout.statusMarkerColumnWidth == HerdrSidebarLayout.agentStatusMarkerSize)
  }

  @Test(arguments: [
    (HerdrAgentStatusKind.unknown, HerdrAgentStatusColor.secondary),
    (HerdrAgentStatusKind.working, HerdrAgentStatusColor.working),
    (HerdrAgentStatusKind.blocked, HerdrAgentStatusColor.blocked),
    (HerdrAgentStatusKind.done, HerdrAgentStatusColor.unread),
    (HerdrAgentStatusKind.idle, HerdrAgentStatusColor.idle),
  ])
  func markerColorsMatchHerdrStatusPalette(
    kind: HerdrAgentStatusKind,
    expected: HerdrAgentStatusColor
  ) {
    #expect(kind.markerColor == expected)
  }

  @Test func agentSortMatchesHerdrGroupedAndPriorityModes() {
    let agents = [
      HerdrAgent(paneID: "unknown", agentStatus: "unknown"),
      HerdrAgent(paneID: "done", agentStatus: "done"),
      HerdrAgent(paneID: "blocked", agentStatus: "blocked"),
    ]

    #expect(
      HerdrSidebarProjection.sortedAgents(agents, mode: .grouped).map(\.id)
        == ["unknown", "done", "blocked"])
    #expect(
      HerdrSidebarProjection.sortedAgents(agents, mode: .priority).map(\.id)
        == ["blocked", "done", "unknown"])
  }

  @Test func agentRowsReuseCanonicalAgentKindProjection() {
    #expect(
      HerdrSidebarProjection.agentKind(for: HerdrAgent(agent: "acp-omp")) == .omp
    )
    #expect(
      HerdrSidebarProjection.agentKind(for: HerdrAgent(agent: "pi")) == .pi
    )
  }

  @Test func agentContextUsesDirectoryAndRemovesRepeatedLabels() {
    let agent = HerdrAgent(
      agent: "omp",
      cwd: "/Users/yam/Developer/bb",
      foregroundCWD: "/Users/yam/Developer/bb"
    )

    #expect(
      HerdrSidebarProjection.contextLabel(for: agent, workspaceLabel: "bb", tabLabel: "bb") == "bb"
    )
    #expect(
      HerdrSidebarProjection.contextLabel(for: agent, workspaceLabel: "workspace", tabLabel: "tab")
        == "bb · workspace · tab"
    )
  }

  @Test func usesReadableNativeChromeTitleSizes() {
    #expect(HerdrChromeTypography.workspaceTitleFontSize == 15)
    #expect(HerdrChromeTypography.agentTitleFontSize == 14.5)
    #expect(HerdrChromeTypography.tabTitleFontSize == 14.5)
  }

  @Test func decodesAgentAndOrdinaryPanesFromSnapshot() throws {
    let response = try JSONDecoder().decode(
      HerdrSnapshotResponse.self,
      from: Data(
        #"""
        {
          "id": "snapshot",
          "result": {
            "type": "session_snapshot",
            "snapshot": {
              "version": "0.8.2",
              "protocol": 21,
              "focused_workspace_id": "w1",
              "focused_tab_id": "w1:t1",
              "focused_pane_id": "w1:p1",
              "workspaces": [{"workspace_id":"w1","number":1,"label":"Main","focused":true}],
              "tabs": [{"tab_id":"w1:t1","workspace_id":"w1","number":1,"label":"Shell","focused":true}],
              "panes": [
                {"pane_id":"w1:p1","terminal_id":"term-1","workspace_id":"w1","tab_id":"w1:t1","focused":true,"agent":"codex","agent_status":"working"},
                {"pane_id":"w1:p2","terminal_id":"term-2","workspace_id":"w1","tab_id":"w1:t1","focused":false,"foreground_cwd":"/tmp"}
              ],
              "layouts": [],
              "agents": []
            }
          }
        }
        """#.utf8
      )
    )

    #expect(response.type == "session_snapshot")
    #expect(response.snapshot.panes.first?.isAgent == true)
    #expect(response.snapshot.panes.dropFirst().first?.agent == nil)
    #expect(response.snapshot.panes.dropFirst().first?.foregroundCWD == "/tmp")
  }

  @Test func decodesOptionalWorkspaceBranch() throws {
    let workspace = try JSONDecoder().decode(
      HerdrWorkspace.self,
      from: Data(
        #"{"workspace_id":"w1","label":"Prowl","branch":"herdr-native-sidebar"}"#.utf8
      )
    )

    #expect(workspace.branch == "herdr-native-sidebar")
  }

  @Test func terminalChromeSubscriptionIncludesAgentLifecycleAndReorderEvents() throws {
    let data = try HerdrSocketClient.terminalChromeSubscriptionRequestData(paneIDs: ["p1"])
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let params = try #require(object["params"] as? [String: Any])
    let subscriptions = try #require(params["subscriptions"] as? [[String: Any]])
    let types = subscriptions.compactMap { $0["type"] as? String }

    #expect(types.contains("pane.agent_detected"))
    #expect(types.contains("workspace.reordered"))
    #expect(
      subscriptions.contains {
        $0["type"] as? String == "pane.agent_status_changed"
          && $0["pane_id"] as? String == "p1"
      }
    )
  }

  @Test func snapshotResponseConnectsSidebarAndUsesServerSelection() async {
    let snapshot = makeSnapshot(focusedPaneID: "p2")
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connecting
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    }

    await store.send(.snapshotResponse(.success(snapshot))) {
      $0.connection = .connected
      $0.snapshot = snapshot
      $0.selectedWorkspaceID = "w1"
      $0.selectedTabID = "t1"
      $0.selectedPaneID = "p2"
      $0.subscribedPaneIDs = ["p1", "p2"]
    }
  }

  @Test func externalSnapshotFocusReplacesStillLiveLocalSelection() async {
    let initialSnapshot = makeSnapshot(focusedPaneID: "p1")
    let externalFocusSnapshot = makeSnapshot(focusedPaneID: "p2")
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connected
    initialState.snapshot = initialSnapshot
    initialState.selectedWorkspaceID = "w1"
    initialState.selectedTabID = "t1"
    initialState.selectedPaneID = "p1"
    initialState.subscribedPaneIDs = ["p1", "p2"]
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    }

    await store.send(.refreshResponseWithGeneration(0, .success(externalFocusSnapshot))) {
      $0.snapshot = externalFocusSnapshot
      $0.selectedWorkspaceID = "w1"
      $0.selectedTabID = "t1"
      $0.selectedPaneID = "p2"
    }
  }

  @Test(.dependencies) func focusEventProjectsSelectionAndSchedulesSnapshotRefresh() async {
    let clock = TestClock()
    let snapshot = makeSnapshot(focusedPaneID: "p1")
    let refreshedSnapshot = makeSnapshot(focusedPaneID: "p2")
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connected
    initialState.snapshot = snapshot
    initialState.selectedWorkspaceID = "w1"
    initialState.selectedTabID = "t1"
    initialState.selectedPaneID = "p1"
    initialState.subscribedPaneIDs = ["p1", "p2"]
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.herdrTerminalChromeClient = testClient(snapshot: refreshedSnapshot)
    }

    await store.send(
      .eventStream(
        .event(
          HerdrEventEnvelope(
            event: "pane_focused",
            focus: HerdrFocusEvent(workspaceID: "w1", tabID: "t1", paneID: "p2")
          )
        )
      )
    ) {
      $0.selectedWorkspaceID = "w1"
      $0.selectedTabID = "t1"
      $0.selectedPaneID = "p2"
      $0.refreshGeneration = 1
    }
    await clock.advance(by: .milliseconds(100))
    await store.receive(.debouncedRefresh) {
      $0.refreshGeneration = 2
    }
    await store.receive(.refreshResponseWithGeneration(2, .success(refreshedSnapshot))) {
      $0.snapshot = refreshedSnapshot
    }
  }

  @Test(.dependencies) func localHerdrNavigationProjectsSelectionBeforeSnapshotRefresh() async {
    let clock = TestClock()
    let initialSnapshot = makeNavigationSnapshot(focusedTabID: "t1")
    let focusedSnapshot = makeNavigationSnapshot(focusedTabID: "t2")
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connected
    initialState.snapshot = initialSnapshot
    initialState.selectedWorkspaceID = "w1"
    initialState.selectedTabID = "t1"
    initialState.selectedPaneID = "p1"
    initialState.subscribedPaneIDs = ["p1", "p2"]
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.herdrTerminalChromeClient = testClient(snapshot: focusedSnapshot)
    }

    await store.send(.herdrNavigationKeyPressed(.nextTab)) {
      $0.selectedTabID = "t2"
      $0.selectedPaneID = "p2"
      $0.refreshGeneration = 1
    }
    await clock.advance(by: .milliseconds(500))
    await store.receive(.debouncedRefresh) {
      $0.refreshGeneration = 2
    }
    await store.receive(.refreshResponseWithGeneration(2, .success(focusedSnapshot))) {
      $0.snapshot = focusedSnapshot
    }
  }

  @Test(.dependencies) func localHerdrWorkspaceNavigationProjectsSelectionImmediately() async {
    let clock = TestClock()
    let initialSnapshot = makeWorkspaceNavigationSnapshot(focusedWorkspaceID: "w1")
    let focusedSnapshot = makeWorkspaceNavigationSnapshot(focusedWorkspaceID: "w2")
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connected
    initialState.snapshot = initialSnapshot
    initialState.selectedWorkspaceID = "w1"
    initialState.selectedTabID = "t1"
    initialState.selectedPaneID = "p1"
    initialState.subscribedPaneIDs = ["p1", "p2"]
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.herdrTerminalChromeClient = testClient(snapshot: focusedSnapshot)
    }

    await store.send(.herdrNavigationKeyPressed(.nextWorkspace)) {
      $0.selectedWorkspaceID = "w2"
      $0.selectedTabID = "t2"
      $0.selectedPaneID = "p2"
      $0.refreshGeneration = 1
    }
    await clock.advance(by: .milliseconds(500))
    await store.receive(.debouncedRefresh) {
      $0.refreshGeneration = 2
    }
    await store.receive(.refreshResponseWithGeneration(2, .success(focusedSnapshot))) {
      $0.snapshot = focusedSnapshot
    }
  }

  @Test(.dependencies) func localHerdrNavigationSchedulesSnapshotRefresh() async {
    let clock = TestClock()
    let initialSnapshot = makeSnapshot(focusedPaneID: "p1")
    let focusedSnapshot = makeSnapshot(focusedPaneID: "p2")
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connected
    initialState.snapshot = initialSnapshot
    initialState.selectedWorkspaceID = "w1"
    initialState.selectedTabID = "t1"
    initialState.selectedPaneID = "p1"
    initialState.subscribedPaneIDs = ["p1", "p2"]
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.herdrTerminalChromeClient = testClient(snapshot: focusedSnapshot)
    }

    await store.send(.herdrNavigationKeyPressed(.nextTab)) {
      $0.refreshGeneration = 1
    }
    await clock.advance(by: .milliseconds(500))
    await store.receive(.debouncedRefresh) {
      $0.refreshGeneration = 2
    }
    await store.receive(.refreshResponseWithGeneration(2, .success(focusedSnapshot))) {
      $0.snapshot = focusedSnapshot
      $0.selectedPaneID = "p2"
    }
  }

  @Test(.dependencies) func focusEventInvalidatesInFlightSnapshotRefresh() async {
    let clock = TestClock()
    let initialSnapshot = makeSnapshot(focusedPaneID: "p1")
    let focusedSnapshot = makeSnapshot(focusedPaneID: "p2")
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connected
    initialState.snapshot = initialSnapshot
    initialState.selectedWorkspaceID = "w1"
    initialState.selectedTabID = "t1"
    initialState.selectedPaneID = "p1"
    initialState.refreshGeneration = 1
    initialState.subscribedPaneIDs = ["p1", "p2"]
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.herdrTerminalChromeClient = testClient(snapshot: focusedSnapshot)
    }

    await store.send(
      .eventStream(
        .event(
          HerdrEventEnvelope(
            event: "pane_focused",
            focus: HerdrFocusEvent(workspaceID: "w1", tabID: "t1", paneID: "p2")
          )
        )
      )
    ) {
      $0.selectedPaneID = "p2"
      $0.refreshGeneration = 2
    }
    await store.send(.refreshResponseWithGeneration(1, .success(focusedSnapshot)))
    await clock.advance(by: .milliseconds(100))
    await store.receive(.debouncedRefresh) {
      $0.refreshGeneration = 3
    }
    await store.receive(.refreshResponseWithGeneration(3, .success(focusedSnapshot))) {
      $0.snapshot = focusedSnapshot
    }
  }

  @Test(.dependencies) func paneFocusEventDerivesTabSelectionFromPaneSnapshot() async {
    let clock = TestClock()
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connected
    initialState.snapshot = HerdrSessionSnapshot(
      version: "0.8.2",
      protocolVersion: 21,
      focusedWorkspaceID: "w1",
      focusedTabID: "t1",
      focusedPaneID: "p1",
      workspaces: [HerdrWorkspace(workspaceID: "w1")],
      tabs: [
        HerdrTab(tabID: "t1", workspaceID: "w1", label: "one"),
        HerdrTab(tabID: "t2", workspaceID: "w1", label: "two"),
      ],
      panes: [
        HerdrPane(paneID: "p1", workspaceID: "w1", tabID: "t1"),
        HerdrPane(paneID: "p2", workspaceID: "w1", tabID: "t2"),
      ],
      layouts: [],
      agents: []
    )
    initialState.selectedWorkspaceID = "w1"
    initialState.selectedTabID = "t1"
    initialState.selectedPaneID = "p1"
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }

    await store.send(
      .eventStream(
        .event(
          HerdrEventEnvelope(
            event: "pane_focused",
            focus: HerdrFocusEvent(workspaceID: "w1", paneID: "p2")
          )
        )
      )
    ) {
      $0.selectedWorkspaceID = "w1"
      $0.selectedTabID = "t2"
      $0.selectedPaneID = "p2"
      $0.refreshGeneration = 1
    }
    await store.send(.stop) {
      $0.connection = .hidden
      $0.snapshot = .empty
      $0.selectedWorkspaceID = nil
      $0.selectedTabID = nil
      $0.selectedPaneID = nil
      $0.refreshGeneration = 2
      $0.mutationGeneration = 1
    }
  }

  @Test(.dependencies) func focusUsesOptimisticSelectionAndEventConfirmationSchedulesSnapshotRefresh() async {
    let calls = LockIsolated<[String]>([])
    let snapshotCalls = LockIsolated(0)
    let focusedSnapshot = makeSnapshot(focusedPaneID: "p2")
    let clock = TestClock()
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connected
    initialState.snapshot = makeSnapshot(focusedPaneID: "p1")
    initialState.selectedWorkspaceID = "w1"
    initialState.selectedTabID = "t1"
    initialState.selectedPaneID = "p1"
    initialState.subscribedPaneIDs = ["p1", "p2"]

    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.herdrTerminalChromeClient = HerdrTerminalChromeClient(
        snapshot: {
          snapshotCalls.withValue { $0 += 1 }
          return focusedSnapshot
        },
        subscribeEvents: { _ in
          HerdrEventSubscription(stream: AsyncStream { $0.finish() }, cancel: {})
        },
        focusWorkspace: { _ in },
        focusTab: { _ in },
        focusPane: { paneID in
          calls.withValue { $0.append(paneID) }
        },
        createTab: { _, _, _ in },
        renameTab: { _, _ in },
        moveTab: { _, _ in },
        closeTab: { _ in },
        closeWorkspace: { _ in }
      )
    }

    await store.send(.focusPaneTapped("p2")) {
      $0.pendingFocus = .pane("p2")
      $0.focusRollback = HerdrTerminalChromeFeature.FocusSelection(
        workspaceID: "w1", tabID: "t1", paneID: "p1")
      $0.selectedPaneID = "p2"
    }
    await store.receive(.focusResponse(.success))
    await store.send(
      .eventStream(
        .event(
          HerdrEventEnvelope(
            event: "pane_focused",
            focus: HerdrFocusEvent(workspaceID: "w1", tabID: "t1", paneID: "p2")
          )
        )
      )
    ) {
      $0.pendingFocus = nil
      $0.focusRollback = nil
      $0.refreshGeneration = 1
    }
    await clock.advance(by: .milliseconds(100))
    await store.receive(.debouncedRefresh) {
      $0.refreshGeneration = 2
    }
    await store.receive(.refreshResponseWithGeneration(2, .success(focusedSnapshot))) {
      $0.snapshot = focusedSnapshot
    }
    #expect(calls.value == ["p2"])
    #expect(snapshotCalls.value == 1)
  }

  @Test(.dependencies) func failedOptimisticFocusRollsBackSelection() async {
    let snapshot = makeSnapshot(focusedPaneID: "p1")
    let clock = TestClock()
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connected
    initialState.snapshot = snapshot
    initialState.selectedWorkspaceID = "w1"
    initialState.selectedTabID = "t1"
    initialState.selectedPaneID = "p1"
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.herdrTerminalChromeClient = HerdrTerminalChromeClient(
        snapshot: { snapshot },
        subscribeEvents: { _ in
          HerdrEventSubscription(stream: AsyncStream { $0.finish() }, cancel: {})
        },
        focusWorkspace: { _ in },
        focusTab: { _ in },
        focusPane: { _ in
          throw HerdrSocketError.serverError(code: "busy", message: "busy")
        },
        createTab: { _, _, _ in },
        renameTab: { _, _ in },
        moveTab: { _, _ in },
        closeTab: { _ in },
        closeWorkspace: { _ in }
      )
    }

    await store.send(.focusPaneTapped("p2")) {
      $0.pendingFocus = .pane("p2")
      $0.focusRollback = HerdrTerminalChromeFeature.FocusSelection(
        workspaceID: "w1", tabID: "t1", paneID: "p1")
      $0.selectedPaneID = "p2"
    }
    await store.receive(.focusResponse(.failure(.server(code: "busy", message: "busy")))) {
      $0.pendingFocus = nil
      $0.focusRollback = nil
      $0.selectedPaneID = "p1"
    }
  }

  @Test(.dependencies) func optimisticFocusFallsBackToSnapshotAfterEventTimeout() async {
    let clock = TestClock()
    let focusedSnapshot = makeSnapshot(focusedPaneID: "p2")
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connected
    initialState.snapshot = makeSnapshot(focusedPaneID: "p1")
    initialState.selectedWorkspaceID = "w1"
    initialState.selectedTabID = "t1"
    initialState.selectedPaneID = "p1"
    initialState.subscribedPaneIDs = ["p1", "p2"]
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.herdrTerminalChromeClient = HerdrTerminalChromeClient(
        snapshot: { focusedSnapshot },
        subscribeEvents: { _ in
          HerdrEventSubscription(stream: AsyncStream { $0.finish() }, cancel: {})
        },
        focusWorkspace: { _ in },
        focusTab: { _ in },
        focusPane: { _ in },
        createTab: { _, _, _ in },
        renameTab: { _, _ in },
        moveTab: { _, _ in },
        closeTab: { _ in },
        closeWorkspace: { _ in }
      )
    }

    await store.send(.focusPaneTapped("p2")) {
      $0.pendingFocus = .pane("p2")
      $0.focusRollback = HerdrTerminalChromeFeature.FocusSelection(
        workspaceID: "w1", tabID: "t1", paneID: "p1")
      $0.selectedPaneID = "p2"
    }
    await store.receive(.focusResponse(.success))
    await clock.advance(by: .milliseconds(250))
    await store.receive(.focusConfirmationTimedOut(.pane("p2"))) {
      $0.refreshGeneration = 1
      $0.pendingFocus = nil
      $0.focusRollback = nil
    }
    await store.receive(.refreshResponseWithGeneration(1, .success(focusedSnapshot))) {
      $0.snapshot = focusedSnapshot
      $0.selectedPaneID = "p2"
    }
  }

  @Test func intermediateFocusEventDoesNotOverrideOptimisticPaneSelection() async {
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connected
    initialState.snapshot = makeSnapshot(focusedPaneID: "p1")
    initialState.selectedWorkspaceID = "w1"
    initialState.selectedTabID = "t1"
    initialState.selectedPaneID = "p2"
    initialState.pendingFocus = .pane("p2")
    initialState.focusRollback = HerdrTerminalChromeFeature.FocusSelection(
      workspaceID: "w1", tabID: "t1", paneID: "p1")
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    }

    await store.send(
      .eventStream(
        .event(
          HerdrEventEnvelope(
            event: "workspace_focused",
            focus: HerdrFocusEvent(workspaceID: "w1")
          )
        )
      )
    )
  }

  @Test(.dependencies) func notFoundFocusFailureRefreshesConfirmedSelection() async {
    let calls = LockIsolated<[String]>([])
    let clock = TestClock()
    let snapshot = makeSnapshot(focusedPaneID: "p1")
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connected
    initialState.snapshot = snapshot
    initialState.selectedPaneID = "p1"
    initialState.subscribedPaneIDs = ["p1", "p2"]
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.herdrTerminalChromeClient = HerdrTerminalChromeClient(
        snapshot: { snapshot },
        subscribeEvents: { _ in
          HerdrEventSubscription(stream: AsyncStream { $0.finish() }, cancel: {})
        },
        focusWorkspace: { _ in },
        focusTab: { _ in },
        focusPane: { paneID in
          calls.withValue { $0.append(paneID) }
          throw HerdrSocketError.serverError(code: "not_found", message: "pane not found")
        },
        createTab: { _, _, _ in },
        renameTab: { _, _ in },
        moveTab: { _, _ in },
        closeTab: { _ in },
        closeWorkspace: { _ in }
      )
    }

    await store.send(.focusPaneTapped("p2")) {
      $0.pendingFocus = .pane("p2")
      $0.focusRollback = HerdrTerminalChromeFeature.FocusSelection(
        workspaceID: nil, tabID: nil, paneID: "p1")
      $0.selectedWorkspaceID = "w1"
      $0.selectedTabID = "t1"
      $0.selectedPaneID = "p2"
    }
    await store.receive(
      .focusResponse(
        .failure(.server(code: "not_found", message: "pane not found"))
      )
    ) {
      $0.refreshGeneration = 1
      $0.pendingFocus = nil
      $0.focusRollback = nil
      $0.selectedWorkspaceID = nil
      $0.selectedTabID = nil
      $0.selectedPaneID = "p1"
    }
    await store.receive(.refreshResponseWithGeneration(1, .success(snapshot))) {
      $0.selectedWorkspaceID = "w1"
      $0.selectedTabID = "t1"
    }
    #expect(calls.value == ["p2"])
  }

  @Test(.dependencies) func createTabMutationRefreshesAfterServerSuccess() async {
    let calls = LockIsolated<[String]>([])
    let clock = TestClock()
    let snapshot = makeSnapshot(focusedPaneID: "p1")
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connected
    initialState.snapshot = snapshot
    initialState.selectedWorkspaceID = "w1"
    initialState.selectedTabID = "t1"
    initialState.selectedPaneID = "p1"
    initialState.subscribedPaneIDs = ["p1", "p2"]
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.herdrTerminalChromeClient = testClient(snapshot: snapshot) {
        calls.withValue { $0.append("create:w1:logs") }
      }
    }

    await store.send(
      .newTabRequested(workspaceID: "w1", label: "logs", sourceTabID: nil)
    ) {
      $0.pendingMutation = .createTab(
        workspaceID: "w1",
        label: "logs",
        sourceTabID: nil
      )
      $0.mutationGeneration = 1
    }
    await store.receive(.mutationResponse(1, .success)) {
      $0.refreshGeneration = 1
      $0.pendingMutation = nil
    }
    await store.receive(.refreshResponseWithGeneration(1, .success(snapshot)))
    #expect(calls.value == ["create:w1:logs"])
  }

  @Test(.dependencies) func resetTabNameSendsNullableRenameAndRefreshes() async {
    let labels = LockIsolated<[String?]>([])
    let clock = TestClock()
    let snapshot = makeSnapshot(focusedPaneID: "p1")
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connected
    initialState.snapshot = snapshot
    initialState.selectedWorkspaceID = "w1"
    initialState.selectedTabID = "t1"
    initialState.selectedPaneID = "p1"
    initialState.subscribedPaneIDs = ["p1", "p2"]
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.herdrTerminalChromeClient = HerdrTerminalChromeClient(
        snapshot: { snapshot },
        subscribeEvents: { _ in
          HerdrEventSubscription(stream: AsyncStream { $0.finish() }, cancel: {})
        },
        focusWorkspace: { _ in },
        focusTab: { _ in },
        focusPane: { _ in },
        createTab: { _, _, _ in },
        renameTab: { _, label in labels.withValue { $0.append(label) } },
        moveTab: { _, _ in },
        closeTab: { _ in },
        closeWorkspace: { _ in }
      )
    }

    await store.send(.resetTabNameRequested("t1")) {
      $0.pendingMutation = .renameTab(tabID: "t1", label: nil)
      $0.mutationGeneration = 1
    }
    await store.receive(.mutationResponse(1, .success)) {
      $0.pendingMutation = nil
      $0.refreshGeneration = 1
    }
    await clock.advance(by: .milliseconds(100))
    await store.receive(.debouncedRefresh) {
      $0.refreshGeneration = 2
    }
    await store.receive(.refreshResponseWithGeneration(2, .success(snapshot)))
    #expect(labels.value == [nil])
  }

  @Test(.dependencies) func newWorkspaceMutationUsesFocusedCreateRequest() async {
    let calls = LockIsolated<[String]>([])
    let clock = TestClock()
    let snapshot = makeSnapshot(focusedPaneID: "p1")
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connected
    initialState.snapshot = snapshot
    initialState.selectedWorkspaceID = "w1"
    initialState.selectedTabID = "t1"
    initialState.selectedPaneID = "p1"
    initialState.subscribedPaneIDs = ["p1", "p2"]
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.herdrTerminalChromeClient = testClient(
        snapshot: snapshot,
        createWorkspace: {
          calls.withValue { $0.append("create-workspace") }
        }
      )
    }

    await store.send(.newWorkspaceRequested) {
      $0.pendingMutation = .createWorkspace
      $0.mutationGeneration = 1
    }
    await store.receive(.mutationResponse(1, .success)) {
      $0.refreshGeneration = 1
      $0.pendingMutation = nil
    }
    await store.receive(.refreshResponseWithGeneration(1, .success(snapshot)))
    #expect(calls.value == ["create-workspace"])
  }

  @Test(.dependencies) func lastTabConfirmationClosesWorkspaceOnlyAfterConfirm() async {
    let calls = LockIsolated<[String]>([])
    let clock = TestClock()
    let (closeWorkspaceStream, closeWorkspaceContinuation) = AsyncStream.makeStream(of: Void.self)
    let snapshot = makeSnapshot(focusedPaneID: "p1")
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connected
    initialState.snapshot = snapshot
    initialState.selectedWorkspaceID = "w1"
    initialState.selectedTabID = "t1"
    initialState.selectedPaneID = "p1"
    initialState.subscribedPaneIDs = ["p1", "p2"]
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.herdrTerminalChromeClient = testClient(
        snapshot: snapshot,
        closeTab: {
          calls.withValue { $0.append("close-tab") }
          throw HerdrSocketError.serverError(
            code: "confirmation_required",
            message: "closing this tab would close a worktree group"
          )
        },
        closeWorkspace: {
          calls.withValue { $0.append("close-workspace:w1") }
          for await _ in closeWorkspaceStream {
            break
          }
        }
      )
    }

    await store.send(.closeTabRequested(tabID: "w1:t1", workspaceID: "w1")) {
      $0.pendingMutation = .closeTab(tabID: "w1:t1", workspaceID: "w1", isLastTab: true)
      $0.mutationGeneration = 1
    }
    await store.receive(
      .mutationResponse(
        1,
        .failure(
          .server(
            code: "confirmation_required",
            message: "closing this tab would close a worktree group"
          )
        )
      )
    ) {
      $0.pendingMutation = nil
      $0.closeConfirmation = .init(workspaceID: "w1")
    }
    await store.send(.closeConfirmationConfirmed) {
      $0.closeConfirmation = nil
      $0.pendingMutation = .closeWorkspace(workspaceID: "w1")
      $0.mutationGeneration = 2
    }
    closeWorkspaceContinuation.yield(())
    await store.receive(.mutationResponse(2, .success)) {
      $0.refreshGeneration = 1
      $0.pendingMutation = nil
    }
    await store.receive(.refreshResponseWithGeneration(1, .success(snapshot)))
    closeWorkspaceContinuation.finish()
    #expect(calls.value == ["close-tab", "close-workspace:w1"])
  }

  private func testClient(
    snapshot: HerdrSessionSnapshot,
    createTab: @escaping @Sendable () async throws -> Void = {},
    createWorkspace: @escaping @Sendable () async throws -> Void = {},
    closeTab: @escaping @Sendable () async throws -> Void = {},
    closeWorkspace: @escaping @Sendable () async throws -> Void = {}
  ) -> HerdrTerminalChromeClient {
    HerdrTerminalChromeClient(
      snapshot: { snapshot },
      subscribeEvents: { _ in
        HerdrEventSubscription(stream: AsyncStream { $0.finish() }, cancel: {})
      },
      focusWorkspace: { _ in },
      focusTab: { _ in },
      focusPane: { _ in },
      createWorkspace: { try await createWorkspace() },
      createTab: { _, _, _ in try await createTab() },
      renameTab: { _, _ in },
      moveTab: { _, _ in },
      closeTab: { _ in try await closeTab() },
      closeWorkspace: { _ in try await closeWorkspace() }
    )
  }

  private func makeWorkspaceNavigationSnapshot(focusedWorkspaceID: String) -> HerdrSessionSnapshot {
    HerdrSessionSnapshot(
      version: "0.9.0",
      protocolVersion: 22,
      focusedWorkspaceID: focusedWorkspaceID,
      focusedTabID: focusedWorkspaceID == "w1" ? "t1" : "t2",
      focusedPaneID: focusedWorkspaceID == "w1" ? "p1" : "p2",
      workspaces: [
        HerdrWorkspace(
          workspaceID: "w1",
          label: "Main",
          focused: focusedWorkspaceID == "w1",
          activeTabID: "t1"
        ),
        HerdrWorkspace(
          workspaceID: "w2",
          label: "Second",
          focused: focusedWorkspaceID == "w2",
          activeTabID: "t2"
        ),
      ],
      tabs: [
        HerdrTab(
          tabID: "t1", workspaceID: "w1", label: "Shell", focused: focusedWorkspaceID == "w1"),
        HerdrTab(
          tabID: "t2", workspaceID: "w2", label: "Logs", focused: focusedWorkspaceID == "w2"),
      ],
      panes: [
        HerdrPane(paneID: "p1", workspaceID: "w1", tabID: "t1"),
        HerdrPane(paneID: "p2", workspaceID: "w2", tabID: "t2"),
      ],
      layouts: [],
      agents: []
    )
  }

  private func makeNavigationSnapshot(focusedTabID: String) -> HerdrSessionSnapshot {
    HerdrSessionSnapshot(
      version: "0.9.0",
      protocolVersion: 22,
      focusedWorkspaceID: "w1",
      focusedTabID: focusedTabID,
      focusedPaneID: focusedTabID == "t1" ? "p1" : "p2",
      workspaces: [
        HerdrWorkspace(
          workspaceID: "w1",
          label: "Main",
          focused: true,
          activeTabID: focusedTabID
        )
      ],
      tabs: [
        HerdrTab(tabID: "t1", workspaceID: "w1", label: "Shell", focused: focusedTabID == "t1"),
        HerdrTab(tabID: "t2", workspaceID: "w1", label: "Logs", focused: focusedTabID == "t2"),
      ],
      panes: [
        HerdrPane(paneID: "p1", workspaceID: "w1", tabID: "t1"),
        HerdrPane(paneID: "p2", workspaceID: "w1", tabID: "t2"),
      ],
      layouts: [],
      agents: []
    )
  }

  private func makeSnapshot(
    focusedPaneID: String,
    includesSecondaryPane: Bool = true
  ) -> HerdrSessionSnapshot {
    var panes = [HerdrPane(paneID: "p1", workspaceID: "w1", tabID: "t1", agent: "codex")]
    if includesSecondaryPane {
      panes.append(HerdrPane(paneID: "p2", workspaceID: "w1", tabID: "t1", foregroundCWD: "/tmp"))
    }
    return HerdrSessionSnapshot(
      version: "0.8.2",
      protocolVersion: 21,
      focusedWorkspaceID: "w1",
      focusedTabID: "t1",
      focusedPaneID: focusedPaneID,
      workspaces: [HerdrWorkspace(workspaceID: "w1", label: "Main", focused: true)],
      tabs: [HerdrTab(tabID: "t1", workspaceID: "w1", label: "Shell", focused: true)],
      panes: panes,
      layouts: [],
      agents: []
    )
  }
}
