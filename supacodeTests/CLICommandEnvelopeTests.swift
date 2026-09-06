// supacodeTests/CLICommandEnvelopeTests.swift
// Contract tests for CommandEnvelope, CommandResponse, and shared types.

import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct CLICommandEnvelopeTests {

  // MARK: - CommandEnvelope round-trip

  @Test func envelopeOpenRoundTrips() throws {
    let envelope = CommandEnvelope(
      output: .json,
      command: .open(OpenInput(path: "/Users/test/project"))
    )
    let data = try JSONEncoder().encode(envelope)
    let decoded = try JSONDecoder().decode(CommandEnvelope.self, from: data)

    #expect(decoded.output == .json)
    if case .open(let input) = decoded.command {
      #expect(input.path == "/Users/test/project")
    } else {
      Issue.record("Expected .open command")
    }
  }

  @Test func envelopeOpenNilPathRoundTrips() throws {
    let envelope = CommandEnvelope(
      output: .text,
      command: .open(OpenInput(path: nil))
    )
    let data = try JSONEncoder().encode(envelope)
    let decoded = try JSONDecoder().decode(CommandEnvelope.self, from: data)

    if case .open(let input) = decoded.command {
      #expect(input.path == nil)
    } else {
      Issue.record("Expected .open command")
    }
  }

  @Test func envelopeListRoundTrips() throws {
    let envelope = CommandEnvelope(
      output: .text,
      command: .list(ListInput())
    )
    let data = try JSONEncoder().encode(envelope)
    let decoded = try JSONDecoder().decode(CommandEnvelope.self, from: data)
    #expect(decoded.output == .text)
    if case .list = decoded.command {
      // expected
    } else {
      Issue.record("Expected .list command")
    }
  }

  @Test func envelopeAgentsRoundTrips() throws {
    let envelope = CommandEnvelope(
      output: .json,
      command: .agents(AgentsInput())
    )
    let data = try JSONEncoder().encode(envelope)
    let decoded = try JSONDecoder().decode(CommandEnvelope.self, from: data)
    #expect(decoded.output == .json)
    if case .agents = decoded.command {
      // expected
    } else {
      Issue.record("Expected .agents command")
    }
  }

  @Test func envelopeAgentsSignalRoundTrips() throws {
    let envelope = CommandEnvelope(
      output: .json,
      command: .agentsSignal(
        AgentSignalInput(
          event: .needsInput,
          origin: "manual",
          sessionID: "session-1",
          detail: "Approval required"
        ))
    )
    let data = try JSONEncoder().encode(envelope)
    let decoded = try JSONDecoder().decode(CommandEnvelope.self, from: data)

    if case .agentsSignal(let input) = decoded.command {
      #expect(input.event == .needsInput)
      #expect(input.progress == nil)
      #expect(input.origin == "manual")
      #expect(input.sessionID == "session-1")
      #expect(input.detail == "Approval required")
    } else {
      Issue.record("Expected .agentsSignal command")
    }
  }

  @Test func envelopeAgentsReadRoundTrips() throws {
    let envelope = CommandEnvelope(
      output: .text,
      command: .agentsRead(AgentReadInput(pane: "p7", maxBytes: 1_024, resultOnly: true))
    )
    let data = try JSONEncoder().encode(envelope)
    let decoded = try JSONDecoder().decode(CommandEnvelope.self, from: data)

    if case .agentsRead(let input) = decoded.command {
      #expect(input.pane == "p7")
      #expect(input.maxBytes == 1_024)
      #expect(input.resultOnly)
    } else {
      Issue.record("Expected .agentsRead command")
    }
  }

  @Test func envelopeSendWithSelectorRoundTrips() throws {
    let envelope = CommandEnvelope(
      output: .json,
      command: .send(
        SendInput(
          selector: .pane("abc-123"),
          text: "hello world",
          trailingEnter: false
        ))
    )
    let data = try JSONEncoder().encode(envelope)
    let decoded = try JSONDecoder().decode(CommandEnvelope.self, from: data)
    if case .send(let input) = decoded.command {
      #expect(input.text == "hello world")
      #expect(input.trailingEnter == false)
      #expect(input.selector == .pane("abc-123"))
    } else {
      Issue.record("Expected .send command")
    }
  }

  @Test func envelopeKeyWithRepeatRoundTrips() throws {
    let envelope = CommandEnvelope(
      output: .text,
      command: .key(
        KeyInput(
          selector: .tab("tab-1"),
          rawToken: "enter",
          token: "enter",
          repeatCount: 5
        ))
    )
    let data = try JSONEncoder().encode(envelope)
    let decoded = try JSONDecoder().decode(CommandEnvelope.self, from: data)
    if case .key(let input) = decoded.command {
      #expect(input.token == "enter")
      #expect(input.repeatCount == 5)
      #expect(input.selector == .tab("tab-1"))
    } else {
      Issue.record("Expected .key command")
    }
  }

  @Test func envelopeReadWithLastRoundTrips() throws {
    let envelope = CommandEnvelope(
      output: .json,
      command: .read(ReadInput(selector: .worktree("wt-main"), last: 50))
    )
    let data = try JSONEncoder().encode(envelope)
    let decoded = try JSONDecoder().decode(CommandEnvelope.self, from: data)
    if case .read(let input) = decoded.command {
      #expect(input.last == 50)
      #expect(input.selector == .worktree("wt-main"))
    } else {
      Issue.record("Expected .read command")
    }
  }

  @Test func envelopeFocusNoSelectorRoundTrips() throws {
    let envelope = CommandEnvelope(
      output: .text,
      command: .focus(FocusInput(selector: .none))
    )
    let data = try JSONEncoder().encode(envelope)
    let decoded = try JSONDecoder().decode(CommandEnvelope.self, from: data)
    if case .focus(let input) = decoded.command {
      #expect(input.selector == .none)
    } else {
      Issue.record("Expected .focus command")
    }
  }

  @Test func envelopeTabCreateRoundTrips() throws {
    let envelope = CommandEnvelope(
      output: .json,
      command: .tab(TabInput(action: .create, selector: .worktree("wt-main"), path: "/Projects/App"))
    )
    let data = try JSONEncoder().encode(envelope)
    let decoded = try JSONDecoder().decode(CommandEnvelope.self, from: data)
    if case .tab(let input) = decoded.command {
      #expect(input.action == .create)
      #expect(input.selector == .worktree("wt-main"))
      #expect(input.path == "/Projects/App")
      #expect(input.force == false)
    } else {
      Issue.record("Expected .tab command")
    }
  }

  @Test func envelopeTabCloseForceRoundTrips() throws {
    let envelope = CommandEnvelope(
      output: .json,
      command: .tab(TabInput(action: .close, selector: .tab("tab-1"), force: true))
    )
    let data = try JSONEncoder().encode(envelope)
    let decoded = try JSONDecoder().decode(CommandEnvelope.self, from: data)
    if case .tab(let input) = decoded.command {
      #expect(input.action == .close)
      #expect(input.selector == .tab("tab-1"))
      #expect(input.force == true)
    } else {
      Issue.record("Expected .tab command")
    }
  }

  @Test func envelopeTabInputDecodesMissingForceAsFalse() throws {
    let json = """
      {
        "output": "json",
        "command": {
          "tab": {
            "_0": {
              "action": "close",
              "selector": { "tab": { "_0": "tab-1" } }
            }
          }
        }
      }
      """
    let decoded = try JSONDecoder().decode(CommandEnvelope.self, from: Data(json.utf8))
    if case .tab(let input) = decoded.command {
      #expect(input.action == .close)
      #expect(input.selector == .tab("tab-1"))
      #expect(input.force == false)
    } else {
      Issue.record("Expected .tab command")
    }
  }

  @Test func envelopePaneCloseRoundTrips() throws {
    let envelope = CommandEnvelope(
      output: .text,
      command: .pane(PaneInput(action: .close, selector: .pane("pane-1"), force: true))
    )
    let data = try JSONEncoder().encode(envelope)
    let decoded = try JSONDecoder().decode(CommandEnvelope.self, from: data)
    if case .pane(let input) = decoded.command {
      #expect(input.action == .close)
      #expect(input.selector == .pane("pane-1"))
      #expect(input.force == true)
    } else {
      Issue.record("Expected .pane command")
    }
  }

  @Test func envelopePaneInputDecodesMissingForceAsFalse() throws {
    let json = """
      {
        "output": "json",
        "command": {
          "pane": {
            "_0": {
              "action": "close",
              "selector": { "pane": { "_0": "pane-1" } }
            }
          }
        }
      }
      """
    let decoded = try JSONDecoder().decode(CommandEnvelope.self, from: Data(json.utf8))
    if case .pane(let input) = decoded.command {
      #expect(input.action == .close)
      #expect(input.selector == .pane("pane-1"))
      #expect(input.force == false)
    } else {
      Issue.record("Expected .pane command")
    }
  }

  // MARK: - Command name

  @Test func commandNameReturnsCorrectStrings() {
    let commands: [(Command, String)] = [
      (.open(OpenInput(path: nil)), "open"),
      (.list(ListInput()), "list"),
      (.agents(AgentsInput()), "agents"),
      (.agentsRead(AgentReadInput(pane: "p7")), "agents.read"),
      (.agentsSignal(AgentSignalInput(event: .turnEnded)), "agents.signal"),
      (.focus(FocusInput()), "focus"),
      (.send(SendInput(text: "x")), "send"),
      (.key(KeyInput(rawToken: "tab", token: "tab")), "key"),
      (.read(ReadInput()), "read"),
      (.tab(TabInput(action: .create)), "tab"),
      (.pane(PaneInput(action: .close)), "pane"),
    ]
    for (command, expected) in commands {
      #expect(command.name == expected)
    }
  }

  // MARK: - Encoding produces valid JSON

  @Test func allCommandsEncodeToValidJSON() throws {
    let commands: [Command] = [
      .open(OpenInput(path: "/tmp")),
      .list(ListInput()),
      .agents(AgentsInput()),
      .agentsRead(AgentReadInput(pane: "p7")),
      .agentsSignal(AgentSignalInput(event: .sessionStart)),
      .focus(FocusInput()),
      .send(SendInput(text: "test")),
      .key(KeyInput(rawToken: "enter", token: "enter")),
      .read(ReadInput()),
      .tab(TabInput(action: .create)),
      .pane(PaneInput(action: .close)),
    ]
    for cmd in commands {
      let envelope = CommandEnvelope(output: .json, command: cmd)
      let data = try JSONEncoder().encode(envelope)
      let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(json["output"] as? String == "json")
      #expect(json["command"] != nil)
    }
  }
}
