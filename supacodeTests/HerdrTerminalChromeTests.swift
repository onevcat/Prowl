import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

@Suite(.serialized)
@MainActor
struct HerdrTerminalChromeTests {
  @Test func tabMutationParamsUseHerdrWireNames() throws {
    let encoder = JSONEncoder()
    let create = try JSONSerialization.jsonObject(
      with: encoder.encode(
        HerdrTabCreateParams(workspaceID: "w1", focus: true, label: "logs")
      )
    ) as? [String: Any]
    let move = try JSONSerialization.jsonObject(
      with: encoder.encode(HerdrTabMoveParams(tabID: "w1:t1", insertIndex: 2))
    ) as? [String: Any]

    #expect(create?["workspace_id"] as? String == "w1")
    #expect(create?["focus"] as? Bool == true)
    #expect(create?["label"] as? String == "logs")
    #expect(move?["tab_id"] as? String == "w1:t1")
    #expect(move?["insert_index"] as? Int == 2)
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

  @Test(.dependencies) func focusRefreshConfirmsServerFocusedPane() async {
    let calls = LockIsolated<[String]>([])
    let focusedSnapshot = makeSnapshot(focusedPaneID: "p2")
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connected
    initialState.snapshot = makeSnapshot(focusedPaneID: "p1")
    initialState.selectedPaneID = "p1"
    initialState.subscribedPaneIDs = ["p1", "p2"]

    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.herdrTerminalChromeClient = HerdrTerminalChromeClient(
        snapshot: { focusedSnapshot },
        events: { _ in AsyncStream { $0.finish() } },
        focusWorkspace: { _ in },
        focusTab: { _ in },
        focusPane: { paneID in
          calls.withValue { $0.append(paneID) }
        },
        createTab: { _, _ in },
        renameTab: { _, _ in },
        moveTab: { _, _ in },
        closeTab: { _ in },
        closeWorkspace: { _ in }
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
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.connection = .connected
    initialState.snapshot = snapshot
    initialState.selectedPaneID = "p1"
    initialState.subscribedPaneIDs = ["p1", "p2"]
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.herdrTerminalChromeClient = HerdrTerminalChromeClient(
        snapshot: { snapshot },
        events: { _ in AsyncStream { $0.finish() } },
        focusWorkspace: { _ in },
        focusTab: { _ in },
        focusPane: { paneID in
          calls.withValue { $0.append(paneID) }
          throw HerdrSocketError.serverError(code: "not_found", message: "pane not found")
        },
        createTab: { _, _ in },
        renameTab: { _, _ in },
        moveTab: { _, _ in },
        closeTab: { _ in },
        closeWorkspace: { _ in }
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

    await store.send(.newTabRequested(workspaceID: "w1", label: "logs")) {
      $0.pendingMutation = .createTab(workspaceID: "w1", label: "logs")
      $0.mutationGeneration = 1
    }
    await store.receive(.mutationResponse(1, .success)) {
      $0.pendingMutation = nil
    }
    await store.receive(.refreshResponseWithGeneration(0, .success(snapshot)))
    #expect(calls.value == ["create:w1:logs"])
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
      $0.pendingMutation = nil
    }
    await store.receive(.refreshResponseWithGeneration(0, .success(snapshot)))
    closeWorkspaceContinuation.finish()
    #expect(calls.value == ["close-tab", "close-workspace:w1"])
  }

  private func testClient(
    snapshot: HerdrSessionSnapshot,
    createTab: @escaping @Sendable () async throws -> Void = {},
    closeTab: @escaping @Sendable () async throws -> Void = {},
    closeWorkspace: @escaping @Sendable () async throws -> Void = {}
  ) -> HerdrTerminalChromeClient {
    HerdrTerminalChromeClient(
      snapshot: { snapshot },
      events: { _ in AsyncStream { $0.finish() } },
      focusWorkspace: { _ in },
      focusTab: { _ in },
      focusPane: { _ in },
      createTab: { _, _ in try await createTab() },
      renameTab: { _, _ in },
      moveTab: { _, _ in },
      closeTab: { _ in try await closeTab() },
      closeWorkspace: { _ in try await closeWorkspace() }
    )
  }

  private func makeSnapshot(focusedPaneID: String) -> HerdrSessionSnapshot {
    HerdrSessionSnapshot(
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
