import Foundation

/// What the demo Mac holds (docs-ai 098): agent and shell panes on our own projects, in every
/// state the app shows, with the scripts that answers, messages and Stop play. The text is the
/// agents' output, so it stays English like real agent output.
nonisolated struct MirrorDemoContent: Sendable {
  var hostName: String
  var panes: [Pane]
  var profiles: [Profile]

  /// Events that arrive after `delay`, in one batch.
  struct Step: Sendable {
    var delay: Duration
    var events: [MirrorConversationEvent]

    init(after delay: Duration, _ events: [MirrorConversationEvent]) {
      self.delay = delay
      self.events = events
    }
  }

  struct Worktree: Sendable {
    var name: String
    var path: String
    var rootPath: String

    var id: String { path }
    var json: MirrorJSON {
      .object(["id": .string(id), "name": .string(name), "path": .string(path), "root_path": .string(rootPath)])
    }
  }

  struct Profile: Sendable {
    var id: String
    var name: String
    var runtime: String

    var json: MirrorJSON {
      .object([
        "id": .string(id), "name": .string(name), "enabled": .bool(true), "runtime": .string(runtime),
        "availability": .object(["status": .string("available")]),
      ])
    }
  }

  // MARK: - Pane

  struct Pane: Sendable {
    var descriptor: MirrorPaneDescriptor
    var worktree: Worktree
    private(set) var events: [MirrorConversationEvent] = []
    private(set) var latestSequence: UInt64 = 0
    /// The menu on the screen that a phone can answer, while it is open.
    private(set) var prompt: MirrorConversationEvent.Prompt?
    /// The scripts that follow an answer, by choice id; `*` for any other choice.
    var answers: [String: [Step]] = [:]
    /// Work that plays from the start of the demo without input.
    var autoplay: [Step] = []
    /// A shell pane's screen.
    private(set) var shellLines: [String] = []

    var agentName: String {
      switch descriptor.agent {
      case "claude": "Claude Code"
      case "codex": "Codex"
      case let agent?: agent.capitalized
      case nil: "Shell"
      }
    }

    var session: MirrorConversationEvent.Session? {
      events.last { $0.kind == .sessionStarted }.flatMap {
        if case .session(let session) = $0.payload { return session }
        return nil
      }
    }

    init(
      id: UUID, tab: String, project: String, color: String, order: Int, worktree: Worktree, agent: String?
    ) {
      var descriptor = MirrorPaneDescriptor(
        id: id, title: "\(project) · \(tab) · \(worktree.name)", directory: worktree.path, busy: false,
        projectName: project, subtitle: "\(tab) · \(worktree.name)", agent: agent,
        agentState: agent == nil ? nil : .idle, conversation: agent == nil ? .unsupported : .available)
      descriptor.displayState = agent == nil ? nil : .idle
      descriptor.tabTitle = tab
      descriptor.worktreeName = worktree.name
      descriptor.repositoryColor = color
      descriptor.projectOrder = order
      self.descriptor = descriptor
      self.worktree = worktree
    }

    /// A pane New Session created next to `template`, in the same worktree.
    static func launched(in template: Pane, profile: Profile?, order: Int) -> Pane {
      var pane = Pane(
        id: UUID(), tab: profile?.name ?? "zsh", project: template.descriptor.projectName ?? "",
        color: template.descriptor.repositoryColor ?? "blue", order: template.descriptor.projectOrder ?? order,
        worktree: template.worktree, agent: profile?.runtime)
      if profile == nil { pane.shellLines = [MirrorDemoContent.shellPrompt(template.worktree)] }
      pane.descriptor.stateChangedAt = MirrorConversationEvent.formatTimestamp(Date())
      return pane
    }

    /// The start of a new agent session.
    func agentStartEvents(at date: Date) -> [MirrorConversationEvent] {
      guard descriptor.agent != nil else { return [] }
      return [
        .demo(.sessionStarted, .session(.init(id: UUID().uuidString.lowercased(), cwd: worktree.path))),
        .demo(.agentStatus, .status(.init(state: .idle)), source: .osc),
      ]
    }

    /// Takes events in order: numbers them, dates them, and follows the state, the session and
    /// the open prompt they report.
    mutating func append(_ newEvents: [MirrorConversationEvent], at date: Date) {
      for var event in newEvents {
        latestSequence += 1
        event.sequence = latestSequence
        event.timestamp = event.timestamp ?? date
        events.append(event)
        switch (event.kind, event.payload) {
        case (.agentStatus, .status(let status)):
          setState(status.state, at: event.timestamp ?? date)
        case (.promptOpened, .prompt(let opened)) where event.source == .screen:
          prompt = opened
        case (.promptResolved, .prompt(let resolved)) where resolved.id == prompt?.id:
          prompt = nil
        default:
          break
        }
      }
    }

    private mutating func setState(_ state: MirrorConversationEvent.AgentState, at date: Date) {
      let previous = descriptor.displayState
      descriptor.agentState = state
      switch state {
      case .working: descriptor.displayState = .working
      case .blocked: descriptor.displayState = .blocked
      case .idle, .unknown:
        // As on the Mac: a turn that just ended is done until someone looks at it.
        descriptor.displayState = previous == .working || previous == .blocked ? .done : .idle
      }
      if descriptor.displayState != previous {
        descriptor.stateChangedAt = MirrorConversationEvent.formatTimestamp(date)
      }
    }

    /// What Stop leaves: the running tools and the turn end as interrupted, and the agent waits.
    func interruptionEvents() -> [MirrorConversationEvent] {
      var ended = Set<String>()
      var running: [MirrorConversationEvent.ToolStart] = []
      for event in events {
        switch event.payload {
        case .toolStart(let start): running.append(start)
        case .toolEnd(let end): ended.insert(end.id)
        default: break
        }
      }
      let open = running.filter { !ended.contains($0.id) }
      return open.map {
        .demo(.toolCompleted, .toolEnd(.init(id: $0.id, name: $0.name, status: .interrupted)))
      } + [
        .demo(.turnCompleted, .turn(.init(status: .aborted, reason: "interrupted"))),
        .demo(.notice, .notice(.init(level: .info, text: "Interrupted. Tell \(agentName) what to do differently."))),
        .demo(.agentStatus, .status(.init(state: .idle)), source: .osc),
      ]
    }

    /// A shell command from the phone: shown at the prompt, not run.
    mutating func runShellCommand(_ command: String) {
      if shellLines.last == MirrorDemoContent.shellPrompt(worktree) { shellLines.removeLast() }
      shellLines.append(MirrorDemoContent.shellPrompt(worktree) + command)
      shellLines.append("demo: Commands do not run in the demo. On a paired Mac they run in this pane.")
      shellLines.append(MirrorDemoContent.shellPrompt(worktree))
    }

    mutating func setShellLines(_ lines: [String]) { shellLines = lines }

    // MARK: Screen

    static let screenLines = 48

    /// The terminal screen: the last lines of the session and the menu the agent waits on, or
    /// an earlier window `scrolledBy` lines up from the end.
    func screen(scrolledBy offset: Int = 0) -> String {
      let lines = transcriptLines
      let end = lines.count - min(max(0, offset), maximumScroll(lines))
      return lines[max(0, end - Self.screenLines)..<end].joined(separator: "\n")
    }

    /// How far the screen can scroll up from the end.
    var maximumScroll: Int { maximumScroll(transcriptLines) }

    private func maximumScroll(_ lines: [String]) -> Int { max(0, lines.count - Self.screenLines) }

    /// Everything the pane printed, for the terminal history.
    var historyText: String { transcriptLines.joined(separator: "\n") }

    private var transcriptLines: [String] {
      guard descriptor.agent != nil else { return shellLines }
      let bullet = descriptor.agent == "codex" ? "•" : "⏺"
      var lines = [
        descriptor.agent == "codex" ? ">_ Codex · \(worktree.path)" : "✻ Claude Code · \(worktree.path)", "",
      ]
      var ends: [String: MirrorConversationEvent.ToolEnd] = [:]
      for event in events { if case .toolEnd(let end) = event.payload { ends[end.id] = end } }
      func add(_ first: String, _ text: String) {
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        lines.append(first + (parts.first.map(String.init) ?? ""))
        lines.append(contentsOf: parts.dropFirst().map { "  " + $0 })
        lines.append("")
      }
      for event in events {
        switch (event.kind, event.payload) {
        case (.userMessage, .message(let message)), (.userUnqueued, .message(let message)):
          add("> ", message.text.text)
        case (.assistantMessage, .message(let message)):
          add("\(bullet) ", message.text.text)
        case (.toolStarted, .toolStart(let start)):
          let target = start.command ?? start.path ?? start.title
          lines.append("\(bullet) \(start.name)(\(target))")
          lines.append("  ⎿  " + Self.summary(of: ends[start.id]))
          lines.append("")
        case (.notice, .notice(let notice)):
          add("  ", notice.text)
        default:
          break
        }
      }
      if let prompt {
        // As the agent draws it: the quoted lines, such as the command, above the question.
        if let detail = prompt.detail?.text {
          lines.append(contentsOf: detail.split(separator: "\n").map { "  " + $0 })
        }
        if let title = prompt.title { lines.append(title) }
        for (index, choice) in (prompt.choices ?? []).enumerated() {
          lines.append((index == 0 ? "❯ " : "  ") + "\(choice.id). \(choice.label)")
        }
      } else if descriptor.agentState == .working {
        lines.append(descriptor.agent == "codex" ? "• Working (esc to interrupt)" : "✻ Working… (esc to interrupt)")
      } else {
        lines.append(">")
      }
      return lines
    }

    private static func summary(of end: MirrorConversationEvent.ToolEnd?) -> String {
      guard let end else { return "Running…" }
      switch end.status {
      case .interrupted: return "Interrupted"
      case .error: return end.output?.text.split(separator: "\n").first.map(String.init) ?? "Failed"
      case .succeeded:
        if end.diff != nil { return "Updated" }
        let lines = end.output?.text.split(separator: "\n") ?? []
        return lines.last.map(String.init) ?? "Done"
      }
    }
  }

  static func shellPrompt(_ worktree: Worktree) -> String {
    "\(URL(fileURLWithPath: worktree.rootPath).lastPathComponent) \(worktree.name) ❯ "
  }

  /// The answer to anything sent to an agent in the demo: what would happen on a Mac.
  static func reply(to message: String, agent: String) -> [Step] {
    let tool = "demo-\(UUID().uuidString.prefix(8))"
    return [
      Step(
        after: .zero,
        [
          .demo(.turnStarted, .turn(.init(origin: .human))),
          .demo(.userMessage, .message(.init(text: .init(message), origin: .human))),
          .demo(.agentStatus, .status(.init(state: .working)), source: .osc),
        ]),
      Step(after: .seconds(1.2), [.demo(.assistantReasoning, .reasoning(.init(durationMs: 1100)))]),
      Step(
        after: .seconds(0.8),
        [
          .demo(
            .toolStarted,
            .toolStart(.init(id: tool, name: "Read", kind: .read, title: "Read the request", path: "Demo.md")))
        ]),
      Step(
        after: .seconds(1.4),
        [
          .demo(
            .toolCompleted,
            .toolEnd(
              .init(id: tool, name: "Read", status: .succeeded, output: .init("Read 12 lines"), durationMs: 1400))),
          .demo(
            .assistantMessage,
            .message(
              .init(
                text: .init(
                  """
                  This is the demo, so no agent runs here and nothing changes on a Mac.

                  With Prowl on your Mac, \(agent) gets this message in its pane, and you follow the work here: \
                  its messages, the tools it runs, and the questions it asks you.

                  To use your own agents, exit the demo and pair with a Mac that runs Prowl.
                  """), phase: .final))),
          .demo(.turnCompleted, .turn(.init(origin: .human, status: .completed, durationMs: 3400))),
          .demo(.agentStatus, .status(.init(state: .idle)), source: .osc),
        ]),
    ]
  }
}

extension MirrorConversationEvent {
  /// A demo event; the demo Host numbers and dates it when it is appended.
  nonisolated static func demo(_ kind: Kind, _ payload: Payload, source: Source = .transcript, at date: Date? = nil)
    -> MirrorConversationEvent
  {
    .init(kind, payload, at: date, source: source)
  }
}
