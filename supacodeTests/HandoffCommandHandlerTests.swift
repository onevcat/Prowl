import ComposableArchitecture
import Foundation
import ProwlCLIShared
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

  private func makeHandler(
    root: URL,
    outgoingAgent: String?,
    outgoingLaunchObservation: AgentLaunchObservation? = AgentLaunchObservation(
      model: "gpt-5.4",
      executionMode: .unrestricted
    ),
    sessionContext: HandoffStore.SessionContext? = HandoffStore.SessionContext(
      agent: "codex",
      paneID: "pane-0",
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
    completionSpy: (@MainActor (HandoffCLICompletion) -> Void)? = nil,
    requestClaim: ((UUID) -> Bool)? = nil

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
            paneID: "pane-0",
            outgoingAgent: outgoingAgent,
            outgoingLaunchObservation: outgoingLaunchObservation,
            sessionContext: sessionContext
          )
        )
      },
      launchProvider: { _, request in
        launchSpy?(request)
        return launched
      },
      completionObserver: { completion in
        completionSpy?(completion)
      },
      requestAuthorizer: { requestID in
        requestClaim?(requestID) ?? true
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

  @Test func saveWithoutBriefIsRejectedWithGuidance() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let handler = makeHandler(root: root, outgoingAgent: "codex")

    let response = await handler.handle(envelope: envelope(HandoffInput(action: .save)))

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.briefRequired)
    #expect(response.error?.message.contains("--brief -") == true)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".prowl").path(percentEncoded: false)))
  }

  @Test func toWithoutBriefIsRejectedWithGuidance() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let handler = makeHandler(root: root, outgoingAgent: "claude")

    let response = await handler.handle(
      envelope: envelope(HandoffInput(action: .toAgent, toAgent: "codex"))
    )

    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.briefRequired)
    #expect(response.error?.message.contains("handoff to codex --brief -") == true)
    // Zero side effects: nothing was scaffolded or written.
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".prowl").path(percentEncoded: false)))
  }

  @Test func invalidInlineBriefIsRejectedWithZeroSideEffects() async throws {
    let root = try makeTempRoot()
    defer { remove(root) }
    let handler = makeHandler(root: root, outgoingAgent: "claude")

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
      requestClaim: { _ in false }

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
    let handler = makeHandler(root: root, outgoingAgent: "codex")

    let response = await handler.handle(
      envelope: envelope(HandoffInput(action: .save, contextOnly: true))
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: HandoffCommandPayload.self))
    #expect(payload.briefing == "none")
    #expect(payload.hasBriefing == false)
    // A context-only checkpoint never touches the last valid briefing.
    let current = try String(contentsOf: store.currentURL, encoding: .utf8)
    #expect(current == validHandoffBriefing + "\n")
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

    let response = await handler.handle(envelope: envelope(HandoffInput(action: .save, contextOnly: true)))

    let payload = try #require(try response.data?.decode(as: HandoffCommandPayload.self))
    let session = try #require(payload.sessionContext)
    #expect(session.sessionID == "native-session")
    #expect(session.source == "open_file")
    #expect(session.confidence == "exact")
    #expect(session.transcriptPath == "/tmp/native-session.jsonl")
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
    #expect(completion.sourcePaneID == "pane-0")
    #expect(completion.toAgent == "claude")
    #expect(completion.launched?.paneID == "pane-1")
  }

  @Test func toWithExplicitContextOnlyRemovesStaleBriefing() async throws {
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
      launchSpy: { launchedRequest = $0 }
    )

    let response = await handler.handle(
      envelope: envelope(HandoffInput(action: .toAgent, toAgent: "claude", contextOnly: true))
    )

    #expect(response.ok)
    let payload = try #require(try response.data?.decode(as: HandoffCommandPayload.self))
    #expect(payload.briefing == "none")
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
    #expect(log.contains("briefing=none"))
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
      envelope: envelope(HandoffInput(action: .toAgent, toAgent: "codex", launch: false, contextOnly: true))
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
      envelope: envelope(HandoffInput(action: .toAgent, toAgent: "gemini", launch: false, contextOnly: true))
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
      envelope: envelope(HandoffInput(action: .toAgent, toAgent: "claude", contextOnly: true))
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
