import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

@Suite(.serialized)
@MainActor
struct HerdrSidebarTests {
  @Test(arguments: [
    (nil, HerdrSidebarStatusKind.unknown),
    ("unknown", HerdrSidebarStatusKind.unknown),
    ("working", HerdrSidebarStatusKind.working),
    ("blocked", HerdrSidebarStatusKind.blocked),
    ("done", HerdrSidebarStatusKind.done),
    ("idle", HerdrSidebarStatusKind.idle),
  ])
  func mapsServerStatusToNativeMarker(
    status: String?,
    expected: HerdrSidebarStatusKind
  ) {
    #expect(HerdrSidebarStatusKind(status) == expected)
  }

  @Test func markerShapesPreserveUnreadSemantics() {
    #expect(HerdrSidebarStatusKind.unknown.isSmall)
    #expect(HerdrSidebarStatusKind.done.isFilled)
    #expect(!HerdrSidebarStatusKind.idle.isFilled)
    #expect(HerdrSidebarStatusKind.working.isFilled)
    #expect(HerdrSidebarStatusKind.blocked.isFilled)
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
              "protocol": 20,
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

  @Test func sidebarSubscriptionIncludesAgentLifecycleAndReorderEvents() throws {
    let data = try HerdrSocketClient.sidebarSubscriptionRequestData(paneIDs: ["p1"])
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
    var initialState = HerdrSidebarFeature.State()
    initialState.connection = .connecting
    let store = TestStore(initialState: initialState) {
      HerdrSidebarFeature()
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
    var initialState = HerdrSidebarFeature.State()
    initialState.connection = .connected
    initialState.snapshot = initialSnapshot
    initialState.selectedWorkspaceID = "w1"
    initialState.selectedTabID = "t1"
    initialState.selectedPaneID = "p1"
    initialState.subscribedPaneIDs = ["p1", "p2"]
    let store = TestStore(initialState: initialState) {
      HerdrSidebarFeature()
    }

    await store.send(.refreshResponseWithGeneration(0, .success(externalFocusSnapshot))) {
      $0.snapshot = externalFocusSnapshot
      $0.selectedWorkspaceID = "w1"
      $0.selectedTabID = "t1"
      $0.selectedPaneID = "p2"
    }
  }

  @Test(.dependencies) func focusRefreshConfirmsServerFocusedPane() async {
    let calls = LockIsolated<[String]>([])
    let focusedSnapshot = makeSnapshot(focusedPaneID: "p2")
    var initialState = HerdrSidebarFeature.State()
    initialState.connection = .connected
    initialState.snapshot = makeSnapshot(focusedPaneID: "p1")
    initialState.selectedPaneID = "p1"
    initialState.subscribedPaneIDs = ["p1", "p2"]

    let store = TestStore(initialState: initialState) {
      HerdrSidebarFeature()
    } withDependencies: {
      $0.herdrSidebarClient = HerdrSidebarClient(
        snapshot: { focusedSnapshot },
        events: { _ in AsyncStream { $0.finish() } },
        focusWorkspace: { _ in },
        focusTab: { _ in },
        focusPane: { paneID in
          calls.withValue { $0.append(paneID) }
        }
      )
    }

    await store.send(.focusPaneTapped("p2")) {
      $0.pendingFocus = .pane("p2")
    }
    await store.receive(.focusResponse(.success))
    await store.receive(.refreshResponseWithGeneration(0, .success(focusedSnapshot))) {
      $0.snapshot = focusedSnapshot
      $0.selectedWorkspaceID = "w1"
      $0.selectedTabID = "t1"
      $0.selectedPaneID = "p2"
      $0.pendingFocus = nil
    }
    #expect(calls.value == ["p2"])
  }

  @Test(.dependencies) func notFoundFocusFailureRefreshesConfirmedSelection() async {
    let calls = LockIsolated<[String]>([])
    let snapshot = makeSnapshot(focusedPaneID: "p1")
    var initialState = HerdrSidebarFeature.State()
    initialState.connection = .connected
    initialState.snapshot = snapshot
    initialState.selectedPaneID = "p1"
    initialState.subscribedPaneIDs = ["p1", "p2"]
    let store = TestStore(initialState: initialState) {
      HerdrSidebarFeature()
    } withDependencies: {
      $0.herdrSidebarClient = HerdrSidebarClient(
        snapshot: { snapshot },
        events: { _ in AsyncStream { $0.finish() } },
        focusWorkspace: { _ in },
        focusTab: { _ in },
        focusPane: { paneID in
          calls.withValue { $0.append(paneID) }
          throw HerdrSocketError.serverError(code: "not_found", message: "pane not found")
        }
      )
    }

    await store.send(.focusPaneTapped("p2")) {
      $0.pendingFocus = .pane("p2")
    }
    await store.receive(
      .focusResponse(
        .failure(.server(code: "not_found", message: "pane not found"))
      )
    ) {
      $0.pendingFocus = nil
    }
    await store.receive(.refreshResponseWithGeneration(0, .success(snapshot))) {
      $0.selectedWorkspaceID = "w1"
      $0.selectedTabID = "t1"
    }
    #expect(calls.value == ["p2"])
  }

  private func makeSnapshot(focusedPaneID: String) -> HerdrSidebarSnapshot {
    HerdrSidebarSnapshot(
      version: "0.8.2",
      protocolVersion: 20,
      focusedWorkspaceID: "w1",
      focusedTabID: "t1",
      focusedPaneID: focusedPaneID,
      workspaces: [HerdrWorkspace(workspaceID: "w1", label: "Main", focused: true)],
      tabs: [HerdrTab(tabID: "t1", workspaceID: "w1", label: "Shell", focused: true)],
      panes: [
        HerdrPane(paneID: "p1", workspaceID: "w1", tabID: "t1", agent: "codex"),
        HerdrPane(paneID: "p2", workspaceID: "w1", tabID: "t1", foregroundCWD: "/tmp"),
      ],
      layouts: [],
      agents: []
    )
  }
}
