import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

/// A shape-valid briefing used when a test does not care about the content.
nonisolated private let validHandoffBriefing = """
  # Handoff

  ## Objective
  Ship the checkout flow.

  ## Current State
  Tests are green.

  ## Next Steps
  1. Review the PR.
  """
nonisolated private let handoffHandlerSourcePaneID =
  UUID(uuidString: "A29DBA75-3B49-490B-912F-0B2A894F6262")!

@MainActor
struct HandoffCommandHandlerTests {
  private func makeTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "handoff-handler-tests", directoryHint: .isDirectory)
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  private let fixedDate = Date(timeIntervalSince1970: 1_760_000_000)

  private func profile(
    id: AgentProfile.ID = UUID(),
    name: String = "Codex · Work",
    isEnabled: Bool = true,
    model: String? = nil,
    reasoningEffort: String? = nil,
    bindsDedicatedHome: Bool = true
  ) -> AgentProfile {
    AgentProfile(
      id: id,
      name: name,
      isEnabled: isEnabled,
      runtime: .codex,
      model: model,
      reasoningEffort: reasoningEffort,
      extraArguments: "-p work",
      environmentOverrides: [
        AgentProfileEnvironmentOverride(name: "OPENAI_BASE_URL", value: "https://example.test/v1")
      ],
      bindsDedicatedHome: bindsDedicatedHome
    )
  }

  private func makeHandler(
    root: URL,
    outgoingAgent: String?,
    isSelfHandoff: Bool = false,
    outgoingLaunchObservation: AgentLaunchObservation? = AgentLaunchObservation(
      model: "gpt-5.4",
      executionMode: .unrestricted
    ),
    outgoingSession: AgentSession? = AgentSession(
      id: "9B0E3B0E-67B3-4D45-A3A0-7DD9BC713711",
      transcriptPath: nil,
      source: .openFile,
      confidence: .exact
    ),
    sessionContext: HandoffStore.SessionContext? = HandoffStore.SessionContext(
      agent: "codex",
      paneID: handoffHandlerSourcePaneID.uuidString,
      paneTitle: "codex",
      source: "terminal-scrollback",
      confidence: "fallback",
      excerptText: "working on handoff"
    ),
    launched: HandoffLaunchedPane? = HandoffLaunchedPane(
      worktreeID: "ws", worktreeName: "Workspace", tabID: "tab-1", paneID: "pane-1", paneTitle: "claude"
    ),
    resolveFailure: HandoffResolveError? = nil,
    launchSpy: (@MainActor (AgentStartRequest) -> Void)? = nil,
    profiles: [AgentProfile] = [],
    profileLaunchSpy: (@MainActor (AgentProfileLaunchPlan) -> Void)? = nil,
    forkSpy: (@Sendable (AgentResumeRequest, URL) async throws -> String)? = nil,
    notificationSpy: (@MainActor (String) -> Void)? = nil,
    completionSpy: (@MainActor (HandoffCLICompletion) -> Void)? = nil,
    requestClaim: ((UUID, HandoffRequestExpectation) -> HandoffRequestClaimResult)? = nil

  ) -> HandoffCommandHandler {
    HandoffCommandHandler(
      resolveProvider: { _, _ in
        if let resolveFailure {
          return .failure(resolveFailure)
        }
        return .success(
          HandoffResolvedTarget(
            worktreeID: "ws",
            worktreeName: "Workspace",
            rootPath: root.path(percentEncoded: false),
            paneID: handoffHandlerSourcePaneID.uuidString,
            outgoingAgent: outgoingAgent,
            outgoingLaunchObservation: outgoingLaunchObservation,
            outgoingSession: outgoingSession,
            sessionContext: sessionContext,
            isSelfHandoff: isSelfHandoff
          )
        )
      },
      launchProvider: { _, request in
        launchSpy?(request)
        return launched
      },
      profileProvider: { profileID in
        profiles.first { $0.id == profileID }
      },
      profileLaunchProvider: { _, plan in
        profileLaunchSpy?(plan)
        return launched
      },
      forkProvider: { request, directory in
        guard let forkSpy else { return validHandoffBriefing }
        return try await forkSpy(request, directory)
      },
      notifyLaunch: { _, _, receiverDisplayName in
        notificationSpy?(receiverDisplayName)
      },
      completionObserver: { completion in
        completionSpy?(completion)
      },
      requestAuthorizer: { requestID, expectation in
        requestClaim?(requestID, expectation) ?? .claimed
      },
      now: { [fixedDate] in fixedDate }
    )
  }

  private func envelope(_ input: HandoffInput) -> CommandEnvelope {
    CommandEnvelope(output: .json, command: .handoff(input))
  }

  // MARK: - save

  @Test func saveWithInlineBriefWritesArtifactAndReturnsPayload() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let handler = makeHandler(root: root, outgoingAgent: "codex")

    let response = await handler.handle(
      envelope: envelope(HandoffInput(action: .save, note: "wip", brief: validHandoffBriefing))
    )

    #expect(response.ok)
    #expect(response.command == "handoff")
    let payload = try #require(try response.data?.decode(as: HandoffCommandPayload.self))
    #expect(payload.action == .save)
    #expect(payload.outgoingAgent == "codex")
    #expect(payload.briefing == "inline")
    #expect(payload.hasBriefing)
    let session = try #require(payload.sessionContext)
    #expect(session.excerptPath?.hasPrefix("handoff/sessions/") == true)

    let store = HandoffStore(rootURL: root)
    let current = try String(contentsOf: store.currentURL, encoding: .utf8)
    #expect(current == validHandoffBriefing + "\n")
    let content = try String(contentsOf: store.contextURL, encoding: .utf8)
    #expect(content.contains("Session Context:"))
    #expect(content.contains(".prowl/handoff/sessions/"))
    // One save produces exactly one log line, carrying the briefing outcome.
    let log = try String(contentsOf: store.logURL, encoding: .utf8)
    let entries = log.split(separator: "\n").filter { $0.hasPrefix("- ") }
    #expect(entries.count == 1)
    #expect(entries.first?.contains("briefing=inline") == true)
  }

  @Test func saveForksBriefingForThirdPartySource() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let resumed = LockIsolated<AgentResumeRequest?>(nil)
    let handler = makeHandler(
      root: root,
      outgoingAgent: "codex",
      forkSpy: { request, _ in
        resumed.setValue(request)
        return """
          Here is the updated artifact:

          # Handoff

          ## Objective
          Source-authored status.

          ## Current State
          Awaiting review.

          ## Next Steps
          1. Hand off.
          """
      }
    )

    let response = await handler.handle(envelope: envelope(HandoffInput(action: .save)))

    #expect(response.ok)
    #expect(resumed.value?.agent == .codex)
    #expect(resumed.value?.session.confidence == .exact)
    #expect(resumed.value?.model == "gpt-5.4")
    let payload = try #require(try response.data?.decode(as: HandoffCommandPayload.self))
    #expect(payload.briefing == "fork")
    #expect(payload.hasBriefing)
    // Prowl transcribed the reply (preamble dropped) into current.md.
    let content = try String(contentsOf: HandoffStore(rootURL: root).currentURL, encoding: .utf8)
    #expect(content.hasPrefix("# Handoff"))
    #expect(content.contains("Source-authored status."))
  }

  @Test func selfHandoffSaveWithoutBriefIsRejectedWithGuidance() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let forkCalled = LockIsolated(false)
    let handler = makeHandler(
      root: root,
      outgoingAgent: "claude",
      isSelfHandoff: true,
      forkSpy: { _, _ in
        forkCalled.setValue(true)
        return validHandoffBriefing
      }
    )

    let response = await handler.handle(envelope: envelope(HandoffInput(action: .save)))

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.briefRequired)
    #expect(response.error?.message.contains("--brief -") == true)
    #expect(forkCalled.value == false)
    // Zero side effects: nothing was scaffolded or written.
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".prowl").path(percentEncoded: false)))
  }

  @Test func invalidInlineBriefIsRejectedWithZeroSideEffects() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let handler = makeHandler(root: root, outgoingAgent: "claude", isSelfHandoff: true)

    let response = await handler.handle(
      envelope: envelope(
        HandoffInput(action: .toAgent, toAgent: "codex", brief: "not a briefing")
      )
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.invalidBrief)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".prowl").path(percentEncoded: false)))
  }

  @Test func supersededHudRequestIsRejectedBeforeSideEffects() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let requestID = UUID()

    let handler = makeHandler(
      root: root,
      outgoingAgent: "codex",
      requestClaim: { _, _ in .unavailable }

    )

    let response = await handler.handle(
      envelope: envelope(
        HandoffInput(
          action: .toAgent,
          toAgent: "claude",
          brief: validHandoffBriefing,
          requestID: requestID
        )
      )
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.handoffRequestSuperseded)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".prowl").path(percentEncoded: false)))
  }

  @Test func mismatchedHudRequestIsRejectedWithoutConsumingArtifacts() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let requestID = UUID()
    let actual = LockIsolated<HandoffRequestExpectation?>(nil)
    let handler = makeHandler(
      root: root,
      outgoingAgent: "codex",
      requestClaim: { _, expectation in
        actual.setValue(expectation)
        return .mismatch
      }
    )

    let response = await handler.handle(
      envelope: envelope(
        HandoffInput(
          action: .toAgent,
          toAgent: "claude",
          brief: validHandoffBriefing,
          requestID: requestID
        )
      )
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.invalidArgument)
    #expect(
      actual.value
        == HandoffRequestExpectation(
          sourcePaneID: handoffHandlerSourcePaneID,
          operation: .handoff(target: .runtimeDefault(.claude))
        )
    )
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".prowl").path(percentEncoded: false)))
  }

  @Test func briefAndNoBriefAreMutuallyExclusive() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let handler = makeHandler(root: root, outgoingAgent: "codex")

    let response = await handler.handle(
      envelope: envelope(
        HandoffInput(action: .save, brief: validHandoffBriefing, contextOnly: true)
      )
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.invalidArgument)
  }

  @Test func contextOnlySaveSkipsBriefingAndKeepsCurrentArtifact() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let store = HandoffStore(rootURL: root)
    try store.writeBriefing(validHandoffBriefing + "\n", archivingPrevious: false, now: fixedDate)
    let forkCalled = LockIsolated(false)
    let handler = makeHandler(
      root: root,
      outgoingAgent: "codex",
      forkSpy: { _, _ in
        forkCalled.setValue(true)
        return validHandoffBriefing
      }
    )

    let response = await handler.handle(
      envelope: envelope(HandoffInput(action: .save, contextOnly: true))
    )

    #expect(response.ok)
    #expect(forkCalled.value == false)
    let payload = try #require(try response.data?.decode(as: HandoffCommandPayload.self))
    #expect(payload.briefing == "none")
    #expect(payload.hasBriefing == false)
    // A context-only checkpoint never touches the last valid briefing.
    let current = try String(contentsOf: store.currentURL, encoding: .utf8)
    #expect(current == validHandoffBriefing + "\n")
  }

  @Test func saveMarksBriefingFailedForUnusableForkReply() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let handler = makeHandler(
      root: root,
      outgoingAgent: "codex",
      forkSpy: { _, _ in "I could not update the handoff file." }
    )

    let response = await handler.handle(envelope: envelope(HandoffInput(action: .save)))

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: HandoffCommandPayload.self))
    #expect(payload.briefing == "failed")
    #expect(payload.hasBriefing == false)
    // No briefing was ever written; a checkpoint failure leaves no artifact.
    #expect(!HandoffStore(rootURL: root).hasCurrentArtifact)
    let log = try String(contentsOf: HandoffStore(rootURL: root).logURL, encoding: .utf8)
    #expect(log.contains("briefing=failed"))
  }

  @Test func savePreservesResolvedNativeSessionContext() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let handler = makeHandler(
      root: root,
      outgoingAgent: "codex",
      sessionContext: HandoffStore.SessionContext(
        agent: "codex",
        sessionID: "native-session",
        paneID: "pane-0",
        paneTitle: "codex",
        source: "open_file",
        confidence: "exact",
        transcriptPath: "/tmp/native-session.jsonl",
        excerptText: "working on handoff"
      )
    )

    let response = await handler.handle(envelope: envelope(HandoffInput(action: .save)))

    let payload = try #require(try response.data?.decode(as: HandoffCommandPayload.self))
    let session = try #require(payload.sessionContext)
    #expect(session.sessionID == "native-session")
    #expect(session.source == "open_file")
    #expect(session.confidence == "exact")
    #expect(session.transcriptPath == "/tmp/native-session.jsonl")
  }

  // MARK: - fork request (fallback identity rules)

  @Test func forkRequiresVerifiableSourceSession() {
    let session = AgentSession(
      id: "ambiguous-session",
      transcriptPath: nil,
      source: .recentFile,
      confidence: .medium
    )

    #expect(
      HandoffCommandHandler.forkRequest(
        outgoingAgent: "codex",
        session: session,
        observation: AgentLaunchObservation(executionMode: .unrestricted)
      ) == nil
    )
  }

  @Test func forkRequestKeepsSameAdapterModelOnly() throws {
    let request = try #require(
      HandoffCommandHandler.forkRequest(
        outgoingAgent: "codex",
        session: AgentSession(
          id: "9B0E3B0E-67B3-4D45-A3A0-7DD9BC713711",
          transcriptPath: nil,
          source: .openFile,
          confidence: .high
        ),
        observation: AgentLaunchObservation(model: "gpt-5.4", executionMode: .unrestricted)
      )
    )

    #expect(request.agent == .codex)
    #expect(request.model == "gpt-5.4")
  }

  /// The fork prompt, the advertised section skeleton, and the validator must
  /// agree on the section names — drift in any one silently breaks validation.
  @Test func forkPromptSectionsAndValidatorAgree() {
    let prompt = HandoffCommandHandler.forkBriefingPrompt()
    for section in HandoffStore.briefingSections where section.hasPrefix("##") {
      #expect(prompt.contains("\"\(section)\""))
    }
    // A document with exactly the advertised sections passes validation.
    let document =
      "# Handoff\n\n"
      + HandoffStore.briefingSections.dropFirst().map { "\($0)\ncontent\n" }.joined(separator: "\n")
    #expect(HandoffStore.validatedBriefing(from: document) != nil)
  }

  /// Snapshot semantics: the fork prompt never embeds or references the
  /// previous artifact — the source writes a fresh document from its own
  /// session knowledge; history flows through the archive chain.
  @Test func forkPromptIsIndependentOfTheExistingArtifact() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let store = HandoffStore(rootURL: root)
    try store.writeBriefing(
      "# Handoff\n\n## Objective\nEarlier notes from a previous round.\n\n## Current State\nx\n\n## Next Steps\n1. y\n",
      archivingPrevious: false,
      now: fixedDate
    )
    let resumed = LockIsolated<AgentResumeRequest?>(nil)
    let handler = makeHandler(
      root: root,
      outgoingAgent: "codex",
      forkSpy: { request, _ in
        resumed.setValue(request)
        return "unusable"
      }
    )

    _ = await handler.handle(envelope: envelope(HandoffInput(action: .save)))

    let prompt = try #require(resumed.value?.prompt)
    #expect(prompt == HandoffCommandHandler.forkBriefingPrompt())
    #expect(!prompt.contains("Earlier notes from a previous round."))
  }

  // MARK: - to

  @Test func toArchivesOutgoingStateInstallsBriefingAndLaunches() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let store = HandoffStore(rootURL: root)
    let outgoing =
      "# Handoff\n\n## Objective\nOutgoing round to preserve.\n\n## Current State\nx\n\n## Next Steps\n1. y\n"
    try store.writeBriefing(outgoing, archivingPrevious: false, now: fixedDate)

    var launchedRequest: AgentStartRequest?
    let completions = LockIsolated<[HandoffCLICompletion]>([])
    let handler = makeHandler(
      root: root,
      outgoingAgent: "codex",
      launchSpy: { launchedRequest = $0 },
      completionSpy: { completion in completions.withValue { $0.append(completion) } }
    )

    let response = await handler.handle(
      envelope: envelope(
        HandoffInput(action: .toAgent, toAgent: "claude", note: "over to you", brief: validHandoffBriefing)
      )
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: HandoffCommandPayload.self))
    #expect(payload.action == .toAgent)
    #expect(payload.toAgent == "claude")
    #expect(payload.briefing == "inline")
    #expect(payload.archivedPath?.hasPrefix("handoff/archive/") == true)
    #expect(payload.launchedPane?.paneID == "pane-1")

    // The archive holds the *outgoing* round; current.md is the new briefing.
    let archiveURL = store.handoffDirectory.appending(
      path: try #require(payload.archivedPath).replacing("handoff/", with: "")
    )
    let archive = try String(contentsOf: archiveURL, encoding: .utf8)
    #expect(archive.contains("Outgoing round to preserve."))
    let current = try String(contentsOf: store.currentURL, encoding: .utf8)
    #expect(current == validHandoffBriefing + "\n")

    // The receiving adapter gets a semantic handoff prompt and only portable
    // source configuration. Cross-agent model identifiers must not leak.
    #expect(launchedRequest?.agent == .claude)
    #expect(launchedRequest?.configuration.model == nil)
    #expect(launchedRequest?.configuration.executionMode == .unrestricted)
    #expect(launchedRequest?.intent.promptText?.contains(".prowl/handoff/current.md") == true)

    // Log records the transition; the completion observer fired for the HUD.
    let log = try String(contentsOf: store.logURL, encoding: .utf8)
    #expect(log.contains("codex → claude"))
    #expect(log.contains("briefing=inline"))
    let completion = try #require(completions.value.first)
    #expect(completion.action == .toAgent)
    #expect(completion.sourcePaneID == handoffHandlerSourcePaneID.uuidString)
    #expect(completion.toAgent == "claude")
    #expect(completion.launched?.paneID == "pane-1")
  }

  @Test func profileTargetUsesFrozenProfileLaunchPlanAndReportsIdentity() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let selectedProfile = profile(model: "profile-model", reasoningEffort: "xhigh")
    let plan = LockIsolated<AgentProfileLaunchPlan?>(nil)
    let runtimeLaunchCalled = LockIsolated(false)
    let notifiedReceiver = LockIsolated<String?>(nil)
    let completions = LockIsolated<[HandoffCLICompletion]>([])
    let handler = makeHandler(
      root: root,
      outgoingAgent: "codex",
      outgoingLaunchObservation: AgentLaunchObservation(
        model: "outgoing-model",
        executionMode: .unrestricted
      ),
      launchSpy: { _ in runtimeLaunchCalled.setValue(true) },
      profiles: [selectedProfile],
      profileLaunchSpy: { plan.setValue($0) },
      notificationSpy: { notifiedReceiver.setValue($0) },
      completionSpy: { completion in completions.withValue { $0.append(completion) } }
    )

    let response = await handler.handle(
      envelope: envelope(
        HandoffInput(
          action: .toAgent,
          toProfileID: selectedProfile.id,
          brief: validHandoffBriefing
        )
      )
    )

    #expect(response.ok)
    #expect(runtimeLaunchCalled.value == false)
    let launchPlan = try #require(plan.value)
    #expect(launchPlan.profileID == selectedProfile.id)
    #expect(
      Array(launchPlan.invocation.arguments.prefix(6)) == [
        "--model", "profile-model", "-c", "model_reasoning_effort=xhigh", "-p", "work",
      ])
    #expect(launchPlan.invocation.arguments.last?.contains(".prowl/handoff/current.md") == true)
    #expect(launchPlan.surfaceEnvironment["PROWL_ENV_OPENAI_BASE_URL"] == "https://example.test/v1")
    #expect(launchPlan.dedicatedHome != nil)
    #expect(!launchPlan.terminalInput.contains("outgoing-model"))

    let payload = try #require(try response.data?.decode(as: HandoffCommandPayload.self))
    #expect(payload.toAgent == "codex")
    #expect(payload.toProfileID == selectedProfile.id)
    #expect(payload.toProfileName == selectedProfile.name)
    let completion = try #require(completions.value.first)
    #expect(completion.toProfileID == selectedProfile.id)
    #expect(completion.toProfileName == selectedProfile.name)
    #expect(completion.failureMessage == nil)
    #expect(completion.artifactsReady)
    #expect(notifiedReceiver.value == selectedProfile.name)
  }

  @Test func profileNoLaunchResolvesIdentityWithoutPlanningOrLaunching() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let selectedProfile = profile()
    let profileLaunchCalled = LockIsolated(false)
    let handler = makeHandler(
      root: root,
      outgoingAgent: "codex",
      profiles: [selectedProfile],
      profileLaunchSpy: { _ in profileLaunchCalled.setValue(true) }
    )

    let response = await handler.handle(
      envelope: envelope(
        HandoffInput(
          action: .toAgent,
          toProfileID: selectedProfile.id,
          launch: false,
          brief: validHandoffBriefing
        )
      )
    )

    #expect(response.ok)
    #expect(profileLaunchCalled.value == false)
    let payload = try #require(try response.data?.decode(as: HandoffCommandPayload.self))
    #expect(payload.toAgent == "codex")
    #expect(payload.toProfileID == selectedProfile.id)
    #expect(payload.toProfileName == selectedProfile.name)
    #expect(payload.launchedPane == nil)
  }

  @Test func missingProfileFailsBeforeArtifactMutationAndCompletesClaimedRequest() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let missingProfileID = UUID()
    let completions = LockIsolated<[HandoffCLICompletion]>([])
    let handler = makeHandler(
      root: root,
      outgoingAgent: "codex",
      completionSpy: { completion in completions.withValue { $0.append(completion) } }
    )

    let response = await handler.handle(
      envelope: envelope(
        HandoffInput(
          action: .toAgent,
          toProfileID: missingProfileID,
          brief: validHandoffBriefing,
          requestID: UUID()
        )
      )
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.invalidArgument)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".prowl").path(percentEncoded: false)))
    let completion = try #require(completions.value.first)
    #expect(completion.toProfileID == missingProfileID)
    #expect(completion.failureMessage != nil)
    #expect(completion.artifactsReady == false)
  }

  @Test func profileLaunchFailureKeepsArtifactsAndReportsTerminalCompletion() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let selectedProfile = profile(name: "Codex\n\"Work\"", bindsDedicatedHome: false)
    let completions = LockIsolated<[HandoffCLICompletion]>([])
    let handler = makeHandler(
      root: root,
      outgoingAgent: "codex",
      launched: nil,
      profiles: [selectedProfile],
      completionSpy: { completion in completions.withValue { $0.append(completion) } }
    )

    let response = await handler.handle(
      envelope: envelope(
        HandoffInput(
          action: .toAgent,
          toProfileID: selectedProfile.id,
          brief: validHandoffBriefing,
          requestID: UUID()
        )
      )
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.handoffFailed)
    #expect(HandoffStore(rootURL: root).hasCurrentArtifact)
    let completion = try #require(completions.value.first)
    #expect(completion.toProfileID == selectedProfile.id)
    #expect(completion.failureMessage?.contains("Progress was saved") == true)
    #expect(completion.artifactsReady)
    let log = try String(contentsOf: HandoffStore(rootURL: root).logURL, encoding: .utf8)
    #expect(log.contains("profile_id=\(selectedProfile.id.uuidString)"))
    #expect(log.contains("profile=\"Codex 'Work'\""))
    #expect(!log.contains("https://example.test"))
  }

  @Test func toWithFailedForkDegradesToContextOnlyAndRemovesStaleBriefing() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let store = HandoffStore(rootURL: root)
    let stale =
      "# Handoff\n\n## Objective\nStale round.\n\n## Current State\nx\n\n## Next Steps\n1. y\n"
    try store.writeBriefing(stale, archivingPrevious: false, now: fixedDate)

    var launchedRequest: AgentStartRequest?
    let handler = makeHandler(
      root: root,
      outgoingAgent: "codex",
      launchSpy: { launchedRequest = $0 },
      forkSpy: { _, _ in throw AgentRuntimeError.resumeTimedOut }
    )

    let response = await handler.handle(
      envelope: envelope(HandoffInput(action: .toAgent, toAgent: "claude"))
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: HandoffCommandPayload.self))
    #expect(payload.briefing == "failed")
    #expect(payload.hasBriefing == false)
    // The stale briefing was archived and removed — it must never impersonate
    // a fresh contract for the receiver.
    #expect(!store.hasCurrentArtifact)
    #expect(payload.archivedPath != nil)
    // The kickoff prompt points at context + archive, not current.md.
    let prompt = try #require(launchedRequest?.intent.promptText)
    #expect(!prompt.contains("current.md"))
    #expect(prompt.contains(".prowl/handoff/context.md"))
    let log = try String(contentsOf: store.logURL, encoding: .utf8)
    #expect(log.contains("briefing=failed"))
  }

  @Test func toWithoutLaunchSkipsAgentButArchives() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let store = HandoffStore(rootURL: root)
    try store.writeBriefing(validHandoffBriefing + "\n", archivingPrevious: false, now: fixedDate)

    var launchCalled = false
    let handler = makeHandler(
      root: root,
      outgoingAgent: "codex",
      launchSpy: { _ in launchCalled = true }
    )

    let response = await handler.handle(
      envelope: envelope(HandoffInput(action: .toAgent, toAgent: "codex", launch: false))
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: HandoffCommandPayload.self))
    #expect(payload.launchedPane == nil)
    #expect(payload.archivedPath != nil)
    #expect(launchCalled == false)
  }

  @Test func toAcceptsDetectedAgentToken() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let handler = makeHandler(root: root, outgoingAgent: "codex")

    let response = await handler.handle(
      envelope: envelope(HandoffInput(action: .toAgent, toAgent: "gemini", launch: false))
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: HandoffCommandPayload.self))
    #expect(payload.toAgent == "gemini")
  }

  @Test func toRejectsLaunchForAgentWithoutVerifiedLauncher() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let handler = makeHandler(root: root, outgoingAgent: "codex")

    let response = await handler.handle(
      envelope: envelope(HandoffInput(action: .toAgent, toAgent: "gemini"))
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.invalidArgument)
  }

  @Test func toRejectsUnknownAgent() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let handler = makeHandler(root: root, outgoingAgent: "codex")

    let response = await handler.handle(
      envelope: envelope(HandoffInput(action: .toAgent, toAgent: "unknown-agent"))
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.invalidArgument)
  }

  @Test func supportedAgentsMatchDetectedAgents() {
    #expect(HandoffAgentSupport.supportedAgents == DetectedAgent.allCases.map(\.rawValue))
  }

  @Test func toReportsFailureWhenLaunchReturnsNil() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let handler = makeHandler(root: root, outgoingAgent: "codex", launched: nil)

    let response = await handler.handle(
      envelope: envelope(HandoffInput(action: .toAgent, toAgent: "claude"))
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.handoffFailed)
    let log = try String(contentsOf: HandoffStore(rootURL: root).logURL, encoding: .utf8)
    #expect(log.contains("codex → claude"))
    #expect(log.contains("launch=failed"))
  }

  // MARK: - source resolution

  @Test func missingCallerPaneIsRejectedWithGuidance() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let handler = makeHandler(root: root, outgoingAgent: "codex", resolveFailure: .noCallerPane)

    let response = await handler.handle(envelope: envelope(HandoffInput(action: .save)))

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.sourceRequired)
    #expect(response.error?.message.contains("--pane") == true)
  }

  // MARK: - kickoff prompt

  @Test func kickoffPromptAdaptsToBriefingPresence() {
    let with = HandoffCommandHandler.kickoffPrompt(hasBriefing: true)
    #expect(with.contains(".prowl/handoff/current.md"))
    let without = HandoffCommandHandler.kickoffPrompt(hasBriefing: false)
    #expect(!without.contains("current.md"))
    #expect(without.contains(".prowl/handoff/context.md"))
    #expect(without.contains("archive/"))
  }
}
