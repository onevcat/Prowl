// supacodeTests/CLITransportProtocolTests.swift
// Tests for the length-prefixed JSON transport encoding/decoding.

import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct CLITransportProtocolTests {

  // MARK: - Length-prefix encoding

  @Test func lengthPrefixEncodesCorrectly() throws {
    let envelope = CommandEnvelope(
      output: .json,
      command: .list(ListInput())
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(envelope)

    // Build length-prefixed message
    var length = UInt32(payload.count).bigEndian
    var message = Data()
    withUnsafeBytes(of: &length) { message.append(contentsOf: $0) }
    message.append(payload)

    // Verify: first 4 bytes are big-endian length
    #expect(message.count == 4 + payload.count)
    let decodedLength = message.withUnsafeBytes { ptr -> UInt32 in
      UInt32(bigEndian: ptr.load(as: UInt32.self))
    }
    #expect(decodedLength == UInt32(payload.count))

    // Verify: remaining bytes decode back to envelope
    let payloadSlice = message.suffix(from: 4)
    let decoded = try JSONDecoder().decode(CommandEnvelope.self, from: payloadSlice)
    #expect(decoded.output == .json)
    if case .list = decoded.command {
      // expected
    } else {
      Issue.record("Expected .list command")
    }
  }

  @Test func responseLengthPrefixRoundTrips() throws {
    let response = CommandResponse(
      ok: true,
      command: "list",
      schemaVersion: "prowl.cli.list.v1"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(response)

    var length = UInt32(payload.count).bigEndian
    var message = Data()
    withUnsafeBytes(of: &length) { message.append(contentsOf: $0) }
    message.append(payload)

    // Parse back
    let parsedLength = message.withUnsafeBytes { ptr -> UInt32 in
      UInt32(bigEndian: ptr.load(as: UInt32.self))
    }
    let parsedPayload = message.suffix(from: 4).prefix(Int(parsedLength))
    let decoded = try JSONDecoder().decode(CommandResponse.self, from: parsedPayload)
    #expect(decoded.ok == true)
    #expect(decoded.command == "list")
  }

  // MARK: - Edge cases

  @Test func emptyDataPayloadLengthIsZero() {
    let emptyPayload = Data()
    var length = UInt32(emptyPayload.count).bigEndian
    var message = Data()
    withUnsafeBytes(of: &length) { message.append(contentsOf: $0) }
    #expect(message.count == 4)
    let decodedLength = message.withUnsafeBytes { ptr -> UInt32 in
      UInt32(bigEndian: ptr.load(as: UInt32.self))
    }
    #expect(decodedLength == 0)
  }

  @Test func maxReasonablePayloadLengthEncodes() {
    // 32 MiB is the max accepted by both client and server.
    let maxLength: UInt32 = 32 * 1_024 * 1_024
    var encoded = UInt32(maxLength).bigEndian
    var data = Data()
    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    let decoded = data.withUnsafeBytes { ptr -> UInt32 in
      UInt32(bigEndian: ptr.load(as: UInt32.self))
    }
    #expect(decoded == maxLength)
  }

  // MARK: - All commands encode without error

  @Test func allCommandTypesEncodeSuccessfully() throws {
    let commands: [Command] = [
      .open(OpenInput(path: "/tmp")),
      .open(OpenInput(path: nil)),
      .list(ListInput()),
      .focus(FocusInput(selector: .worktree("wt"))),
      .focus(FocusInput(selector: .none)),
      .send(SendInput(selector: .tab("t1"), text: "cmd", trailingEnter: true)),
      .key(KeyInput(selector: .pane("p1"), rawToken: "Ctrl+C", token: "ctrl-c", repeatCount: 100)),
      .read(ReadInput(selector: .none, last: nil)),
      .read(ReadInput(selector: .worktree("w"), last: 1)),
    ]
    let encoder = JSONEncoder()
    for cmd in commands {
      let envelope = CommandEnvelope(output: .json, command: cmd)
      let data = try encoder.encode(envelope)
      #expect(data.count > 0)
      // Verify it decodes back
      let decoded = try JSONDecoder().decode(CommandEnvelope.self, from: data)
      #expect(decoded.command.name == cmd.name)
    }
  }
}
