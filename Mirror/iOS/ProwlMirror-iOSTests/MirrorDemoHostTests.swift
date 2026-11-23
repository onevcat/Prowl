import Foundation
import Testing

@testable import ProwlMirror_iOS

/// The demo Host (docs-ai 098) drives the app's real sessions, so these tests use them too.
@MainActor
struct MirrorDemoHostTests {
  typealias PaneID = MirrorDemoContent.PaneID

  @Test(.timeLimit(.minutes(1))) func rosterShowsEveryStateWithoutPush() async {
    let host = MirrorDemoHost(clock: DemoImmediateClock())
    let session = MirrorHostSession(
      configuration: .init(address: "demo.invalid", port: 7880, pairingKey: ""),
      makeTransport: { _ in host.makeTransport() })
    defer { session.stop() }
    session.start()
    await settle { session.status == .ready }

    let states = Dictionary(session.panes.map { ($0.id, MirrorPaneState($0)) }, uniquingKeysWith: { first, _ in first })
    #expect(states[PaneID.blocked] == .blocked)
    #expect(states[PaneID.working] == .working)
    #expect(states[PaneID.done] == .done)
    #expect(states[PaneID.idle] == .idle)
    #expect(states[PaneID.prowlShell] == .terminal)
    #expect(session.hostName == "Demo Mac")
    #expect(session.supportsLaunch)
    #expect(session.supportsPush == false)
  }

