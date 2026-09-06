import Clocks
import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct CLILifecycleCommandHandlerTests {
  @Test func createPaneDirectionsMapToTerminalDirections() {
    #expect(CreatePaneDirection.right.terminalSplitDirection == .right)
    #expect(CreatePaneDirection.left.terminalSplitDirection == .left)
    #expect(CreatePaneDirection.upward.terminalSplitDirection == .top)
    #expect(CreatePaneDirection.down.terminalSplitDirection == .down)
  }

  @Test func createTabResolvesWorktreeCreatesTabAndReturnsCreatePayload() async throws {
    let base = makeTarget(tabID: "base-tab", paneID: "base-pane")
    let created = makeTarget(tabID: "created-tab", paneID: "created-pane")
    var resolvedSelector: TargetSelector?
    var createPath: String?
    let handler = LifecycleCommandHandler(
      resolveCreateTarget: { selector in
        resolvedSelector = selector
        return .success(base)
      },
      resolveCloseTarget: { _ in .success(LifecycleResolvedTarget(resource: .pane, target: base)) },
      createTab: { _, path in
        createPath = path
        return created
      },
      createPane: { _, _ in nil },
      closeTab: { _, _ in true },
      closePane: { _, _ in true }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .create(CreateInput(resource: .tab, selector: .worktree("App"), path: "/Projects/App"))
      )
    )

    #expect(response.ok)
    #expect(response.command == "create")
    #expect(response.schemaVersion == "prowl.cli.create.v1")
    #expect(resolvedSelector == .worktree("App"))
    #expect(createPath == "/Projects/App")
    let data = try #require(response.data)
    let payload = try data.decode(as: LifecycleCommandPayload.self)
    #expect(payload.resource == .tab)
    #expect(payload.target.tab.id == "created-tab")
  }

  @Test func createPaneUsesResolvedAnchorAndReturnsCreatePayload() async throws {
    let anchor = makeTarget(tabID: "anchor-tab", paneID: "anchor-pane")
    let created = makeTarget(tabID: "anchor-tab", paneID: "created-pane")
    var resolvedSelector: TargetSelector?
    var createdFrom: TabResolvedTarget?
    var createdDirection: CreatePaneDirection?
    let handler = LifecycleCommandHandler(
      resolveCreateTarget: { selector in
        resolvedSelector = selector
        return .success(anchor)
      },
      resolveCloseTarget: { _ in .success(LifecycleResolvedTarget(resource: .pane, target: anchor)) },
      createTab: { _, _ in nil },
      createPane: { target, direction in
        createdFrom = target
        createdDirection = direction
        return created
      },
      closeTab: { _, _ in true },
      closePane: { _, _ in true }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .create(
          CreateInput(resource: .pane, selector: .pane("p12"), direction: .upward)
        )
      )
    )

    #expect(response.ok)
    #expect(resolvedSelector == .pane("p12"))
    #expect(createdFrom == anchor)
    #expect(createdDirection == .upward)
    let data = try #require(response.data)
    let payload = try data.decode(as: LifecycleCommandPayload.self)
    #expect(payload.resource == .pane)
    #expect(payload.anchor?.pane.id == "anchor-pane")
    #expect(payload.direction == .upward)
    #expect(payload.target.pane.id == "created-pane")
  }

  @Test func createPaneRejectsNonPaneSocketInputBeforeResolution() async {
    let target = makeTarget()
    var didResolve = false
    var didCreate = false
    let handler = LifecycleCommandHandler(
      resolveCreateTarget: { _ in
        didResolve = true
        return .success(target)
      },
      resolveCloseTarget: { _ in .success(LifecycleResolvedTarget(resource: .pane, target: target)) },
      createTab: { _, _ in nil },
      createPane: { _, _ in
        didCreate = true
        return target
      },
      closeTab: { _, _ in true },
      closePane: { _, _ in true }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .create(
          CreateInput(resource: .pane, selector: .worktree("App"), direction: .right)
        )
      )
    )

    #expect(!response.ok)
    #expect(response.error?.code == CLIErrorCode.invalidArgument)
    #expect(!didResolve)
    #expect(!didCreate)
  }

  @Test func createPaneReportsCreateFailedWhenTheSplitCannotBeMade() async throws {
    let anchor = makeTarget(tabID: "anchor-tab", paneID: "anchor-pane")
    var createAttempts = 0
    let handler = LifecycleCommandHandler(
      resolveCreateTarget: { _ in .success(anchor) },
      resolveCloseTarget: { _ in .success(LifecycleResolvedTarget(resource: .pane, target: anchor)) },
      createTab: { _, _ in nil },
      createPane: { _, _ in
        createAttempts += 1
        return nil
      },
      closeTab: { _, _ in true },
      closePane: { _, _ in true }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .create(
          CreateInput(resource: .pane, selector: .pane("p12"), direction: .down)
        )
      )
    )

    #expect(!response.ok)
    #expect(response.error?.code == CLIErrorCode.createFailed)
    #expect(createAttempts == 1)
    #expect(response.data == nil)
  }

  @Test func createTabLaunchesAnEnabledProfileByExactNameAndReturnsMetadata() async throws {
    let base = makeTarget(tabID: "base-tab", paneID: "base-pane")
    let created = makeTarget(tabID: "created-tab", paneID: "created-pane")
    let profile = AgentProfile(name: "Reviewer", runtime: .claude)
    var launchRequest: CLIProfileLaunchRequest?
    var lifecycle: [String] = []
    let handler = LifecycleCommandHandler(
      resolveCreateTarget: { _ in .success(base) },
      resolveCloseTarget: { _ in .success(LifecycleResolvedTarget(resource: .pane, target: base)) },
      createTab: { _, _ in nil },
      createPane: { _, _ in nil },
      profiles: { [profile] },
      prepareAgentProfile: { request in
        lifecycle.append("preflight")
        #expect(request.dispatchID == nil)
        return .success(request)
      },
      launchAgentProfile: { request in
        lifecycle.append("launch")
        launchRequest = request
        return .success(created)
      },
      issueDispatch: {
        lifecycle.append("issue")
        return .success(
          DispatchPendingRecord(id: "d1", createdAt: "2026-08-23T02:00:00.000Z")
        )
      },
      bindDispatch: { dispatchID, target in
        lifecycle.append("bind:\(dispatchID):\(target.paneID)")
        return .success(())
      },
      closeTab: { _, _ in true },
      closePane: { _, _ in true }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .create(
          CreateInput(
            resource: .tab,
            selector: .worktree("App"),
            launch: CreateLaunchInput(profile: "Reviewer", prompt: "Review the diff."),
            background: true
          )
        )
      )
    )

    #expect(response.ok)
    #expect(launchRequest?.profile == profile)
    #expect(launchRequest?.target == base)
    #expect(launchRequest?.prompt == "Review the diff.")
    #expect(launchRequest?.dispatchID == "d1")
    #expect(launchRequest?.background == true)
    #expect(lifecycle == ["preflight", "issue", "launch", "bind:d1:created-pane"])
    let data = try #require(response.data)
    let payload = try data.decode(as: LifecycleCommandPayload.self)
    #expect(
      payload.launch
        == LifecycleCommandLaunch(
          profileID: profile.id.uuidString,
          profileName: "Reviewer",
          agent: "claude"
        )
    )
    #expect(payload.dispatch?.id == "d1")
  }

  @Test func cancellationDuringPreflightNeverIssuesDispatchOrLaunchesSurface() async {
    let base = makeTarget()
    let profile = AgentProfile(name: "Reviewer", runtime: .codex)
    let clock = TestClock()
    var issued = false
    var launched = false
    var cancelledPreparation = false
    let handler = LifecycleCommandHandler(
      resolveCreateTarget: { _ in .success(base) },
      resolveCloseTarget: { _ in .success(.init(resource: .pane, target: base)) },
      createTab: { _, _ in nil },
      createPane: { _, _ in nil },
      profiles: { [profile] },
      prepareAgentProfile: { request in
        do {
          try await clock.sleep(for: .seconds(10))
          return .success(request)
        } catch {
          // Model a production resolver that catches cancellation and returns
          // an ordinary degraded/successful preparation.
          return .success(request)
        }
      },
      launchAgentProfile: { _ in
        launched = true
        return .success(base)
      },
      cancelProfilePreparation: { _ in cancelledPreparation = true },
      issueDispatch: {
        issued = true
        return .failure(.capacityExceeded)
      },
      closeTab: { _, _ in true },
      closePane: { _, _ in true }
    )
    let task = Task {
      await handler.handle(
        envelope: CommandEnvelope(
          output: .json,
          command: .create(
            .init(
              resource: .tab,
              selector: .worktree("App"),
              launch: .init(profile: "Reviewer", prompt: "Review")
            )
          )
        )
      )
    }
    await Task.yield()

    task.cancel()
    _ = await task.value

    #expect(!issued)
    #expect(!launched)
    #expect(cancelledPreparation)
  }

  @Test func promptedLaunchFailureCancelsIssuedDispatch() async {
    let base = makeTarget()
    let profile = AgentProfile(name: "Reviewer", runtime: .claude)
    var cancelled: [String] = []
    let handler = LifecycleCommandHandler(
      resolveCreateTarget: { _ in .success(base) },
      resolveCloseTarget: { _ in .success(LifecycleResolvedTarget(resource: .pane, target: base)) },
      createTab: { _, _ in nil },
      createPane: { _, _ in nil },
      profiles: { [profile] },
      launchAgentProfile: { request in
        #expect(request.dispatchID == "d1")
        return .failure(.createFailed("Launch failed."))
      },
      issueDispatch: {
        .success(DispatchPendingRecord(id: "d1", createdAt: "2026-08-23T02:00:00.000Z"))
      },
      cancelDispatch: { cancelled.append($0) },
      closeTab: { _, _ in true },
      closePane: { _, _ in true }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .create(
          CreateInput(
            resource: .tab,
            selector: .worktree("App"),
            launch: CreateLaunchInput(profile: "Reviewer", prompt: "Review.")
          )
        )
      )
    )

    #expect(!response.ok)
    #expect(cancelled == ["d1"])
  }

  @Test func dispatchCapacityFailurePreventsLaunch() async {
    let base = makeTarget()
    let profile = AgentProfile(name: "Reviewer", runtime: .claude)
    var didLaunch = false
    var cancelledPreparation = false
    let handler = LifecycleCommandHandler(
      resolveCreateTarget: { _ in .success(base) },
      resolveCloseTarget: { _ in .success(LifecycleResolvedTarget(resource: .pane, target: base)) },
      createTab: { _, _ in nil },
      createPane: { _, _ in nil },
      profiles: { [profile] },
      launchAgentProfile: { _ in
        didLaunch = true
        return .success(base)
      },
      cancelProfilePreparation: { _ in cancelledPreparation = true },
      issueDispatch: { .failure(.capacityExceeded) },
      closeTab: { _, _ in true },
      closePane: { _, _ in true }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .create(
          CreateInput(
            resource: .tab,
            selector: .worktree("App"),
            launch: CreateLaunchInput(profile: "Reviewer", prompt: "Review.")
          )
        )
      )
    )

    #expect(!response.ok)
    #expect(response.error?.code == CLIErrorCode.dispatchCapacityExceeded)
    #expect(!didLaunch)
    #expect(cancelledPreparation)
  }

  @Test func unpromptedProfileLaunchDoesNotIssueOrBindDispatch() async throws {
    let target = makeTarget()
    let profile = AgentProfile(name: "Reviewer", runtime: .codex)
    var issued = false
    var bound = false
    let handler = LifecycleCommandHandler(
      resolveCreateTarget: { _ in .success(target) },
      resolveCloseTarget: { _ in .success(.init(resource: .pane, target: target)) },
      createTab: { _, _ in nil },
      createPane: { _, _ in nil },
      profiles: { [profile] },
      launchAgentProfile: { request in
        #expect(request.dispatchID == nil)
        return .success(target)
      },
      issueDispatch: {
        issued = true
        return .failure(.capacityExceeded)
      },
      bindDispatch: { _, _ in
        bound = true
        return .success(())
      },
      closeTab: { _, _ in true },
      closePane: { _, _ in true }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .create(
          .init(
            resource: .tab,
            selector: .worktree("App"),
            launch: .init(profile: "Reviewer")
          ))
      ))
    #expect(response.ok)
    #expect(!issued)
    #expect(!bound)
    #expect(try #require(response.data).decode(as: LifecycleCommandPayload.self).dispatch == nil)
  }

  @Test func bindFailureRollsBackCreatedSurfaceAndCancelsDispatch() async {
    let anchor = makeTarget(paneID: "anchor")
    let created = makeTarget(paneID: "created")
    let profile = AgentProfile(name: "Reviewer", runtime: .codex)
    var rolledBack: (LifecycleResource, TabResolvedTarget)?
    var cancelled: String?
    let handler = LifecycleCommandHandler(
      resolveCreateTarget: { _ in .success(anchor) },
      resolveCloseTarget: { _ in .success(.init(resource: .pane, target: anchor)) },
      createTab: { _, _ in nil },
      createPane: { _, _ in nil },
      profiles: { [profile] },
      launchAgentProfile: { _ in .success(created) },
      issueDispatch: {
        .success(.init(id: "d1", createdAt: "2026-08-23T02:00:00.000Z"))
      },
      bindDispatch: { _, _ in .failure(.notFound) },
      cancelDispatch: { cancelled = $0 },
      rollbackProfileLaunch: { rolledBack = ($0, $1) },
      closeTab: { _, _ in true },
      closePane: { _, _ in true }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .create(
          .init(
            resource: .pane,
            selector: .pane("anchor"),
            direction: .right,
            launch: .init(profile: "Reviewer", prompt: "Review")
          ))
      ))
    #expect(response.error?.code == CLIErrorCode.createFailed)
    #expect(rolledBack?.0 == .pane)
    #expect(rolledBack?.1 == created)
    #expect(cancelled == "d1")
  }

  @Test func disabledNamesDoNotMakeAnEnabledProfileNonUnique() async {
    let target = makeTarget()
    let enabled = AgentProfile(name: "Reviewer", runtime: .claude)
    let disabled = AgentProfile(name: "Reviewer", isEnabled: false, runtime: .codex)
    var launchedProfile: AgentProfile?
    let handler = LifecycleCommandHandler(
      resolveCreateTarget: { _ in .success(target) },
      resolveCloseTarget: { _ in .success(LifecycleResolvedTarget(resource: .pane, target: target)) },
      createTab: { _, _ in nil },
      createPane: { _, _ in nil },
      profiles: { [disabled, enabled] },
      launchAgentProfile: { request in
        launchedProfile = request.profile
        return .success(target)
      },
      closeTab: { _, _ in true },
      closePane: { _, _ in true }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .create(
          CreateInput(
            resource: .pane,
            selector: .pane("p12"),
            direction: .right,
            launch: CreateLaunchInput(profile: "Reviewer")
          )
        )
      )
    )

    #expect(response.ok)
    #expect(launchedProfile?.id == enabled.id)
  }

  @Test func profileUUIDWinsOverAnExactNameMatch() async {
    let target = makeTarget()
    let byID = AgentProfile(name: "By ID", runtime: .claude)
    let byName = AgentProfile(name: byID.id.uuidString, runtime: .codex)
    var launchedProfile: AgentProfile?
    let handler = LifecycleCommandHandler(
      resolveCreateTarget: { _ in .success(target) },
      resolveCloseTarget: { _ in .success(LifecycleResolvedTarget(resource: .pane, target: target)) },
      createTab: { _, _ in nil },
      createPane: { _, _ in nil },
      profiles: { [byName, byID] },
      launchAgentProfile: { request in
        launchedProfile = request.profile
        return .success(target)
      },
      closeTab: { _, _ in true },
      closePane: { _, _ in true }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .create(
          CreateInput(
            resource: .tab,
            selector: .worktree("App"),
            launch: CreateLaunchInput(profile: byID.id.uuidString)
          )
        )
      )
    )

    #expect(response.ok)
    #expect(launchedProfile?.id == byID.id)
  }

  @Test func disabledProfileUUIDIsNotLaunchable() async {
    let target = makeTarget()
    let disabled = AgentProfile(name: "Reviewer", isEnabled: false, runtime: .claude)
    let handler = makeProfileLookupHandler(target: target, profiles: [disabled])

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .create(
          CreateInput(
            resource: .tab,
            selector: .worktree("App"),
            launch: CreateLaunchInput(profile: disabled.id.uuidString)
          )
        )
      )
    )

    #expect(!response.ok)
    #expect(response.error?.code == CLIErrorCode.profileNotFound)
  }

  @Test func duplicateEnabledProfileNameIsRejected() async {
    let target = makeTarget()
    let profiles = [
      AgentProfile(name: "Reviewer", runtime: .claude),
      AgentProfile(name: "Reviewer", runtime: .codex),
    ]
    let handler = makeProfileLookupHandler(target: target, profiles: profiles)

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .create(
          CreateInput(
            resource: .tab,
            selector: .worktree("App"),
            launch: CreateLaunchInput(profile: "Reviewer")
          )
        )
      )
    )

    #expect(!response.ok)
    #expect(response.error?.code == CLIErrorCode.profileNotUnique)
  }

  @Test func profileLaunchFailureClassifiesPlanningAndCreationErrors() {
    let profile = AgentProfile(name: "Reviewer", runtime: .amp)

    #expect(
      CLIProfileLaunchFailure.planning(
        AgentRuntimeError.unsupportedStartIntent(.amp, .prompt("Review.")),
        profile: profile
      )
        == .invalidArgument("Agent Profile “Reviewer” does not support kickoff prompts.")
    )
    #expect(
      CLIProfileLaunchFailure.creation(.splitAnchorUnavailable, profile: profile)
        == .createFailed("The split anchor for Agent Profile “Reviewer” is no longer available.")
    )
  }

  @Test func profileLaunchFailurePreservesTheCreationReason() async {
    let target = makeTarget()
    let profile = AgentProfile(name: "Reviewer", runtime: .claude)
    let handler = LifecycleCommandHandler(
      resolveCreateTarget: { _ in .success(target) },
      resolveCloseTarget: { _ in .success(LifecycleResolvedTarget(resource: .pane, target: target)) },
      createTab: { _, _ in nil },
      createPane: { _, _ in nil },
      profiles: { [profile] },
      launchAgentProfile: { _ in
        .failure(.createFailed("The split anchor is no longer available."))
      },
      closeTab: { _, _ in true },
      closePane: { _, _ in true }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .create(
          CreateInput(
            resource: .tab,
            selector: .worktree("App"),
            launch: CreateLaunchInput(profile: "Reviewer")
          )
        )
      )
    )

    #expect(!response.ok)
    #expect(response.error?.code == CLIErrorCode.createFailed)
    #expect(response.error?.message == "The split anchor is no longer available.")
  }

  @Test func unsupportedPromptIntentMapsToInvalidArgument() async {
    let target = makeTarget()
    let profile = AgentProfile(name: "Reviewer", runtime: .amp)
    let handler = LifecycleCommandHandler(
      resolveCreateTarget: { _ in .success(target) },
      resolveCloseTarget: { _ in .success(LifecycleResolvedTarget(resource: .pane, target: target)) },
      createTab: { _, _ in nil },
      createPane: { _, _ in nil },
      profiles: { [profile] },
      launchAgentProfile: { _ in
        .failure(.invalidArgument("Agent Profile “Reviewer” does not support kickoff prompts."))
      },
      issueDispatch: {
        .success(DispatchPendingRecord(id: "d1", createdAt: "2026-08-23T02:00:00.000Z"))
      },
      closeTab: { _, _ in true },
      closePane: { _, _ in true }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .create(
          CreateInput(
            resource: .tab,
            selector: .worktree("App"),
            launch: CreateLaunchInput(profile: "Reviewer", prompt: "Review.")
          )
        )
      )
    )

    #expect(!response.ok)
    #expect(response.error?.code == CLIErrorCode.invalidArgument)
    #expect(response.error?.message == "Agent Profile “Reviewer” does not support kickoff prompts.")
  }

  @Test func emptyProfilePromptIsRejectedBeforeResolution() async {
    let target = makeTarget()
    var didResolve = false
    let handler = LifecycleCommandHandler(
      resolveCreateTarget: { _ in
        didResolve = true
        return .success(target)
      },
      resolveCloseTarget: { _ in .success(LifecycleResolvedTarget(resource: .pane, target: target)) },
      createTab: { _, _ in nil },
      createPane: { _, _ in nil },
      closeTab: { _, _ in true },
      closePane: { _, _ in true }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .create(
          CreateInput(
            resource: .tab,
            selector: .worktree("App"),
            launch: CreateLaunchInput(profile: "Reviewer", prompt: "  \n")
          )
        )
      )
    )

    #expect(!response.ok)
    #expect(response.error?.code == CLIErrorCode.emptyInput)
    #expect(!didResolve)
  }

  @Test func profilePromptContainingNULIsRejectedBeforeResolution() async {
    let target = makeTarget()
    var didResolve = false
    let handler = LifecycleCommandHandler(
      resolveCreateTarget: { _ in
        didResolve = true
        return .success(target)
      },
      resolveCloseTarget: { _ in .success(LifecycleResolvedTarget(resource: .pane, target: target)) },
      createTab: { _, _ in nil },
      createPane: { _, _ in nil },
      closeTab: { _, _ in true },
      closePane: { _, _ in true }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .create(
          CreateInput(
            resource: .tab,
            selector: .worktree("App"),
            launch: CreateLaunchInput(profile: "Reviewer", prompt: "Review\0this")
          )
        )
      )
    )

    #expect(!response.ok)
    #expect(response.error?.code == CLIErrorCode.invalidArgument)
    #expect(!didResolve)
  }

  @Test func oversizedProfilePromptIsRejectedBeforeResolution() async {
    let target = makeTarget()
    var didResolve = false
    let handler = LifecycleCommandHandler(
      resolveCreateTarget: { _ in
        didResolve = true
        return .success(target)
      },
      resolveCloseTarget: { _ in .success(LifecycleResolvedTarget(resource: .pane, target: target)) },
      createTab: { _, _ in nil },
      createPane: { _, _ in nil },
      closeTab: { _, _ in true },
      closePane: { _, _ in true }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .create(
          CreateInput(
            resource: .tab,
            selector: .worktree("App"),
            launch: CreateLaunchInput(
              profile: "Reviewer",
              prompt: String(
                repeating: "x",
                count: CreateLaunchInput.maximumPromptUTF8ByteCount + 1
              )
            )
          )
        )
      )
    )

    #expect(!response.ok)
    #expect(response.error?.code == CLIErrorCode.invalidArgument)
    #expect(!didResolve)
  }

  @Test func backgroundWithoutProfileIsRejectedBeforeResolution() async {
    let target = makeTarget()
    var didResolve = false
    let handler = LifecycleCommandHandler(
      resolveCreateTarget: { _ in
        didResolve = true
        return .success(target)
      },
      resolveCloseTarget: { _ in .success(LifecycleResolvedTarget(resource: .pane, target: target)) },
      createTab: { _, _ in nil },
      createPane: { _, _ in nil },
      closeTab: { _, _ in true },
      closePane: { _, _ in true }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(
        output: .json,
        command: .create(
          CreateInput(resource: .tab, selector: .worktree("App"), background: true)
        )
      )
    )

    #expect(!response.ok)
    #expect(response.error?.code == CLIErrorCode.invalidArgument)
    #expect(!didResolve)
  }

  @Test func closeUsesResolvedResourceAndReturnsClosePayload() async throws {
    let target = makeTarget(tabID: "tab-to-close", paneID: "pane-to-close")
    var closedPane: TabResolvedTarget?
    let handler = LifecycleCommandHandler(
      resolveCreateTarget: { _ in .success(target) },
      resolveCloseTarget: { selector in
        #expect(selector == .auto("p12"))
        return .success(LifecycleResolvedTarget(resource: .pane, target: target))
      },
      createTab: { _, _ in nil },
      createPane: { _, _ in nil },
      closeTab: { _, _ in false },
      closePane: { target, force in
        #expect(force)
        closedPane = target
        return true
      }
    )

    let response = await handler.handle(
      envelope: CommandEnvelope(output: .json, command: .close(CloseInput(selector: .auto("p12"), force: true)))
    )

    #expect(response.ok)
    #expect(response.command == "close")
    #expect(response.schemaVersion == "prowl.cli.close.v1")
    #expect(closedPane == target)
    let data = try #require(response.data)
    let payload = try data.decode(as: LifecycleCommandPayload.self)
    #expect(payload.resource == .pane)
    #expect(payload.target.pane.id == "pane-to-close")
  }

  private func makeProfileLookupHandler(
    target: TabResolvedTarget,
    profiles: [AgentProfile]
  ) -> LifecycleCommandHandler {
    LifecycleCommandHandler(
      resolveCreateTarget: { _ in .success(target) },
      resolveCloseTarget: { _ in .success(LifecycleResolvedTarget(resource: .pane, target: target)) },
      createTab: { _, _ in nil },
      createPane: { _, _ in nil },
      profiles: { profiles },
      launchAgentProfile: { _ in .success(target) },
      closeTab: { _, _ in true },
      closePane: { _, _ in true }
    )
  }

  private func makeTarget(
    worktreeID: String = "App:/Projects/App",
    worktreeName: String = "App",
    worktreePath: String = "/Projects/App",
    worktreeRootPath: String = "/Projects/App",
    worktreeKind: String = "git",
    tabID: String = "tab-1",
    tabTitle: String = "App 1",
    tabSelected: Bool = true,
    paneID: String = "pane-1",
    paneTitle: String = "zsh",
    paneCWD: String? = "/Projects/App",
    paneFocused: Bool = true
  ) -> TabResolvedTarget {
    TabResolvedTarget(
      worktreeID: worktreeID,
      worktreeName: worktreeName,
      worktreePath: worktreePath,
      worktreeRootPath: worktreeRootPath,
      worktreeKind: worktreeKind,
      tabID: tabID,
      tabTitle: tabTitle,
      tabSelected: tabSelected,
      paneID: paneID,
      paneTitle: paneTitle,
      paneCWD: paneCWD,
      paneFocused: paneFocused
    )
  }
}
