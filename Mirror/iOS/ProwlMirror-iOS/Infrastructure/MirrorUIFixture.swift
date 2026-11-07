#if DEBUG
  import Foundation

  /// Explicit UI-test launch only. Network and Host behavior are tested separately.
  @MainActor
  enum MirrorUIFixture {
    static func connectionSession() -> MirrorSession {
      let channel = Channel(name: "Launch fixture", longOutput: false)
      return MirrorSession(
        configuration: .init(address: "127.0.0.1", port: 7880, pairingKey: ""),
        makeTransport: { _ in channel })
    }

    static func launchCommand(_ command: MirrorCommandRequest.Command) async throws -> MirrorJSON {
      let payload: String
      switch command {
      case .agentsInput, .agentsDispatch, .send, .promptRespond, .agentKeys: throw CancellationError()
      case .list where CommandLine.arguments.contains("--mirror-ui-roster-fixture"):
        // The roster fixture's projects, with the pane IDs of `rosterPanes`.
        payload =
          #"{"ok":true,"data":{"items":[{"pane":{"id":"A1000000-0000-0000-0000-000000000004"},"worktree":{"id":"/demo/Prowl/","name":"main","path":"/demo/Prowl/","root_path":"/demo/Prowl/"}},{"pane":{"id":"A1000000-0000-0000-0000-000000000003"},"worktree":{"id":"/demo/Prowl-mirror/","name":"feat/mirror-ios","path":"/demo/Prowl-mirror/","root_path":"/demo/Prowl/"}},{"pane":{"id":"A1000000-0000-0000-0000-000000000001"},"worktree":{"id":"/demo/Kingfisher/","name":"main","path":"/demo/Kingfisher/","root_path":"/demo/Kingfisher/"}},{"pane":{"id":"A1000000-0000-0000-0000-000000000002"},"worktree":{"id":"/demo/Kingfisher-8.4/","name":"release/8.4","path":"/demo/Kingfisher-8.4/","root_path":"/demo/Kingfisher/"}},{"pane":{"id":"A1000000-0000-0000-0000-000000000007"},"worktree":{"id":"/demo/FengNiao/","name":"main","path":"/demo/FengNiao/","root_path":"/demo/FengNiao/"}}]}}"#
      case .list:
        payload =
          #"{"ok":true,"data":{"items":[{"worktree":{"id":"fixture-worktree","name":"main","path":"/Projects/Prowl","root_path":"/Projects/Prowl"}}]}}"#
      case .profiles where CommandLine.arguments.contains("--mirror-ui-roster-fixture"):
        payload =
          #"{"ok":true,"data":{"profiles":[{"id":"opus","name":"Claude Code Opus","enabled":true,"runtime":"claude","availability":{"status":"available"},"model":"claude-opus-5-5","reasoning_effort":"high"},{"id":"luna","name":"Luna","enabled":true,"runtime":"codex","availability":{"status":"available"},"model":"gpt-6-luna","reasoning_effort":"xhigh","icon":"paperplane.fill"},{"id":"pi","name":"Pi Reviewer","enabled":true,"runtime":"pi","availability":{"status":"unavailable","reason":"pi is not on your shell's PATH"}}]}}"#
      case .profiles:
        payload =
          #"{"ok":true,"data":{"profiles":[{"id":"fixture-profile","name":"Codex","enabled":true,"runtime":"codex","availability":{"status":"available"}}]}}"#
      case .create:
        payload =
          #"{"ok":true,"data":{"target":{"worktree":{"id":"fixture-worktree","name":"main","path":"/Projects/Prowl","root_path":"/Projects/Prowl"},"pane":{"id":"03F5535A-D08C-498C-B70B-C665AC8D02CB","title":"Codex"}}}}"#
      }
      return try JSONDecoder().decode(MirrorJSON.self, from: Data(payload.utf8))
    }

    /// With `--mirror-ui-scroll-hold-fixture`, the fixture Host confirms a scroll only when the UI
    /// test posts this Darwin notification, so the test can check the loading state at any speed.
    static let releaseScrollNotification = "com.onevcat.prowl.mirror.ui-fixture.release-scroll"
    private static var holdsScroll: Bool {
      CommandLine.arguments.contains("--mirror-ui-scroll-hold-fixture")
    }

    /// Every fixture pane has this ID so the roster, the pane screen and UI tests agree on it.
    static let paneID = UUID(uuidString: "0F1C2D3E-4A5B-6C7D-8E9F-A0B1C2D3E4F5")!

    /// The agent whose bundled conversation `--mirror-ui-conversation-fixture [agent]` replays.
    static var conversationFixtureAgent: String? {
      let arguments = CommandLine.arguments
      guard let index = arguments.firstIndex(of: "--mirror-ui-conversation-fixture") else { return nil }
      let next = index + 1 < arguments.count ? arguments[index + 1] : ""
      return next.isEmpty || next.hasPrefix("--") ? "claude" : next
    }

    struct Hosts {
      let store: MirrorHostStore
      let sessions: MirrorHostSessions
    }

    /// `--mirror-ui-connection-fixture`: one paired Host whose roster and panes come from fake
    /// transports, so the Hosts → panes → pane flow runs without a network.
    static func hostsFixture() -> Hosts? {
      guard CommandLine.arguments.contains("--mirror-ui-connection-fixture") else { return nil }
      let suite = "ui-fixture-hosts"
      let defaults = UserDefaults(suiteName: suite) ?? .standard
      defaults.removePersistentDomain(forName: suite)
      let store = MirrorHostStore(defaults: defaults, adoptsLegacyConnection: false)
      if !CommandLine.arguments.contains("--mirror-ui-onboarding-fixture") {
        _ = store.upsert(address: "127.0.0.1", port: 7880, hostID: nil)
      }
      let sessions = MirrorHostSessions(
        makeSession: { MirrorHostSession(configuration: $0.configuration, makeTransport: { _ in channel() }) },
        makePaneSession: { MirrorSession(configuration: $0.configuration, makeTransport: { _ in channel() }) })
      return Hosts(store: store, sessions: sessions)
    }

    /// The pane screen the fixture arguments open directly, or nil to run the real app.
    static func paneFixture() -> (session: MirrorSession, pane: MirrorPaneDescriptor)? {
      let arguments = CommandLine.arguments
      guard arguments.contains("--mirror-ui-fixture") || conversationFixtureAgent != nil else { return nil }
      let channel = channel()
      let session = MirrorSession(
        configuration: .init(address: "127.0.0.1", port: 7880, pairingKey: ""), makeTransport: { _ in channel })
      session.open(channel.pane, mode: channel.conversation.isEmpty ? .screen : .conversation)
      return (session, channel.pane)
    }

    /// Replays a bundled `conversation-v1` event file through a fake Host.
    static func conversationSession(
      fixture: String, agent: String, clock: any Clock<Duration> = ContinuousClock(),
      status: MirrorConversationEvent.AgentState? = nil
    ) -> MirrorSession {
      let channel = Channel(name: "Review PR #1038", longOutput: false)
      var events = Self.fixtureEvents(named: fixture)
      if let status {
        events.append(
          .init(.agentStatus, .status(.init(state: status)), at: nil, source: .osc,
            sequence: (events.last?.sequence ?? 0) + 1))
      }
      channel.conversation = events
      channel.agent = agent
      let session = MirrorSession(
        configuration: .init(address: "127.0.0.1", port: 7880, pairingKey: ""), clock: clock,
        makeTransport: { _ in channel })
      session.open(channel.pane, mode: .conversation)
      return session
    }

    /// A fake Host for the current fixture arguments: the conversation fixture when one is named,
    /// otherwise the terminal fixture (long output with `--mirror-ui-multiple-fixtures`).
    private static func channel() -> Channel {
      let longOutput = CommandLine.arguments.contains("--mirror-ui-multiple-fixtures")
      guard let agent = conversationFixtureAgent else { return Channel(name: "UI Fixture", longOutput: longOutput) }
      let channel = Channel(name: "Review PR #1038", longOutput: longOutput)
      var events = fixtureEvents(named: "\(agent)-review-1038")
      // `--mirror-ui-running-tool-fixture`: the agent works and its last tool call still runs.
      if CommandLine.arguments.contains("--mirror-ui-running-tool-fixture"), let last = events.last {
        let start = MirrorConversationEvent.ToolStart(
          id: "fixture-running", name: "Bash", kind: .shell, title: "Run the mirror tests",
          command: "make test-mirror-ios-unit")
        events.append(.init(.toolStarted, .toolStart(start), at: Date(), source: .transcript, sequence: last.sequence + 1))
        events.append(
          .init(.agentStatus, .status(.init(state: .working)), at: Date(), source: .osc, sequence: last.sequence + 2))
      }
      channel.conversation = events
      channel.agent = agent
      if CommandLine.arguments.contains("--mirror-ui-running-tool-fixture") { channel.setAgentState(.working) }
      return channel
    }

    /// `--mirror-ui-roster-fixture`: more panes in two projects and every state, so the Agents
    /// screen has something to show (docs-ai 089). They open the main fixture conversation.
    static var rosterPanes: [MirrorPaneDescriptor] {
      guard CommandLine.arguments.contains("--mirror-ui-roster-fixture") else { return [] }
      let now = Date()
      func pane(
        _ id: String, _ tab: String, project: String, color: String, order: Int, agent: String?,
        state: MirrorPaneDescriptor.DisplayState?, minutes: Double, worktree: String = "main"
      ) -> MirrorPaneDescriptor {
        var pane = MirrorPaneDescriptor(
          id: UUID(uuidString: id)!, title: "\(project) · \(tab) · \(worktree)", directory: "/demo/\(project)",
          busy: false, projectName: project, subtitle: "\(tab) · \(worktree)", agent: agent,
          agentState: state.map { $0 == .done ? .idle : MirrorConversationEvent.AgentState(rawValue: $0.rawValue)! },
          conversation: agent == nil ? .unsupported : .available)
        pane.displayState = state
        pane.stateChangedAt = MirrorConversationEvent.formatTimestamp(now.addingTimeInterval(-minutes * 60))
        pane.tabTitle = tab
        pane.worktreeName = worktree
        pane.repositoryColor = color
        pane.projectOrder = order
        return pane
      }
      return [
        pane("A1000000-0000-0000-0000-000000000001", "Fix flaky prefetch test", project: "Kingfisher",
          color: "blue", order: 1, agent: "claude", state: .blocked, minutes: 2),
        pane("A1000000-0000-0000-0000-000000000002", "Draft 8.4 release notes", project: "Kingfisher",
          color: "blue", order: 1, agent: "codex", state: .done, minutes: 6, worktree: "release/8.4"),
        pane("A1000000-0000-0000-0000-000000000003", "Mirror iOS redesign", project: "Prowl", color: "mint",
          order: 0, agent: "claude", state: .working, minutes: 1, worktree: "feat/mirror-ios"),
        pane("A1000000-0000-0000-0000-000000000004", "Review sidebar groups", project: "Prowl", color: "mint",
          order: 0, agent: "pi", state: .idle, minutes: 40),
        pane("A1000000-0000-0000-0000-000000000005", "zsh", project: "Prowl", color: "mint",
          order: 0, agent: nil, state: nil, minutes: 90),
        pane("A1000000-0000-0000-0000-000000000006", "swift test", project: "Kingfisher", color: "blue",
          order: 1, agent: nil, state: nil, minutes: 30),
        pane("A1000000-0000-0000-0000-000000000007", "Scan unused images", project: "FengNiao", color: "purple",
          order: 2, agent: "codex", state: .working, minutes: 3),
      ]
    }

    static func fixtureEvents(named name: String) -> [MirrorConversationEvent] {
      guard let url = Bundle.main.url(forResource: name, withExtension: "events.jsonl"),
        let text = try? String(contentsOf: url, encoding: .utf8)
      else { return [] }
      return text.split(separator: "\n").compactMap { line in
        try? JSONDecoder().decode(MirrorConversationEvent.self, from: Data(line.utf8))
      }
    }

    static func session(name: String = "UI Fixture", longOutput: Bool = false) -> MirrorSession {
      let channel = Channel(name: name, longOutput: longOutput)
      let session = MirrorSession(
        configuration: .init(
          address: "127.0.0.1", port: 7880, pairingKey: ""),
        scrollConfirmationTimeout: holdsScroll ? .seconds(120) : .seconds(5),
        makeTransport: { _ in channel })
      session.connect()
      session.select(channel.pane)
      return session
    }

    private final class Channel: MirrorTransport {
      var onReady: (() -> Void)?
      var onMessage: ((MirrorMessage) -> Void)?
      var onClose: ((String?) -> Void)?
      private(set) var pane: MirrorPaneDescriptor
      let longOutput: Bool
      /// Events for a `conversation-v1` subscription; the pane advertises the conversation when set.
      var conversation: [MirrorConversationEvent] = [] {
        didSet {
          pane.conversation = conversation.isEmpty ? .unsupported : .available
          pane.agentState = .idle
        }
      }
      func setAgentState(_ state: MirrorConversationEvent.AgentState) { pane.agentState = state }
      var agent = "codex" {
        didSet {
          pane.agent = agent
          let label = agent == "claude" ? "Claude Code" : agent.capitalized
          pane = MirrorPaneDescriptor(
            id: pane.id, title: "\(pane.projectName ?? "") · \(label)", directory: pane.directory, busy: false,
            projectName: pane.projectName, subtitle: "\(label) · main", agent: agent, agentState: pane.agentState,
            conversation: pane.conversation)
        }
      }
      init(name: String, longOutput: Bool) {
        self.longOutput = longOutput
        pane = MirrorPaneDescriptor(
          id: MirrorUIFixture.paneID, title: "\(name) · Codex", directory: "/fixture", busy: false,
          projectName: name, subtitle: "Codex · main", agent: "codex",
          agentState: CommandLine.arguments.contains("--mirror-ui-working-fixture") ? .working : nil)
        if MirrorUIFixture.holdsScroll {
          CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
              guard let observer else { return }
              let channel = Unmanaged<Channel>.fromOpaque(observer).takeUnretainedValue()
              Task { @MainActor in channel.releaseHeldScrolls() }
            },
            MirrorUIFixture.releaseScrollNotification as CFString, nil, .deliverImmediately)
        }
      }
      deinit {
        CFNotificationCenterRemoveEveryObserver(
          CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
      }
      private let lease = UUID()
      private let run = UUID()
      private let history = MirrorHistory(
        text: (1...401).map { "Retained line \($0)" }.joined(separator: "\n"), truncated: true)
      private var sequence: UInt64 = 0
      private var scrollPage = 0
      private var heldScrolls: [MirrorMessage] = []
      private var includesScrollState = false

      func start() { onReady?() }
      func close(_ reason: String?) {
        heldScrolls = []
        onClose?(reason)
      }

      func send(_ message: MirrorMessage, closeAfterSending: Bool) {
        switch message.kind {
        case .list:
          onMessage?(
            .panes(
              .init(
                panes: [pane] + MirrorUIFixture.rosterPanes,
                capabilities: [
                  "text-v1", "history", "refresh", "launch-profile", "agents-dispatch", "agent-input",
                  "shell-send", "agent-keys", "shell-keys",
                ] + (conversation.isEmpty ? [] : ["conversation-v1"])
                  + (CommandLine.arguments.contains("--mirror-ui-no-scroll-fixture") ? [] : ["remote-scroll"])
                  + (CommandLine.arguments.contains("--mirror-ui-scroll-boundary-fixture") ? ["scroll-state-v1"] : []),
                hostRunID: UUID(), hostName: "onevcat’s MacBook Pro")))
        case .subscribe:
          if case .subscribe(let payload) = message { includesScrollState = payload.includeScrollState == true }
          onMessage?(
            .subscribed(.init(paneID: message.paneID ?? pane.id, subscriptionID: lease, hostRunID: run)))
          if message.representation == .conversation {
            let since = message.since ?? 0
            let events = conversation.filter { $0.sequence > since }
            let session = conversation.last { $0.kind == .sessionStarted }.flatMap {
              event -> MirrorConversationEvent.Session? in
              if case .session(let value) = event.payload { return value }
              return nil
            }
            // `--mirror-ui-slow-snapshot`: as over a real network, the snapshot arrives late with the
            // first half, and the rest follows as event batches.
            if CommandLine.arguments.contains("--mirror-ui-slow-snapshot"), events.count > 8 {
              let first = Array(events.prefix(events.count / 2))
              let rest = Array(events.dropFirst(events.count / 2))
              let lease = lease
              Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                self?.onMessage?(
                  .conversationSnapshot(
                    .init(
                      events: first, gap: false, sequence: first.last?.sequence ?? 0, subscriptionID: lease,
                      session: session)))
                for batch in stride(from: 0, to: rest.count, by: max(1, rest.count / 4)) {
                  try? await Task.sleep(for: .milliseconds(250))
                  let slice = Array(rest[batch..<min(rest.count, batch + max(1, rest.count / 4))])
                  self?.onMessage?(
                    .conversationEvents(
                      .init(events: slice, sequence: slice.last?.sequence ?? 0, subscriptionID: lease)))
                }
              }
              return
            }
            onMessage?(
              .conversationSnapshot(
                .init(
                  events: events, gap: false, sequence: conversation.last?.sequence ?? 0, subscriptionID: lease,
                  session: session)))
            return
          }
          frame()
        case .command:
          guard let request = message.commandRequest else { return }
          if CommandLine.arguments.contains("--mirror-ui-connection-fixture") {
            Task {
              do {
                let response = try await MirrorUIFixture.launchCommand(request.request.command)
                onMessage?(
                  .commandResult(
                    .init(
                      commandResponse: .init(
                        requestID: request.requestID, response: response))))
              } catch { onClose?(error.localizedDescription) }
            }
            return
          }
          let payload: MirrorJSON
          switch request.request.command {
          case .list:
            payload = .object([
              "ok": .bool(true),
              "data": .object([
                "items": .array([
                  .object([
                    "pane": .object(["id": .string(pane.id.uuidString), "agent": .string("codex")]),
                    "task": .object(["status": .string("idle")]),
                  ])
                ])
              ]),
            ])
          case .agentKeys where CommandLine.arguments.contains("--mirror-ui-refuse-keys"):
            payload = .object([
              "ok": .bool(false), "command": .string("agent.keys"),
              "error": .object([
                "code": .string("KEYS_REFUSED"), "message": .string("Someone is typing in this pane on the Mac."),
              ]),
            ])
          case .agentKeys(let input):
            payload = .object([
              "ok": .bool(true), "command": .string("agent.keys"),
              "data": .object(["keys": .array(input.keys.map { .string($0) })]),
            ])
          case .agentsInput where CommandLine.arguments.contains("--mirror-ui-hold-input"):
            // No receipt: the message stays in flight, so a test can check the sending state.
            return
          case .agentsInput(let input) where CommandLine.arguments.contains("--mirror-ui-refuse-input-draft"):
            // The Mac's input box holds a draft (docs-ai 090): refused until the message asks to
            // replace it, then delivered with the stashed draft in the receipt.
            if input.onDraft == "replace" {
              payload = .object([
                "ok": .bool(true), "command": .string("agents.input"),
                "data": .object([
                  "input": .object([
                    "bytes": .number(Double(input.prompt.utf8.count)), "trailing_enter_sent": .bool(true),
                    "replaced_draft": .object([
                      "text": .string("review the tests"), "is_complete": .bool(true), "recovery": .string("stash"),
                    ]),
                  ])
                ]),
              ])
            } else {
              payload = .object([
                "ok": .bool(false), "command": .string("agents.input"),
                "error": .object([
                  "code": .string("DISPATCH_TARGET_BUSY"),
                  "message": .string(
                    "Claude has an existing draft or attachment (“review the tests”). Clear it on Host before dispatching."),
                  "details": .object([
                    "input": .object([
                      "reason": .string("draft"),
                      "draft": .object(["text": .string("review the tests"), "is_complete": .bool(true)]),
                      "replaceable": .bool(true), "recovery": .string("stash"),
                    ])
                  ]),
                ]),
              ])
            }
          case .agentsInput where CommandLine.arguments.contains("--mirror-ui-refuse-input"):
            payload = .object([
              "ok": .bool(false), "command": .string("agents.input"),
              "error": .object([
                "code": .string("INPUT_NOT_READY"),
                "message": .string(
                  "Claude has an existing draft or attachment in its input box: \"review the tests\". Clear it on the Mac, or send it there, then try again."
                ),
              ]),
            ])
          case .agentsInput(let input):
            payload = .object([
              "ok": .bool(true), "command": .string("agents.input"),
              "data": .object([
                "input": .object([
                  "bytes": .number(Double(input.prompt.utf8.count)), "trailing_enter_sent": .bool(true),
                ])
              ]),
            ])
          default:
            onClose?("Unexpected fixture command")
            return
          }
          onMessage?(
            .commandResult(
              .init(commandResponse: .init(requestID: request.requestID, response: payload))))
        case .refresh: frame()
        case .scroll:
          scroll(message)
        case .history:
          do {
            let page = try history.page(before: message.offset ?? history.lines.count)
            onMessage?(
              .historyPage(
                .init(
                  historyID: history.id, offset: page.start, lines: page.lines,
                  total: history.lines.count, subscriptionID: lease, capturedAt: history.capturedAt,
                  truncated: history.truncated)))
          } catch { onClose?(error.localizedDescription) }
        case .acknowledge: break
        default: onClose?("Unexpected fixture request")
        }
      }

      private func scroll(_ message: MirrorMessage) {
        if MirrorUIFixture.holdsScroll {
          heldScrolls.append(message)
        } else {
          completeScroll(message)
        }
      }

      private func releaseHeldScrolls() {
        let scrolls = heldScrolls
        heldScrolls = []
        scrolls.forEach(completeScroll)
      }

      private func completeScroll(_ message: MirrorMessage) {
        guard let id = message.scrollRequestID, let direction = message.scrollDirection else { return }
        scrollPage += direction == .upward ? -1 : 1
        if includesScrollState { scrollPage = min(0, max(-2, scrollPage)) }
        frame()
        onMessage?(.scrollResult(.init(requestID: id, sequence: sequence, subscriptionID: lease)))
      }

      private func frame() {
        sequence += 1
        if includesScrollState {
          onMessage?(
            .scrollState(
              .init(atTop: scrollPage == -2, atBottom: scrollPage == 0, sequence: sequence, subscriptionID: lease)))
        }
        if CommandLine.arguments.contains("--mirror-ui-scroll-fixture") {
          let text =
            CommandLine.arguments.contains("--mirror-ui-scroll-long-fixture")
            ? (1...40).map { "```text\nRemote \(scrollPage) marker \($0)\n```" }.joined(separator: "\n")
            : "Remote page \(scrollPage)\nUse the buttons above to scroll the Host."
          onMessage?(
            .textFrame(
              .init(
                sequence: sequence, text: text,
                subscriptionID: lease)))
          return
        }
        if CommandLine.arguments.contains("--mirror-ui-large-table-fixture") {
          let rows = (0..<10_000).map { "| Row \($0) | Value \($0) |" }.joined(separator: "\n")
          onMessage?(
            .textFrame(
              .init(
                sequence: sequence, text: "| Index | Value |\n| --- | --- |\n" + rows,
                subscriptionID: lease)))
          return
        }
        let extra =
          longOutput
          ? (1...40).map { "\n```text\nLive marker \($0)\n```" }.joined() : ""
        onMessage?(
          .textFrame(
            .init(
              sequence: sequence,
              text: """
                **Live output**
                正在分析代码，当前内容可以复制。

                ```swift
                let greeting = "Hello iPad"
                print(greeting)
                ```

                | Platform | Status |
                | --- | --- |
                | iPad | Reading |
                | macOS | Host |
                """ + extra, subscriptionID: lease)))
      }
    }
  }
#endif
