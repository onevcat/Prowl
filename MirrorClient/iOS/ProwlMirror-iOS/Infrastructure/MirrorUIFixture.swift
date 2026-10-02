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
      case .agentsInput, .agentsDispatch, .send: throw CancellationError()
      case .list:
        payload =
          #"{"ok":true,"data":{"items":[{"worktree":{"id":"fixture-worktree","name":"main","path":"/Projects/Prowl","root_path":"/Projects/Prowl"}}]}}"#
      case .profiles:
        payload =
          #"{"ok":true,"data":{"profiles":[{"id":"fixture-profile","name":"Codex","enabled":true,"runtime":"codex","availability":{"status":"available"}}]}}"#
      case .create:
        payload =
          #"{"ok":true,"data":{"target":{"worktree":{"id":"fixture-worktree","name":"main","path":"/Projects/Prowl","root_path":"/Projects/Prowl"},"pane":{"id":"03F5535A-D08C-498C-B70B-C665AC8D02CB","title":"Codex"}}}}"#
      }
      return try JSONDecoder().decode(MirrorJSON.self, from: Data(payload.utf8))
    }

    static func session(name: String = "UI Fixture", longOutput: Bool = false) -> MirrorSession {
      let channel = Channel(name: name, longOutput: longOutput)
      let session = MirrorSession(
        configuration: .init(
          address: "127.0.0.1", port: 7880, pairingKey: ""),
        makeTransport: { _ in channel })
      session.connect()
      session.select(channel.pane)
      return session
    }

    private final class Channel: MirrorTransport {
      var onReady: (() -> Void)?
      var onMessage: ((MirrorMessage) -> Void)?
      var onClose: ((String?) -> Void)?
      let pane: MirrorPaneDescriptor
      let longOutput: Bool
      init(name: String, longOutput: Bool) {
        self.longOutput = longOutput
        pane = MirrorPaneDescriptor(
          id: UUID(), title: "\(name) · Codex", directory: "/fixture", busy: false,
          projectName: name, subtitle: "Codex · main")
      }
      private let lease = UUID()
      private let run = UUID()
      private let history = MirrorHistory(
        text: (1...401).map { "Retained line \($0)" }.joined(separator: "\n"), truncated: true)
      private var sequence: UInt64 = 0
      private var scrollPage = 0
      private var scrollTask: Task<Void, Never>?
      private var includesScrollState = false

      func start() { onReady?() }
      func close(_ reason: String?) {
        scrollTask?.cancel()
        onClose?(reason)
      }

      func send(_ message: MirrorMessage, closeAfterSending: Bool) {
        switch message.kind {
        case .list:
          onMessage?(
            .panes(
              .init(
                panes: [pane],
                capabilities: [
                  "text-v1", "history", "refresh", "launch-profile", "agents-dispatch", "agent-input",
                  "shell-send",
                ] + (CommandLine.arguments.contains("--mirror-ui-no-scroll-fixture") ? [] : ["remote-scroll"])
                  + (CommandLine.arguments.contains("--mirror-ui-scroll-boundary-fixture") ? ["scroll-state-v1"] : []),
                hostRunID: UUID())))
        case .subscribe:
          if case .subscribe(let payload) = message { includesScrollState = payload.includeScrollState == true }
          onMessage?(
            .subscribed(.init(paneID: pane.id, subscriptionID: lease, hostRunID: run)))
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
        if CommandLine.arguments.contains("--mirror-ui-scroll-delay-fixture") {
          scrollTask = Task { [weak self] in
            do { try await ContinuousClock().sleep(for: .seconds(2)) } catch { return }
            self?.completeScroll(message)
          }
        } else {
          completeScroll(message)
        }
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
