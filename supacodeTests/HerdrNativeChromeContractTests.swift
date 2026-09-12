import ComposableArchitecture
import Darwin
import DependenciesTestSupport
import Foundation
import Testing

@testable import supacode

@Suite(.serialized)
struct HerdrNativeChromeContractTests {
  @Test func decodesGoldenAggregateContractWithEndpointQualifiedDuplicateIDs() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appending(path: "Fixtures/herdr-native-chrome-v1.json")
    let data = try Data(contentsOf: fixtureURL)
    let envelope = try JSONDecoder().decode(
      HerdrNativeChromeEnvelope<HerdrNativeAggregatePayload>.self,
      from: data
    )

    #expect(envelope.contractVersion == 1)
    #expect(envelope.messageKind == "aggregate_sync_commit")
    #expect(envelope.payload.syncCommitted)
    #expect(envelope.payload.state.endpoints.count == 2)
    #expect(
      envelope.payload.state.endpoints.map(\.endpointKey) == [
        .local,
        .ssh(profileID: "0123456789abcdef0123456789abcdef"),
      ])
    #expect(envelope.payload.state.committedActiveEndpointKey == .local)
    let local = try #require(envelope.payload.state.endpoints.first)
    let remote = try #require(envelope.payload.state.endpoints.last)
    #expect(local.snapshot?.focusedPaneID == "pane-duplicate")
    #expect(remote.snapshot?.focusedPaneID == "pane-duplicate")
  }

  @Test func decodesRealSSHProfileAggregateOffMainActor() async throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appending(path: "Fixtures/herdr-native-chrome-v1.json")
    let data = try Data(contentsOf: fixtureURL)

    let endpointKeys = try await Task.detached {
      let envelope = try JSONDecoder().decode(
        HerdrNativeChromeEnvelope<HerdrNativeAggregatePayload>.self,
        from: data
      )
      return envelope.payload.state.endpoints.map(\.endpointKey)
    }.value

    #expect(
      endpointKeys == [
        .local,
        .ssh(profileID: "0123456789abcdef0123456789abcdef"),
      ])
  }

  @Test func malformedEndpointProjectionDoesNotEraseHealthyMachines() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appending(path: "Fixtures/herdr-native-chrome-v1.json")
    var object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
    )
    var payload = try #require(object["payload"] as? [String: Any])
    var state = try #require(payload["state"] as? [String: Any])
    var endpoints = try #require(state["endpoints"] as? [[String: Any]])
    var malformedEndpoint = try #require(endpoints.last)
    endpoints.removeLast()
    malformedEndpoint["status"] = 42
    endpoints.append(malformedEndpoint)
    state["endpoints"] = endpoints
    payload["state"] = state
    object["payload"] = payload

    let envelope = try JSONDecoder().decode(
      HerdrNativeChromeEnvelope<HerdrNativeAggregatePayload>.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    #expect(envelope.payload.state.endpoints.map(\.endpointKey) == [.local])
  }

  @Test func futureDisplayEnumValuesRemainVisibleButNonActionable() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appending(path: "Fixtures/herdr-native-chrome-v1.json")
    var object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
    )
    var payload = try #require(object["payload"] as? [String: Any])
    var state = try #require(payload["state"] as? [String: Any])
    var endpoints = try #require(state["endpoints"] as? [[String: Any]])
    var local = try #require(endpoints.first)
    endpoints.removeFirst()
    local["availability"] = "future_availability"
    local["status"] = "future_status"
    local["freshness"] = "future_freshness"
    endpoints.insert(local, at: 0)
    state["endpoints"] = endpoints
    payload["state"] = state
    object["payload"] = payload

    let envelope = try JSONDecoder().decode(
      HerdrNativeChromeEnvelope<HerdrNativeAggregatePayload>.self,
      from: JSONSerialization.data(withJSONObject: object)
    )
    let decodedLocal = try #require(envelope.payload.state.endpoints.first)
    #expect(decodedLocal.availability == .unknown)
    #expect(decodedLocal.status == .unknown)
    #expect(decodedLocal.freshness == .unknown)
    #expect(!decodedLocal.isActionable)
  }

  @Test func duplicateEndpointKeysRejectTheAggregateCoreWithoutTrapping() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appending(path: "Fixtures/herdr-native-chrome-v1.json")
    var object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
    )
    var payload = try #require(object["payload"] as? [String: Any])
    var state = try #require(payload["state"] as? [String: Any])
    var endpoints = try #require(state["endpoints"] as? [[String: Any]])
    endpoints.append(try #require(endpoints.first))
    state["endpoints"] = endpoints
    payload["state"] = state
    object["payload"] = payload

    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(
        HerdrNativeChromeEnvelope<HerdrNativeAggregatePayload>.self,
        from: JSONSerialization.data(withJSONObject: object)
      )
    }
  }

  @Test func aggregateProjectionKeepsCommittedSelectionDuringRemoteActivation() throws {
    let envelope = try goldenEnvelope()
    let remote = try #require(envelope.payload.state.endpoints.last)
    let requested = HerdrRequestedSelection(
      endpointKey: remote.endpointKey,
      selection: HerdrSelection(
        workspaceID: remote.snapshot?.focusedWorkspaceID,
        tabID: remote.snapshot?.focusedTabID,
        paneID: remote.snapshot?.focusedPaneID
      )
    )
    let state = HerdrAggregateState(
      catalogRevision: envelope.payload.state.catalogRevision,
      endpoints: envelope.payload.state.endpoints,
      perEndpointFocus: envelope.payload.state.perEndpointFocus,
      committedPresentation: envelope.payload.state.committedPresentation,
      requestedSelection: requested,
      pendingActivation: HerdrPendingActivation(
        epoch: 9,
        requestID: "prowl-native-focus-9",
        sourceEndpointKey: .local,
        targetEndpointKey: remote.endpointKey,
        phase: "activating_target"
      ),
      capabilities: envelope.payload.state.capabilities
    )
    let frame = HerdrNativeAggregateFrame(
      messageKind: "aggregate_state",
      sequence: 1,
      projectionRevision: 1,
      activationEpoch: 9,
      requestID: nil,
      mutationResult: nil,
      processInfoTarget: nil,
      processInfoFence: nil,
      processInfo: nil,
      state: state,
      syncCommitted: true
    )
    var reducerState = HerdrTerminalChromeFeature.State()
    reducerState.authorityMode = .aggregate
    reducerState.aggregateSyncCommitted = true
    reducerState.isForeground = true

    _ = HerdrTerminalChromeFeature().applyNativeFrame(&reducerState, frame: frame)

    #expect(reducerState.connection == .connected)
    #expect(reducerState.selectedWorkspaceID == "ws-local")
    #expect(reducerState.selectedTabID == "tab-duplicate")
    #expect(reducerState.selectedPaneID == "pane-duplicate")
    #expect(reducerState.activationEpoch == 9)
    #expect(reducerState.aggregateState?.requestedSelection?.endpointKey == remote.endpointKey)
  }

  @Test func initialAggregateStateRequiresAnExplicitSyncCommit() throws {
    let envelope = try goldenEnvelope()
    var reducerState = HerdrTerminalChromeFeature.State()
    reducerState.authorityMode = .aggregate
    reducerState.isForeground = true
    let stateFrame = HerdrNativeAggregateFrame(
      messageKind: "aggregate_state",
      sequence: 1,
      projectionRevision: 1,
      activationEpoch: nil,
      requestID: nil,
      mutationResult: nil,
      processInfoTarget: nil,
      processInfoFence: nil,
      processInfo: nil,
      state: envelope.payload.state,
      syncCommitted: true
    )

    _ = HerdrTerminalChromeFeature().applyNativeFrame(&reducerState, frame: stateFrame)

    #expect(!reducerState.aggregateSyncCommitted)
    #expect(reducerState.connection == .unavailable)
    let commitFrame = HerdrNativeAggregateFrame(
      messageKind: "aggregate_sync_commit",
      sequence: 2,
      projectionRevision: 2,
      activationEpoch: stateFrame.activationEpoch,
      requestID: stateFrame.requestID,
      mutationResult: stateFrame.mutationResult,
      processInfoTarget: stateFrame.processInfoTarget,
      processInfoFence: stateFrame.processInfoFence,
      processInfo: stateFrame.processInfo,
      state: stateFrame.state,
      syncCommitted: true
    )
    _ = HerdrTerminalChromeFeature().applyNativeFrame(&reducerState, frame: commitFrame)
    #expect(reducerState.aggregateSyncCommitted)
    #expect(reducerState.connection == .connected)
  }

  @Test func aggregateHandshakeTimeoutLocksModeToIncompatible() async {
    let clock = TestClock()
    let store = TestStore(initialState: HerdrTerminalChromeFeature.State()) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }

    await store.send(.nativeEvent(.aggregateStarted(clientInstanceID: "client"))) {
      $0.authorityMode = .aggregate
      $0.nativeClientInstanceID = "client"
      $0.connection = .connecting
    }
    await clock.advance(by: .seconds(1))
    await store.receive(.nativeHandshakeTimedOut(clientInstanceID: "client"))
    await store.receive(
      .nativeEvent(.incompatible("Aggregate sync did not commit within one second."))
    ) {
      $0.authorityMode = .incompatible
      $0.connection = .incompatible
      $0.mutationGeneration = 1
    }
  }

  @Test(.dependencies) func aggregateHandshakeTimeoutCancelsNativeLifecycle() async {
    let clock = TestClock()
    let terminated = LockIsolated(false)
    let (events, continuation) = AsyncStream.makeStream(of: HerdrNativeClientEvent.self)
    continuation.onTermination = { _ in terminated.setValue(true) }
    let store = TestStore(initialState: HerdrTerminalChromeFeature.State()) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
      var client = HerdrTerminalChromeClient.testValue
      client.nativeEvents = { events }
      $0.herdrTerminalChromeClient = client
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.foregroundChanged(true))
    continuation.yield(.aggregateStarted(clientInstanceID: "client"))
    await store.receive(.nativeEvent(.aggregateStarted(clientInstanceID: "client")))
    await clock.advance(by: .seconds(1))
    await store.receive(.nativeHandshakeTimedOut(clientInstanceID: "client"))
    await store.receive(
      .nativeEvent(.incompatible("Aggregate sync did not commit within one second."))
    )
    for _ in 0..<100 where !terminated.value {
      await Task.yield()
    }

    #expect(terminated.value)
    await store.send(.stop)
    await store.finish()
  }

  @Test func aggregateSuspendKeepsModeProjectionAndBindingLifecycle() async throws {
    let envelope = try goldenEnvelope()
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.authorityMode = .aggregate
    initialState.isForeground = true
    initialState.connection = .connected
    initialState.aggregateState = envelope.payload.state
    initialState.aggregateSyncCommitted = true
    initialState.snapshot =
      envelope.payload.state.committedEndpoint?.snapshot?.legacyProjection ?? .empty
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    }

    await store.send(.foregroundChanged(false)) {
      $0.isForeground = false
      $0.connection = .hidden
      $0.refreshGeneration = 1
      $0.mutationGeneration = 1
    }

    #expect(store.state.authorityMode == .aggregate)
    #expect(store.state.aggregateState == envelope.payload.state)
    #expect(store.state.aggregateSyncCommitted)
  }

  @Test func aggregateSequenceGapFreezesProjectionWithoutChangingAuthority() throws {
    let envelope = try goldenEnvelope()
    var reducerState = HerdrTerminalChromeFeature.State()
    reducerState.authorityMode = .aggregate
    reducerState.isForeground = true
    reducerState.nativeEventSequence = 2
    reducerState.nativeProjectionRevision = 2
    reducerState.pendingNativeMutationRequestID = "prowl-native-mutation-1"
    reducerState.pendingMutation = .renameTab(tabID: "tab-duplicate", label: "pending")
    reducerState.mutationError = .invalidResponse("old")
    reducerState.mutationGeneration = 7
    let frame = HerdrNativeAggregateFrame(
      messageKind: "aggregate_state",
      sequence: 4,
      projectionRevision: 3,
      activationEpoch: nil,
      requestID: nil,
      mutationResult: nil,
      processInfoTarget: nil,
      processInfoFence: nil,
      processInfo: nil,
      state: envelope.payload.state,
      syncCommitted: true
    )

    _ = HerdrTerminalChromeFeature().applyNativeFrame(&reducerState, frame: frame)

    #expect(reducerState.authorityMode == .aggregate)
    #expect(reducerState.connection == .unavailable)
    #expect(reducerState.isResyncPending)
    #expect(!reducerState.aggregateSyncCommitted)
    #expect(reducerState.snapshot == .empty)
    #expect(reducerState.pendingNativeMutationRequestID == nil)
    #expect(reducerState.pendingMutation == nil)
    #expect(reducerState.mutationError == nil)
    #expect(reducerState.mutationGeneration == 8)
  }

  @Test(.dependencies) func sequenceGapCancelsOldNativeMutationTimeout() async throws {
    let clock = TestClock()
    let sentRequests = LockIsolated<[HerdrNativeActionRequest]>([])
    let envelope = try goldenEnvelope()
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.authorityMode = .aggregate
    initialState.isForeground = true
    initialState.connection = .connected
    initialState.aggregateState = envelope.payload.state
    initialState.aggregateSyncCommitted = true
    initialState.nativeEventSequence = 1
    initialState.nativeProjectionRevision = 1
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
      var client = HerdrTerminalChromeClient.testValue
      client.sendNativeAction = { request in sentRequests.withValue { $0.append(request) } }
      $0.herdrTerminalChromeClient = client
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.renameTabRequested(tabID: "tab-duplicate", label: "pending"))
    let gapFrame = HerdrNativeAggregateFrame(
      messageKind: "aggregate_state",
      sequence: 3,
      projectionRevision: 2,
      activationEpoch: nil,
      requestID: nil,
      mutationResult: nil,
      processInfoTarget: nil,
      processInfoFence: nil,
      processInfo: nil,
      state: envelope.payload.state,
      syncCommitted: true
    )
    await store.send(.nativeEvent(.stream(.frame(gapFrame))))
    await clock.advance(by: .seconds(5))
    await store.send(.mutationResponse(1, .success))

    #expect(sentRequests.value.map(\.payload.action) == ["mutate", "resync"])
    #expect(store.state.pendingMutation == nil)
    #expect(store.state.pendingNativeMutationRequestID == nil)
    #expect(store.state.mutationError == nil)
    #expect(store.state.mutationGeneration == 2)
  }

  @Test func incompatibleNativeEventInvalidatesPendingMutation() async {
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.authorityMode = .aggregate
    initialState.isForeground = true
    initialState.connection = .connected
    initialState.pendingNativeMutationRequestID = "prowl-native-mutation-1"
    initialState.mutationError = .invalidResponse("old")
    initialState.closeConfirmation = .init(workspaceID: "workspace")
    initialState.mutationGeneration = 4
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    }

    await store.send(.nativeEvent(.incompatible("terminal"))) {
      $0.authorityMode = .incompatible
      $0.connection = .incompatible
      $0.pendingNativeMutationRequestID = nil
      $0.pendingMutation = nil
      $0.mutationError = nil
      $0.closeConfirmation = nil
      $0.mutationGeneration = 5
    }
    await store.send(.mutationResponse(4, .success))
    #expect(store.state.authorityMode == .incompatible)
    #expect(store.state.pendingMutation == nil)
    #expect(store.state.pendingNativeMutationRequestID == nil)
    #expect(store.state.mutationGeneration == 5)
  }

  private func goldenEnvelope() throws -> HerdrNativeChromeEnvelope<HerdrNativeAggregatePayload> {
    let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .appending(path: "Fixtures/herdr-native-chrome-v1.json")
    return try JSONDecoder().decode(
      HerdrNativeChromeEnvelope<HerdrNativeAggregatePayload>.self,
      from: Data(contentsOf: fixtureURL)
    )
  }

  @Test func processInfoResultUsesEndpointQualifiedIdentityAndFence() throws {
    let envelope = try goldenEnvelope()
    let remote = try #require(envelope.payload.state.endpoints.last)
    let identity =
      switch remote.connectionIdentity {
      case .concrete(let value): value
      case .absent: HerdrConnectionIdentity(generation: 0, serverBootID: "missing")
      }
    let snapshot = try #require(remote.snapshot)
    let target = HerdrPaneTarget(endpointKey: remote.endpointKey, paneID: "pane-duplicate")
    let fence = HerdrEndpointFence(
      endpointKey: remote.endpointKey,
      identity: identity,
      snapshotRevision: snapshot.revision
    )
    let info = HerdrPaneProcessInfo(
      paneID: "pane-duplicate",
      foregroundProcesses: [HerdrPaneProcess(pid: 42, name: "swift")]
    )
    let frame = HerdrNativeAggregateFrame(
      messageKind: "process_info_result",
      sequence: 1,
      projectionRevision: 1,
      activationEpoch: nil,
      requestID: "prowl-native-process-1",
      mutationResult: nil,
      processInfoTarget: target,
      processInfoFence: fence,
      processInfo: info,
      state: envelope.payload.state,
      syncCommitted: true
    )
    var reducerState = HerdrTerminalChromeFeature.State()
    reducerState.authorityMode = .aggregate
    reducerState.aggregateSyncCommitted = true
    reducerState.isForeground = true

    _ = HerdrTerminalChromeFeature().applyNativeFrame(&reducerState, frame: frame)

    #expect(reducerState.aggregateProcessInfoByPaneTarget[target] == info)
    #expect(
      reducerState.aggregateProcessInfoByPaneTarget[
        HerdrPaneTarget(endpointKey: .local, paneID: "pane-duplicate")
      ] == nil
    )

    let staleInfo = HerdrPaneProcessInfo(
      paneID: "pane-duplicate",
      foregroundProcesses: [HerdrPaneProcess(pid: 99, name: "stale")]
    )
    let staleFrame = HerdrNativeAggregateFrame(
      messageKind: "process_info_result",
      sequence: 2,
      projectionRevision: 2,
      activationEpoch: nil,
      requestID: "prowl-native-process-2",
      mutationResult: nil,
      processInfoTarget: target,
      processInfoFence: HerdrEndpointFence(
        endpointKey: remote.endpointKey,
        identity: identity,
        snapshotRevision: snapshot.revision &- 1
      ),
      processInfo: staleInfo,
      state: envelope.payload.state,
      syncCommitted: true
    )

    _ = HerdrTerminalChromeFeature().applyNativeFrame(&reducerState, frame: staleFrame)

    #expect(reducerState.aggregateProcessInfoByPaneTarget[target] == info)
  }

  @Test func staleMutationResultCannotCompleteANewerPendingRequest() async throws {
    let envelope = try goldenEnvelope()
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.authorityMode = .aggregate
    initialState.isForeground = true
    initialState.pendingMutation = .renameTab(tabID: "tab-duplicate", label: "Newest")
    initialState.pendingNativeMutationRequestID = "prowl-native-mutation-2"
    initialState.mutationGeneration = 2
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    let staleFrame = HerdrNativeAggregateFrame(
      messageKind: "mutation_result",
      sequence: 1,
      projectionRevision: 1,
      activationEpoch: nil,
      requestID: "prowl-native-mutation-1",
      mutationResult: HerdrNativeMutationResult(succeeded: true, message: nil),
      processInfoTarget: nil,
      processInfoFence: nil,
      processInfo: nil,
      state: envelope.payload.state,
      syncCommitted: false
    )

    await store.send(.nativeEvent(.stream(.frame(staleFrame))))

    #expect(store.state.pendingNativeMutationRequestID == "prowl-native-mutation-2")
    #expect(store.state.pendingMutation != nil)
  }

  @Test func mutationResultWithoutMatchingEndpointFenceCannotCompletePendingRequest() async throws {
    let envelope = try goldenEnvelope()
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.authorityMode = .aggregate
    initialState.isForeground = true
    initialState.connection = .connected
    initialState.aggregateState = envelope.payload.state
    initialState.aggregateSyncCommitted = true
    initialState.pendingMutation = .renameTab(tabID: "tab-duplicate", label: "pending")
    initialState.pendingNativeMutationRequestID = "prowl-native-mutation-1"
    initialState.pendingNativeMutationFence = HerdrEndpointFence(
      endpointKey: .local,
      identity: HerdrConnectionIdentity(generation: 1, serverBootID: "boot-local"),
      snapshotRevision: 8
    )
    initialState.mutationGeneration = 1
    let clock = TestClock()
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    let fences = [
      HerdrEndpointFence(
        endpointKey: .local,
        identity: HerdrConnectionIdentity(generation: 2, serverBootID: "boot-local"),
        snapshotRevision: 8
      ),
      HerdrEndpointFence(
        endpointKey: .local,
        identity: HerdrConnectionIdentity(generation: 1, serverBootID: "boot-old"),
        snapshotRevision: 8
      ),
      HerdrEndpointFence(
        endpointKey: .local,
        identity: HerdrConnectionIdentity(generation: 1, serverBootID: "boot-local"),
        snapshotRevision: 7
      ),
      HerdrEndpointFence(
        endpointKey: .ssh(profileID: "0123456789abcdef0123456789abcdef"),
        identity: HerdrConnectionIdentity(generation: 1, serverBootID: "boot-remote"),
        snapshotRevision: 8
      ),
    ]
    for (index, fence) in fences.enumerated() {
      let frame = HerdrNativeAggregateFrame(
        messageKind: "mutation_result",
        sequence: UInt64(index + 1),
        projectionRevision: UInt64(index + 1),
        activationEpoch: nil,
        requestID: "prowl-native-mutation-1",
        mutationResult: HerdrNativeMutationResult(
          succeeded: true,
          message: nil,
          endpointKey: fence.endpointKey,
          endpointFence: fence
        ),
        processInfoTarget: nil,
        processInfoFence: nil,
        processInfo: nil,
        state: envelope.payload.state,
        syncCommitted: true
      )
      await store.send(.nativeEvent(.stream(.frame(frame))))
    }

    #expect(store.state.pendingMutation != nil)
    #expect(store.state.pendingNativeMutationRequestID == "prowl-native-mutation-1")

    let matchingFence = try #require(initialState.pendingNativeMutationFence)
    let matchingFrame = HerdrNativeAggregateFrame(
      messageKind: "mutation_result",
      sequence: 5,
      projectionRevision: 5,
      activationEpoch: nil,
      requestID: "prowl-native-mutation-1",
      mutationResult: HerdrNativeMutationResult(
        succeeded: true,
        message: nil,
        endpointKey: matchingFence.endpointKey,
        endpointFence: matchingFence
      ),
      processInfoTarget: nil,
      processInfoFence: nil,
      processInfo: nil,
      state: envelope.payload.state,
      syncCommitted: true
    )
    await store.send(.nativeEvent(.stream(.frame(matchingFrame))))
    await store.receive(.mutationResponse(1, .success)) {
      $0.pendingMutation = nil
      $0.pendingNativeMutationRequestID = nil
      $0.pendingNativeMutationFence = nil
    }
  }
  @Test func nativeMutationTimesOutAndClearsPendingState() async throws {
    let clock = TestClock()
    let envelope = try goldenEnvelope()
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.authorityMode = .aggregate
    initialState.isForeground = true
    initialState.connection = .connected
    initialState.aggregateState = envelope.payload.state
    initialState.aggregateSyncCommitted = true
    initialState.snapshot =
      envelope.payload.state.committedEndpoint?.snapshot?.legacyProjection ?? .empty
    let requests = LockIsolated<[HerdrNativeActionRequest]>([])
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
      var client = HerdrTerminalChromeClient.testValue
      client.sendNativeAction = { request in requests.withValue { $0.append(request) } }
      $0.herdrTerminalChromeClient = client
    }

    await store.send(.renameTabRequested(tabID: "tab-duplicate", label: "Newest")) {
      $0.pendingMutation = .renameTab(tabID: "tab-duplicate", label: "Newest")
      $0.mutationGeneration = 1
      $0.nativeRequestSequence = 1
      $0.pendingNativeMutationRequestID = "prowl-native-mutation-1"
      $0.pendingNativeMutationFence = HerdrEndpointFence(
        endpointKey: .local,
        identity: HerdrConnectionIdentity(generation: 1, serverBootID: "boot-local"),
        snapshotRevision: 8
      )
    }
    await clock.advance(by: .seconds(5))
    await store.receive(
      .mutationResponse(
        1,
        .failure(.invalidResponse("Herdr mutation response timed out."))
      )
    ) {
      $0.pendingMutation = nil
      $0.pendingNativeMutationRequestID = nil
      $0.pendingNativeMutationFence = nil
      $0.mutationError = .invalidResponse("Herdr mutation response timed out.")
    }

    #expect(requests.value.map(\.requestID) == ["prowl-native-mutation-1"])
  }

  @Test func rejectsMissingNullableCoreEnvelopeField() {
    let json = """
      {"contract_version":1,"client_instance_id":"client","message_kind":"contract_ready",
      "event_sequence":null,"projection_revision":null,"request_id":null,"payload":{}}
      """
    let data = Data(json.utf8)
    #expect(throws: Error.self) {
      try HerdrNativeChromeRendezvous.validateCoreEnvelopeKeys(in: data)
    }
  }

  @Test func tabRenameKeepsV1ShapeAndUsesV2ToClear() {
    #expect(HerdrTabRenameMethod.method(for: "Build") == "tab.rename")
    #expect(HerdrTabRenameMethod.method(for: nil) == "tab.rename.v2")
  }

  @Test func rejectsInvalidSSHProfileIdentity() {
    let data = Data(#"{"kind":"ssh","profile_id":"Build Host"}"#.utf8)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(HerdrEndpointKey.self, from: data)
    }
  }

  @Test func coordinatorReplacementRetiresThePreviousSurfaceSocket() throws {
    let coordinator = HerdrNativeChromeCoordinator()
    let first = try coordinator.prepareSurface()
    #expect(FileManager.default.fileExists(atPath: first.socketPath))

    let second = try coordinator.prepareSurface()

    #expect(!FileManager.default.fileExists(atPath: first.socketPath))
    #expect(FileManager.default.fileExists(atPath: second.socketPath))
    coordinator.stopSurface()
    #expect(!FileManager.default.fileExists(atPath: second.socketPath))
  }

  private func nativeClaim(
    for rendezvous: HerdrNativeChromeRendezvous,
    challenge: String? = nil,
    startIdentity: HerdrNativeProcessStartIdentity? = nil
  ) -> HerdrNativeChromeEnvelope<HerdrNativeContractReady> {
    nativeClaim(
      for: rendezvous.binding,
      challenge: challenge,
      startIdentity: startIdentity
    )
  }

  private func nativeClaim(
    for binding: HerdrNativeChromeBinding,
    challenge: String? = nil,
    startIdentity: HerdrNativeProcessStartIdentity? = nil
  ) -> HerdrNativeChromeEnvelope<HerdrNativeContractReady> {
    HerdrNativeChromeEnvelope(
      contractVersion: HerdrNativeChromeRendezvous.contractVersion,
      clientInstanceID: binding.clientInstanceID,
      messageKind: "contract_ready",
      eventSequence: nil,
      projectionRevision: nil,
      requestID: nil,
      activationEpoch: nil,
      payload: HerdrNativeContractReady(
        surfaceProof: binding.surfaceProof,
        processID: getpid(),
        capabilities: HerdrNativeChromeCapabilities(
          required: HerdrNativeChromeRendezvous.requiredCapabilities,
          optional: []
        ),
        challenge: challenge ?? binding.challenge,
        userID: geteuid(),
        processGroupID: UInt32(getpgid(0)),
        foregroundProcessGroupID: currentProcessForegroundGroupID(),
        processStartIdentity: startIdentity ?? currentProcessStartIdentity(),
        ownerProcessID: getpid()
      )
    )
  }
  private func currentProcessStartIdentity() -> HerdrNativeProcessStartIdentity {
    var info = proc_bsdinfo()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      proc_pidinfo(
        getpid(),
        PROC_PIDTBSDINFO,
        0,
        pointer,
        Int32(MemoryLayout<proc_bsdinfo>.size)
      )
    }
    precondition(result == Int32(MemoryLayout<proc_bsdinfo>.size))
    return HerdrNativeProcessStartIdentity(
      seconds: info.pbi_start_tvsec,
      microseconds: info.pbi_start_tvusec
    )
  }
  private func currentProcessForegroundGroupID() -> UInt32 {
    var info = proc_bsdinfo()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      proc_pidinfo(
        getpid(),
        PROC_PIDTBSDINFO,
        0,
        pointer,
        Int32(MemoryLayout<proc_bsdinfo>.size)
      )
    }
    precondition(result == Int32(MemoryLayout<proc_bsdinfo>.size))
    return info.e_tpgid
  }
  private func connectUnixSocket(at path: String) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw posixError() }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in
      bytes.copyBytes(from: pathBytes)
      bytes[pathBytes.count] = 0
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else {
      let error = posixError()
      Darwin.close(descriptor)
      throw error
    }
    return descriptor
  }

  private func writeFrame(_ data: Data, to descriptor: Int32) throws {
    try writeFrameHeader(for: data, to: descriptor)
    try writeFrameBody(data, to: descriptor)
  }

  private func writeFrameHeader(for data: Data, to descriptor: Int32) throws {
    var length = UInt32(data.count).bigEndian
    try writeBytes(Data(bytes: &length, count: MemoryLayout<UInt32>.size), to: descriptor)
  }

  private func writeFrameBody(_ data: Data, to descriptor: Int32) throws {
    try writeBytes(data, to: descriptor)
  }

  private func writeBytes(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let written = Darwin.write(
          descriptor,
          bytes.baseAddress!.advanced(by: offset),
          bytes.count - offset
        )
        guard written > 0 else { throw posixError() }
        offset += written
      }
    }
  }

  private func socketPeerClosed(_ descriptor: Int32) -> Bool {
    var byte: UInt8 = 0
    let result = Darwin.recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
    return result == 0
  }

  private func posixError() -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }

  @Test func endpointWatermarkAdvancesOnlyForANewerRevisionOrIdentity() {
    var watermarks = HerdrEndpointWatermarks()
    let key = HerdrEndpointKey.local
    let first = HerdrEndpointFence(
      endpointKey: key,
      identity: HerdrConnectionIdentity(generation: 7, serverBootID: "boot-a"),
      snapshotRevision: 11
    )
    #expect(watermarks.accept(first) == .accepted)
    #expect(watermarks.accept(first) == .stale)
    #expect(
      watermarks.accept(
        HerdrEndpointFence(
          endpointKey: key,
          identity: first.identity,
          snapshotRevision: 12
        )
      ) == .accepted
    )
    #expect(
      watermarks.accept(
        HerdrEndpointFence(
          endpointKey: key,
          identity: HerdrConnectionIdentity(generation: 6, serverBootID: "unseen-old-boot"),
          snapshotRevision: 99
        )
      ) == .retiredConnection
    )
    #expect(
      watermarks.accept(
        HerdrEndpointFence(
          endpointKey: key,
          identity: HerdrConnectionIdentity(generation: 7, serverBootID: "wrong-boot"),
          snapshotRevision: 12
        )
      ) == .replacedConnection
    )
    #expect(
      watermarks.accept(
        HerdrEndpointFence(
          endpointKey: key,
          identity: HerdrConnectionIdentity(generation: 8, serverBootID: "boot-b"),
          snapshotRevision: 1
        )
      ) == .replacedConnection
    )
    #expect(watermarks.accept(first) == .retiredConnection)
  }

  @Test func duplicateAndLowerNativeSequencesAreIgnoredWithoutResync() throws {
    let envelope = try goldenEnvelope()
    var reducerState = HerdrTerminalChromeFeature.State()
    reducerState.authorityMode = .aggregate
    reducerState.isForeground = true
    reducerState.connection = .connected
    reducerState.aggregateState = envelope.payload.state
    reducerState.aggregateSyncCommitted = true
    reducerState.nativeEventSequence = 5
    reducerState.nativeProjectionRevision = 5
    reducerState.snapshot = try #require(envelope.payload.state.committedEndpoint?.snapshot)
      .legacyProjection
    let originalSnapshot = reducerState.snapshot

    for sequence in [UInt64(5), 4] {
      let frame = HerdrNativeAggregateFrame(
        messageKind: "aggregate_state",
        sequence: sequence,
        projectionRevision: 6,
        activationEpoch: nil,
        requestID: nil,
        mutationResult: nil,
        processInfoTarget: nil,
        processInfoFence: nil,
        processInfo: nil,
        state: envelope.payload.state,
        syncCommitted: true
      )

      _ = HerdrTerminalChromeFeature().applyNativeFrame(&reducerState, frame: frame)

      #expect(!reducerState.isResyncPending)
      #expect(reducerState.aggregateSyncCommitted)
      #expect(reducerState.connection == .connected)
      #expect(reducerState.nativeEventSequence == 5)
      #expect(reducerState.snapshot == originalSnapshot)
    }
  }

  @Test func sameGenerationNewBootReplacesIdentityAndRetiresOldBoot() {
    var watermarks = HerdrEndpointWatermarks()
    let old = HerdrEndpointFence(
      endpointKey: .local,
      identity: HerdrConnectionIdentity(generation: 7, serverBootID: "boot-a"),
      snapshotRevision: 11
    )
    let restarted = HerdrEndpointFence(
      endpointKey: .local,
      identity: HerdrConnectionIdentity(generation: 7, serverBootID: "boot-b"),
      snapshotRevision: 1
    )

    #expect(watermarks.accept(old) == .accepted)
    #expect(watermarks.accept(restarted) == .replacedConnection)
    #expect(watermarks.accept(old) == .retiredConnection)
  }

  @Test func endpointReplacementClearsOldProcessDecorationAndPendingMutation() async throws {
    let envelope = try goldenEnvelope()
    let previous = try #require(envelope.payload.state.endpoints.first)
    let oldSnapshot = try #require(previous.snapshot)
    let oldIdentity = try #require(previous.connectionIdentity.concreteValue)
    let target = HerdrPaneTarget(endpointKey: previous.endpointKey, paneID: "pane-duplicate")
    let processInfo = HerdrPaneProcessInfo(
      paneID: target.paneID,
      foregroundProcesses: [HerdrPaneProcess(pid: 42, name: "old-process")]
    )
    let newSnapshot = HerdrClientShellSnapshot(
      bootID: "local-restarted",
      revision: 1,
      focusedWorkspaceID: oldSnapshot.focusedWorkspaceID,
      focusedTabID: oldSnapshot.focusedTabID,
      focusedPaneID: oldSnapshot.focusedPaneID,
      workspaces: oldSnapshot.workspaces,
      tabs: oldSnapshot.tabs,
      panes: oldSnapshot.panes,
      agents: oldSnapshot.agents
    )
    let replacement = HerdrEndpointProjection(
      endpointKey: previous.endpointKey,
      label: previous.label,
      availability: previous.availability,
      status: previous.status,
      freshness: previous.freshness,
      connectionIdentity: .concrete(
        HerdrConnectionIdentity(
          generation: oldIdentity.generation,
          serverBootID: newSnapshot.bootID
        )
      ),
      snapshot: newSnapshot,
      focus: previous.focus,
      activation: previous.activation,
      attention: previous.attention
    )
    let aggregate = HerdrAggregateState(
      catalogRevision: envelope.payload.state.catalogRevision,
      endpoints: [replacement] + envelope.payload.state.endpoints.dropFirst(),
      perEndpointFocus: envelope.payload.state.perEndpointFocus,
      committedPresentation: envelope.payload.state.committedPresentation,
      requestedSelection: nil,
      pendingActivation: nil,
      capabilities: envelope.payload.state.capabilities
    )
    let frame = HerdrNativeAggregateFrame(
      messageKind: "aggregate_state",
      sequence: 2,
      projectionRevision: 2,
      activationEpoch: nil,
      requestID: nil,
      mutationResult: nil,
      processInfoTarget: nil,
      processInfoFence: nil,
      processInfo: nil,
      state: aggregate,
      syncCommitted: true
    )
    var reducerState = HerdrTerminalChromeFeature.State()
    reducerState.authorityMode = .aggregate
    reducerState.isForeground = true
    reducerState.connection = .connected
    reducerState.aggregateState = envelope.payload.state
    reducerState.aggregateSyncCommitted = true
    reducerState.nativeEventSequence = 1
    reducerState.nativeProjectionRevision = 1
    reducerState.aggregateProcessInfoByPaneTarget[target] = processInfo
    reducerState.pendingMutation = .renameTab(tabID: "tab-duplicate", label: "pending")
    reducerState.pendingNativeMutationRequestID = "prowl-native-mutation-1"
    _ = reducerState.endpointWatermarks.accept(
      HerdrEndpointFence(
        endpointKey: previous.endpointKey,
        identity: oldIdentity,
        snapshotRevision: oldSnapshot.revision
      )
    )

    reducerState.mutationGeneration = 4
    _ = HerdrTerminalChromeFeature().applyNativeFrame(&reducerState, frame: frame)

    #expect(reducerState.aggregateState?.endpoints.first?.snapshot?.bootID == "local-restarted")
    #expect(reducerState.aggregateProcessInfoByPaneTarget[target] == nil)
    #expect(reducerState.pendingMutation == nil)
    #expect(reducerState.pendingNativeMutationRequestID == nil)
    #expect(reducerState.pendingNativeMutationFence == nil)
    #expect(reducerState.mutationGeneration == 5)

    let store = TestStore(initialState: reducerState) {
      HerdrTerminalChromeFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)
    await store.send(
      .mutationResponse(4, .failure(.invalidResponse("stale timeout")))
    )
    #expect(store.state.mutationError == nil)
  }

  @Test func nativeDisconnectInvalidatesLateMutationResponse() async {
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.authorityMode = .aggregate
    initialState.isForeground = true
    initialState.connection = .connected
    initialState.pendingMutation = .renameTab(tabID: "tab-duplicate", label: "pending")
    initialState.pendingNativeMutationRequestID = "prowl-native-mutation-1"
    initialState.pendingNativeMutationFence = HerdrEndpointFence(
      endpointKey: .local,
      identity: HerdrConnectionIdentity(generation: 1, serverBootID: "boot-local"),
      snapshotRevision: 8
    )
    initialState.mutationGeneration = 4
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.nativeEvent(.stream(.disconnected)))
    await store.send(
      .mutationResponse(4, .failure(.invalidResponse("stale timeout")))
    )

    #expect(store.state.pendingMutation == nil)
    #expect(store.state.pendingNativeMutationRequestID == nil)
    #expect(store.state.mutationError == nil)
    #expect(store.state.mutationGeneration == 5)
  }

  @Test(.dependencies) func nativeDisconnectCancelsLateMutationTimeout() async throws {
    let clock = TestClock()
    let envelope = try goldenEnvelope()
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.authorityMode = .aggregate
    initialState.isForeground = true
    initialState.connection = .connected
    initialState.aggregateState = envelope.payload.state
    initialState.aggregateSyncCommitted = true
    initialState.pendingMutation = .renameTab(tabID: "tab-duplicate", label: "pending")
    initialState.pendingNativeMutationRequestID = "prowl-native-mutation-1"
    initialState.pendingNativeMutationFence = HerdrEndpointFence(
      endpointKey: .local,
      identity: HerdrConnectionIdentity(generation: 1, serverBootID: "boot-local"),
      snapshotRevision: 8
    )
    let requests = LockIsolated<[HerdrNativeActionRequest]>([])
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
      var client = HerdrTerminalChromeClient.testValue
      client.sendNativeAction = { request in requests.withValue { $0.append(request) } }
      $0.herdrTerminalChromeClient = client
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.nativeEvent(.stream(.disconnected)))
    await clock.advance(by: .seconds(5))

    #expect(requests.value.isEmpty)
    #expect(store.state.mutationError == nil)
    #expect(store.state.pendingMutation == nil)
  }

  @Test func staleReaderCannotPublishAfterConnectionReplacement() async throws {
    final class ReadBarrier: @unchecked Sendable {
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
    }

    let barrier = ReadBarrier()
    let rendezvous = try HerdrNativeChromeRendezvous(
      readBarrier: { epoch in
        if epoch == 1 {
          barrier.entered.signal()
          barrier.release.wait()
        }
      }
    )
    defer { rendezvous.stop() }

    let descriptor = try connectUnixSocket(at: rendezvous.binding.socketPath)
    defer { Darwin.close(descriptor) }
    let claim = nativeClaim(for: rendezvous)
    try writeFrame(JSONEncoder().encode(claim), to: descriptor)

    let result = await rendezvous.probe()
    guard case .aggregate(let session) = result else {
      Issue.record("Expected aggregate contract claim")
      return
    }

    func aggregateFrame(sequence: UInt64) throws -> Data {
      let base = try goldenEnvelope()
      return try JSONEncoder().encode(
        HerdrNativeChromeEnvelope(
          contractVersion: base.contractVersion,
          clientInstanceID: base.clientInstanceID,
          messageKind: "aggregate_state",
          eventSequence: sequence,
          projectionRevision: sequence,
          requestID: nil,
          activationEpoch: nil,
          payload: base.payload
        )
      )
    }

    try writeFrame(aggregateFrame(sequence: 1), to: descriptor)
    let entered = await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(returning: barrier.entered.wait(timeout: .now() + 2))
      }
    }
    #expect(entered == .success)

    var iterator = session.stream.makeAsyncIterator()
    let reconnectDescriptor = try connectUnixSocket(at: rendezvous.binding.socketPath)
    defer { Darwin.close(reconnectDescriptor) }
    try writeFrame(JSONEncoder().encode(claim), to: reconnectDescriptor)

    var observedReconnect = false
    while let state = await iterator.next() {
      if case .reconnected = state {
        observedReconnect = true
        break
      }
    }
    #expect(observedReconnect)

    barrier.release.signal()
    _ = Darwin.shutdown(descriptor, SHUT_RDWR)

    try writeFrame(aggregateFrame(sequence: 2), to: reconnectDescriptor)
    var observedNewFrame = false
    while let state = await iterator.next() {
      if case .frame(let frame) = state {
        #expect(frame.sequence != 1)
        if frame.sequence == 2 {
          observedNewFrame = true
          break
        }
      }
    }
    #expect(observedNewFrame)
  }

  @Test(.dependencies) func verifiedNoContractClaimStartsLegacyLifecycle() async {
    let clock = TestClock()
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.isForeground = true
    initialState.authorityMode = .probing
    initialState.connection = .connecting
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.herdrTerminalChromeClient = HerdrTerminalChromeClient(
        snapshot: { .empty },
        subscribeEvents: { _ in
          HerdrEventSubscription(stream: AsyncStream { _ in }, cancel: {})
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

    await store.send(.nativeEvent(.noContractClaim)) {
      $0.isForeground = true
      $0.authorityMode = .legacy
      $0.connection = .connecting
    }
    await store.receive(.subscriptionPrepared([])) {
      $0.subscriptionAwaitingSnapshot = true
    }
    await store.receive(.snapshotResponse(.success(.empty))) {
      $0.subscriptionAwaitingSnapshot = false
      $0.connection = .connected
    }
    await store.send(.foregroundChanged(false)) {
      $0.isForeground = false
      $0.connection = .hidden
      $0.authorityMode = .legacy
      $0.refreshGeneration = 1
      $0.mutationGeneration = 1
    }
    await store.finish()
  }

  @Test func malformedClaimLocksRendezvousAsIncompatible() async throws {
    let rendezvous = try HerdrNativeChromeRendezvous()
    defer { rendezvous.stop() }
    let descriptor = try connectUnixSocket(at: rendezvous.binding.socketPath)
    try writeFrame(Data("{}".utf8), to: descriptor)
    Darwin.close(descriptor)

    guard case .incompatible = await rendezvous.probe() else {
      Issue.record("Expected malformed claim to make the rendezvous incompatible")
      return
    }
    #expect(throws: Error.self) {
      let lateDescriptor = try connectUnixSocket(at: rendezvous.binding.socketPath)
      Darwin.close(lateDescriptor)
    }
  }

  @Test func incompatibleInitialClaimCannotBeOverwrittenByDelayedValidClaim() async throws {
    let rendezvous = try HerdrNativeChromeRendezvous()
    defer { rendezvous.stop() }

    let validDescriptor = try connectUnixSocket(at: rendezvous.binding.socketPath)
    defer { Darwin.close(validDescriptor) }
    let invalidDescriptor = try connectUnixSocket(at: rendezvous.binding.socketPath)
    defer { Darwin.close(invalidDescriptor) }
    let validClaimData = try JSONEncoder().encode(nativeClaim(for: rendezvous))

    // Keep B's accepted handler in readFrame while A reaches the terminal failure state.
    try writeFrameHeader(for: validClaimData, to: validDescriptor)
    for _ in 0..<100 { await Task.yield() }
    try writeFrame(Data("{}".utf8), to: invalidDescriptor)

    guard case .incompatible = await rendezvous.probe() else {
      Issue.record("Expected invalid claim A to make the rendezvous incompatible")
      return
    }

    try writeFrameBody(validClaimData, to: validDescriptor)
    for _ in 0..<100 {
      await Task.yield()
      let result = await rendezvous.probe()
      switch result {
      case .aggregate:
        Issue.record("A delayed valid claim B overwrote the incompatible terminal state")
        return
      case .incompatible:
        if socketPeerClosed(validDescriptor) { return }
      case .noContractClaim:
        Issue.record("Expected incompatible terminal state after invalid claim A")
        return
      }
    }
    Issue.record("Timed out waiting for the delayed valid claim to be rejected")
  }

  @Test func invalidChallengeLocksRendezvousAsIncompatible() async throws {
    let rendezvous = try HerdrNativeChromeRendezvous()
    defer { rendezvous.stop() }
    let descriptor = try connectUnixSocket(at: rendezvous.binding.socketPath)
    let claim = nativeClaim(for: rendezvous, challenge: "wrong-challenge")
    try writeFrame(JSONEncoder().encode(claim), to: descriptor)
    Darwin.close(descriptor)

    guard case .incompatible = await rendezvous.probe() else {
      Issue.record("Expected invalid challenge proof to make the rendezvous incompatible")
      return
    }
  }

  @Test func invalidStartIdentityLocksRendezvousAsIncompatible() async throws {
    let rendezvous = try HerdrNativeChromeRendezvous()
    defer { rendezvous.stop() }
    let descriptor = try connectUnixSocket(at: rendezvous.binding.socketPath)
    let actualStart = currentProcessStartIdentity()
    let claim = nativeClaim(
      for: rendezvous,
      startIdentity: HerdrNativeProcessStartIdentity(
        seconds: actualStart.seconds,
        microseconds: actualStart.microseconds &+ 1
      )
    )
    try writeFrame(JSONEncoder().encode(claim), to: descriptor)
    Darwin.close(descriptor)

    guard case .incompatible = await rendezvous.probe() else {
      Issue.record("Expected invalid process identity proof to make the rendezvous incompatible")
      return
    }
  }

  @Test func noContractClaimClosesListenerBeforeLateValidClaim() async throws {
    let rendezvous = try HerdrNativeChromeRendezvous()
    defer { rendezvous.stop() }

    guard case .noContractClaim = await rendezvous.probe() else {
      Issue.record("Expected no_contract_claim after the startup window")
      return
    }
    #expect(throws: Error.self) {
      let lateDescriptor = try connectUnixSocket(at: rendezvous.binding.socketPath)
      Darwin.close(lateDescriptor)
    }
  }

  @Test func postHandshakeInvalidFrameClosesListenerAndSocketFile() async throws {
    let rendezvous = try HerdrNativeChromeRendezvous()
    defer { rendezvous.stop() }
    let descriptor = try connectUnixSocket(at: rendezvous.binding.socketPath)
    let claim = nativeClaim(for: rendezvous)
    try writeFrame(JSONEncoder().encode(claim), to: descriptor)

    let result = await rendezvous.probe()
    guard case .aggregate(let session) = result else {
      Issue.record("Expected aggregate contract claim")
      Darwin.close(descriptor)
      return
    }
    try writeFrame(Data("not-json".utf8), to: descriptor)
    Darwin.close(descriptor)

    var iterator = session.stream.makeAsyncIterator()
    var becameIncompatible = false
    while let state = await iterator.next() {
      if case .incompatible = state {
        becameIncompatible = true
        break
      }
    }
    #expect(becameIncompatible)
    #expect(!FileManager.default.fileExists(atPath: rendezvous.binding.socketPath))
    #expect(throws: Error.self) {
      let lateDescriptor = try connectUnixSocket(at: rendezvous.binding.socketPath)
      Darwin.close(lateDescriptor)
    }
  }

  @Test func reconnectTimeoutClosesListenerAndSocketFile() async throws {
    let rendezvous = try HerdrNativeChromeRendezvous()
    defer { rendezvous.stop() }
    let descriptor = try connectUnixSocket(at: rendezvous.binding.socketPath)
    let claim = nativeClaim(for: rendezvous)
    try writeFrame(JSONEncoder().encode(claim), to: descriptor)

    let result = await rendezvous.probe()
    guard case .aggregate(let session) = result else {
      Issue.record("Expected aggregate contract claim")
      Darwin.close(descriptor)
      return
    }
    _ = Darwin.shutdown(descriptor, SHUT_RDWR)
    Darwin.close(descriptor)

    var iterator = session.stream.makeAsyncIterator()
    var becameIncompatible = false
    while let state = await iterator.next() {
      if case .incompatible = state {
        becameIncompatible = true
        break
      }
    }
    #expect(becameIncompatible)
    #expect(!FileManager.default.fileExists(atPath: rendezvous.binding.socketPath))
    #expect(throws: Error.self) {
      let lateDescriptor = try connectUnixSocket(at: rendezvous.binding.socketPath)
      Darwin.close(lateDescriptor)
    }
  }

  @Test func acceptedClaimKeepsListenerForProofProtectedReconnect() async throws {
    let rendezvous = try HerdrNativeChromeRendezvous()
    defer { rendezvous.stop() }
    let descriptor = try connectUnixSocket(at: rendezvous.binding.socketPath)
    let claim = nativeClaim(for: rendezvous)
    try writeFrame(JSONEncoder().encode(claim), to: descriptor)

    let result = await rendezvous.probe()

    guard case .aggregate(let session) = result else {
      Issue.record("Expected aggregate contract claim")
      Darwin.close(descriptor)
      return
    }
    #expect(FileManager.default.fileExists(atPath: rendezvous.binding.socketPath))

    _ = Darwin.shutdown(descriptor, SHUT_RDWR)
    Darwin.close(descriptor)
    let reconnectDescriptor = try connectUnixSocket(at: rendezvous.binding.socketPath)
    defer { Darwin.close(reconnectDescriptor) }
    try writeFrame(JSONEncoder().encode(claim), to: reconnectDescriptor)

    var iterator = session.stream.makeAsyncIterator()
    var reconnectedEpoch: UInt64?
    while let state = await iterator.next() {
      if case .reconnected(let epoch) = state {
        reconnectedEpoch = epoch
        break
      }
    }
    guard let epoch = reconnectedEpoch else {
      Issue.record("Expected proof-protected reconnect")
      return
    }
    #expect(epoch == 2)
  }

  @Test func nativeEventTerminationCancelsSessionAndClosesListener() async throws {
    let coordinator = HerdrNativeChromeCoordinator()
    let binding = try coordinator.prepareSurface()
    let client = HerdrTerminalChromeClient.live(coordinator: coordinator)
    let (startedStream, startedContinuation) = AsyncStream.makeStream(of: Void.self)
    let consumer = Task {
      for await event in client.nativeEvents() {
        if case .aggregateStarted = event {
          startedContinuation.yield()
        }
      }
    }
    let descriptor = try connectUnixSocket(at: binding.socketPath)
    defer { Darwin.close(descriptor) }
    try writeFrame(JSONEncoder().encode(nativeClaim(for: binding)), to: descriptor)

    var startedIterator = startedStream.makeAsyncIterator()
    _ = await startedIterator.next()
    #expect(FileManager.default.fileExists(atPath: binding.socketPath))

    consumer.cancel()
    await consumer.value
    for _ in 0..<100 where FileManager.default.fileExists(atPath: binding.socketPath) {
      await Task.yield()
    }

    #expect(!FileManager.default.fileExists(atPath: binding.socketPath))
    #expect(socketPeerClosed(descriptor))
  }

  @Test(.dependencies) func reconnectDuringNativeMutationDropsOldTimeout() async throws {
    let clock = TestClock()
    let sentRequests = LockIsolated<[HerdrNativeActionRequest]>([])
    let envelope = try goldenEnvelope()
    var initialState = HerdrTerminalChromeFeature.State()
    initialState.authorityMode = .aggregate
    initialState.isForeground = true
    initialState.connection = .connected
    initialState.aggregateState = envelope.payload.state
    initialState.aggregateSyncCommitted = true
    initialState.nativeConnectionEpoch = 1
    let store = TestStore(initialState: initialState) {
      HerdrTerminalChromeFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.herdrTerminalChromeClient = HerdrTerminalChromeClient(
        sendNativeAction: { request in
          sentRequests.withValue { $0.append(request) }
        },
        snapshot: { .empty },
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
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.renameTabRequested(tabID: "tab-duplicate", label: "Newest")) {
      $0.pendingMutation = .renameTab(tabID: "tab-duplicate", label: "Newest")
      $0.mutationGeneration = 1
      $0.nativeRequestSequence = 1
      $0.pendingNativeMutationRequestID = "prowl-native-mutation-1"
      $0.pendingNativeMutationFence = HerdrEndpointFence(
        endpointKey: .local,
        identity: HerdrConnectionIdentity(generation: 1, serverBootID: "boot-local"),
        snapshotRevision: 8
      )
    }
    let mutationRequest = try #require(sentRequests.value.first)
    #expect(sentRequests.value.count == 1)
    #expect(mutationRequest.requestID == "prowl-native-mutation-1")
    #expect(mutationRequest.payload.action == "mutate")
    #expect(mutationRequest.payload.method == "tab.rename")

    await store.send(.nativeEvent(.stream(.reconnected(epoch: 2)))) {
      $0.connection = .connecting
      $0.aggregateSyncCommitted = false
      $0.nativeConnectionEpoch = 2
      $0.pendingMutation = nil
      $0.pendingNativeMutationRequestID = nil
      $0.mutationGeneration = 2
    }
    await clock.advance(by: .seconds(5))

    #expect(sentRequests.value.map(\.payload.action) == ["mutate", "resync"])
    #expect(store.state.pendingMutation == nil)
    #expect(store.state.pendingNativeMutationRequestID == nil)
    #expect(store.state.mutationError == nil)
  }

  @Test func onlyLegacyModeAcceptsLegacyAuthority() {
    var state = HerdrTerminalChromeFeature.State()
    for mode in [
      HerdrTerminalChromeFeature.State.AuthorityMode.bootstrap,
      .probing,
      .aggregate,
      .incompatible,
    ] {
      state.authorityMode = mode
      #expect(!state.acceptsLegacyAuthority)
    }
    state.authorityMode = .legacy
    #expect(state.acceptsLegacyAuthority)
    #expect(state.committedActiveEndpointKey == .local)
  }
}

extension HerdrConnectionIdentityState {
  fileprivate var concreteValue: HerdrConnectionIdentity? {
    guard case .concrete(let value) = self else { return nil }
    return value
  }
}
