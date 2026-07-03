import Testing

@testable import supacode

struct TelegramBotCommandParserTests {
  @Test func parsesAgentsIntoCommandEnvelope() {
    let parser = TelegramBotCommandParser(defaultReadLines: 80, requireExplicitPaneForWrite: true)

    let result = parser.parse(text: "/agents")

    guard case .command(let request) = result else {
      Issue.record("Expected command parse result, got \(result)")
      return
    }
    #expect(request.commandName == "agents")
    guard case .agents = request.envelope.command else {
      Issue.record("Expected agents envelope")
      return
    }
    #expect(request.envelope.output == .json)
  }

  @Test func parsesReadTargetWithExplicitLineCount() {
    let parser = TelegramBotCommandParser(defaultReadLines: 80, requireExplicitPaneForWrite: true)

    let result = parser.parse(text: "/read pane-123 12")

    guard case .command(let request) = result else {
      Issue.record("Expected command parse result, got \(result)")
      return
    }
    #expect(request.commandName == "read")
    guard case .read(let input) = request.envelope.command else {
      Issue.record("Expected read envelope")
      return
    }
    #expect(input.selector == .pane("pane-123"))
    #expect(input.last == 12)
  }

  @Test func readUsesDefaultLineCountWhenOmitted() {
    let parser = TelegramBotCommandParser(defaultReadLines: 50, requireExplicitPaneForWrite: true)

    let result = parser.parse(text: "/read pane-123")

    guard case .command(let request) = result,
      case .read(let input) = request.envelope.command
    else {
      Issue.record("Expected read envelope, got \(result)")
      return
    }
    #expect(input.selector == .pane("pane-123"))
    #expect(input.last == 50)
  }

  @Test func sendRequiresExplicitPaneWhenWriteProtectionIsEnabled() {
    let parser = TelegramBotCommandParser(defaultReadLines: 80, requireExplicitPaneForWrite: true)

    let result = parser.parse(text: "/send hello")

    guard case .message(let text) = result else {
      Issue.record("Expected validation message, got \(result)")
      return
    }
    #expect(text.contains("/send <pane-id> <text>"))
  }

  @Test func parsesSendWithoutWaitOrCapture() {
    let parser = TelegramBotCommandParser(defaultReadLines: 80, requireExplicitPaneForWrite: true)

    let result = parser.parse(text: "/send pane-123 echo hello")

    guard case .command(let request) = result,
      case .send(let input) = request.envelope.command
    else {
      Issue.record("Expected send envelope, got \(result)")
      return
    }
    #expect(request.commandName == "send")
    #expect(input.selector == .pane("pane-123"))
    #expect(input.text == "echo hello")
    #expect(input.wait == false)
    #expect(input.captureOutput == false)
  }

  @Test func sendCanUseFocusedPaneWhenWriteProtectionIsDisabled() {
    let parser = TelegramBotCommandParser(defaultReadLines: 80, requireExplicitPaneForWrite: false)

    let result = parser.parse(text: "/send echo hello")

    guard case .command(let request) = result,
      case .send(let input) = request.envelope.command
    else {
      Issue.record("Expected send envelope, got \(result)")
      return
    }
    #expect(input.selector == .none)
    #expect(input.text == "echo hello")
  }

  @Test func keyNormalizesSupportedToken() {
    let parser = TelegramBotCommandParser(defaultReadLines: 80, requireExplicitPaneForWrite: true)

    let result = parser.parse(text: "/key pane-123 Cmd+Shift+P")

    guard case .command(let request) = result,
      case .key(let input) = request.envelope.command
    else {
      Issue.record("Expected key envelope, got \(result)")
      return
    }
    #expect(input.selector == .pane("pane-123"))
    #expect(input.rawToken == "Cmd+Shift+P")
    #expect(input.token == "cmd-shift-p")
  }

  @Test func keyCanUseFocusedPaneWhenWriteProtectionIsDisabled() {
    let parser = TelegramBotCommandParser(defaultReadLines: 80, requireExplicitPaneForWrite: false)

    let result = parser.parse(text: "/key cmd-k")

    guard case .command(let request) = result,
      case .key(let input) = request.envelope.command
    else {
      Issue.record("Expected key envelope, got \(result)")
      return
    }
    #expect(input.selector == .none)
    #expect(input.rawToken == "cmd-k")
    #expect(input.token == "cmd-k")
  }

  @Test func keyRejectsUnsupportedToken() {
    let parser = TelegramBotCommandParser(defaultReadLines: 80, requireExplicitPaneForWrite: true)

    let result = parser.parse(text: "/key pane-123 nope-key")

    guard case .message(let text) = result else {
      Issue.record("Expected validation message, got \(result)")
      return
    }
    #expect(text.contains("unsupported"))
  }

  @Test func closeCommandsAreExplicitAndNonForce() {
    let parser = TelegramBotCommandParser(defaultReadLines: 80, requireExplicitPaneForWrite: true)

    let paneResult = parser.parse(text: "/pane_close pane-123")
    guard case .command(let paneRequest) = paneResult,
      case .pane(let paneInput) = paneRequest.envelope.command
    else {
      Issue.record("Expected pane close envelope, got \(paneResult)")
      return
    }
    #expect(paneInput.selector == .pane("pane-123"))
    #expect(paneInput.force == false)

    let tabResult = parser.parse(text: "/tab_close tab-123")
    guard case .command(let tabRequest) = tabResult,
      case .tab(let tabInput) = tabRequest.envelope.command
    else {
      Issue.record("Expected tab close envelope, got \(tabResult)")
      return
    }
    #expect(tabInput.selector == .tab("tab-123"))
    #expect(tabInput.force == false)
  }
}