  @Test(.timeLimit(.minutes(1))) func answeringThePermissionLetsTheAgentFinish() async {
    let host = MirrorDemoHost(clock: DemoImmediateClock())
    let session = paneSession(host, PaneID.blocked, mode: .conversation)
    defer { session.disconnect() }
    await settle { session.conversation.openScreenPrompt != nil }
    #expect(session.agentState == .blocked)
    #expect(session.conversation.openScreenPrompt?.id == MirrorDemoContent.blockedPromptID)

    session.answerPrompt(MirrorDemoContent.blockedPromptID, choice: "1")
    await settle { session.agentState == .idle }

    #expect(session.promptAnswer?.state == .delivered)
    #expect(session.conversation.openScreenPrompt == nil)
    #expect(host.pane(PaneID.blocked)?.descriptor.displayState == .done)
    #expect(host.pane(PaneID.blocked)?.prompt == nil)
    let resolved = session.conversation.events.last { $0.kind == .promptResolved }
    if case .prompt(let prompt)? = resolved?.payload { #expect(prompt.outcome == .allowed) }
  }

  @Test(.timeLimit(.minutes(1))) func escapeDeclinesTheOpenPrompt() async {
    let host = MirrorDemoHost(clock: DemoImmediateClock())
    let session = paneSession(host, PaneID.blocked, mode: .screen)
    defer { session.disconnect() }
    await settle { session.screenPrompt != nil }
    #expect(session.text.contains("Do you want to proceed?"))

    session.sendKeys(["esc"])
    await settle { host.pane(PaneID.blocked)?.descriptor.agentState == .idle }

    let resolved = host.pane(PaneID.blocked)?.events.last { $0.kind == .promptResolved }
    if case .prompt(let prompt)? = resolved?.payload { #expect(prompt.outcome == .denied) }
    await settle { session.screenPrompt == nil }
    #expect(session.keyRefusal == nil)
  }

  @Test(.timeLimit(.minutes(1))) func aMessageGetsTheDemoReply() async {
    let host = MirrorDemoHost(clock: DemoImmediateClock())
    let session = paneSession(host, PaneID.done, mode: .conversation)
    defer { session.disconnect() }
    await settle { session.status == .live }

    session.draft = "Add them to the changelog."
    session.submitDraft()
    await settle { session.submission?.outcome.status == .accepted }
    await settle { session.agentState == .idle && session.conversation.items.count > 0 }
    await settle {
      session.conversation.events.contains {
        if case .message(let message) = $0.payload, $0.kind == .assistantMessage {
          return message.text.text.hasPrefix("This is the demo")
        }
        return false
      }
    }
    #expect(
      session.conversation.events.contains {
        if case .message(let message) = $0.payload, $0.kind == .userMessage {
          return message.text.text == "Add them to the changelog."
        }
        return false
      })
    #expect(session.draft.isEmpty)
  }

  @Test(.timeLimit(.minutes(1))) func blockedAgentRefusesAMessage() {
    let host = MirrorDemoHost(clock: DemoImmediateClock())
    let response = host.run(.agentsInput(.init(pane: PaneID.blocked.uuidString, prompt: "hello")))
    #expect(response.object?["ok"] == .bool(false))
    #expect(host.pane(PaneID.blocked)?.descriptor.agentState == .blocked)
  }

  @Test(.timeLimit(.minutes(1))) func stopInterruptsTheWorkingAgent() async {
    // The scan runs until the clock advances, which it never does here.
    let clock = HostTestClock()
    let host = MirrorDemoHost(clock: clock)
    host.start()
    defer { host.stop() }
    let session = paneSession(host, PaneID.working, mode: .conversation)
    defer { session.disconnect() }
    await settle { session.status == .live }
    #expect(session.agentState == .working)
    #expect(session.canStopAgent)

    session.sendKeys(["esc"])
    await settle { session.agentState == .idle }

    let events = session.conversation.events
    #expect(
      events.contains {
        if case .toolEnd(let end) = $0.payload { return end.status == .interrupted } else { return false }
      })
    #expect(
      events.contains { if case .turn(let turn) = $0.payload { return turn.status == .aborted } else { return false } })
  }

  @Test(.timeLimit(.minutes(1))) func newSessionStartsTheAgentWithTheFirstMessage() async throws {
    let host = MirrorDemoHost(clock: DemoImmediateClock())
    let worktree = try #require(host.pane(PaneID.idle)?.worktree)
    let response = host.run(
      .create(.init(worktreeID: worktree.id, profileID: "codex", prompt: "Update the README.")))
    #expect(response.object?["ok"] == .bool(true))
    let created = try #require(host.panes.last)
    #expect(created.descriptor.agent == "codex")
    #expect(created.descriptor.projectName == "Prowl")
    #expect(created.descriptor.conversation == .available)
    await settle { host.panes.last?.descriptor.agentState == .idle && (host.panes.last?.events.count ?? 0) > 3 }
    #expect(
      host.panes.last?.events.contains {
        if case .message(let message) = $0.payload, $0.kind == .userMessage {
          return message.text.text == "Update the README."
        }
        return false
      } == true)
  }

  @Test(.timeLimit(.minutes(1))) func shellCommandShowsOnTheScreenWithoutRunning() async {
    let host = MirrorDemoHost(clock: DemoImmediateClock())
    let session = paneSession(host, PaneID.prowlShell, mode: .screen)
    defer { session.disconnect() }
    await settle { session.status == .live }

    session.draft = "ls"
    session.submitDraft()
    await settle { session.submission?.outcome.status == .accepted }
    await settle { session.text.contains("Commands do not run in the demo") }
    #expect(session.text.contains("❯ ls"))
  }

  @Test(.timeLimit(.minutes(1))) func terminalHistoryPagesTheSession() async {
    let host = MirrorDemoHost(clock: DemoImmediateClock())
    let session = paneSession(host, PaneID.idle, mode: .screen)
    defer { session.disconnect() }
    await settle { session.status == .live }
    session.loadHistory()
    await settle { !session.isLoadingHistory && !session.historyLines.isEmpty }
    #expect(session.historyLines.contains { $0.contains("Review the sidebar groups change") })
  }

  @Test func demoKeepsNothingAfterItEnds() throws {
    let demo = MirrorDemo(host: MirrorDemoHost(clock: DemoImmediateClock()))
    let host = try #require(demo.store.selectedHost)
    #expect(demo.store.hosts.count == 1)
    #expect(host.displayName == "Demo Mac")
    #expect(host.configuration.credential == nil)
    demo.end()
    let defaults = UserDefaults(suiteName: MirrorDemo.defaultsSuite)
    #expect(defaults?.data(forKey: MirrorHostStore.defaultsKey) == nil)
  }

  // MARK: - Helpers

  private func paneSession(_ host: MirrorDemoHost, _ id: UUID, mode: MirrorSession.Mode) -> MirrorSession {
    let session = MirrorSession(
      configuration: .init(address: "demo.invalid", port: 7880, pairingKey: ""),
      makeTransport: { _ in host.makeTransport() })
    session.open(host.pane(id)!.descriptor, mode: mode)
    return session
  }

  /// Lets main-actor work run until `predicate` holds. The demo Host is not observable, so this
  /// yields instead of tracking changes; every demo step runs on the main actor.
  private func settle(_ predicate: () -> Bool) async {
    for _ in 0..<10_000 {
      if predicate() { return }
      await Task.yield()
    }
    Issue.record("The condition did not hold")
  }
}

/// A clock whose sleeps end at once, so demo scripts run straight through.
nonisolated struct DemoImmediateClock: Clock {
  let now = ContinuousClock.now
  let minimumResolution = Duration.zero
  func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
    try Task.checkCancellation()
    await Task.yield()
    try Task.checkCancellation()
  }
}

extension MirrorJSON {
  fileprivate var object: [String: MirrorJSON]? {
    if case .object(let value) = self { return value }
    return nil
  }
}
