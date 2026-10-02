// supacodeTests/CLICommandResponseTests.swift
// Contract tests for CommandResponse and RawJSON encoding/decoding.

import Foundation
import ProwlCLIShared
import Testing

@testable import supacode

struct CLICommandResponseTests {

  // MARK: - CommandResponse JSON key stability

  @Test func successResponseHasStableKeys() throws {
    let payload = ["items": [1, 2, 3]]
    let rawData = try JSONSerialization.data(withJSONObject: payload)
    let response = CommandResponse(
      ok: true,
      command: "list",
      schemaVersion: "prowl.cli.list.v1",
      data: RawJSON(rawData)
    )
    let encoded = try JSONEncoder().encode(response)
    let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    #expect(json["ok"] as? Bool == true)
    #expect(json["command"] as? String == "list")
    #expect(json["schema_version"] as? String == "prowl.cli.list.v1")
    #expect(json["data"] != nil)
    #expect(json["error"] == nil)
  }

  @Test func errorResponseHasStableKeys() throws {
    let response = CommandResponse(
      ok: false,
      command: "open",
      schemaVersion: "prowl.cli.open.v1",
      error: CommandError(code: "PATH_NOT_FOUND", message: "Path not found: ~/nope")
    )
    let encoded = try JSONEncoder().encode(response)
    let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

    #expect(json["ok"] as? Bool == false)
    #expect(json["command"] as? String == "open")
    #expect(json["schema_version"] as? String == "prowl.cli.open.v1")
    #expect(json["data"] == nil)
    let error = try #require(json["error"] as? [String: Any])
    #expect(error["code"] as? String == "PATH_NOT_FOUND")
    #expect(error["message"] as? String == "Path not found: ~/nope")
  }

  @Test func responseRoundTrips() throws {
    let original = CommandResponse(
      ok: false,
      command: "send",
      schemaVersion: "prowl.cli.send.v1",
      error: CommandError(code: "EMPTY_INPUT", message: "No input provided.")
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(CommandResponse.self, from: data)
    #expect(decoded.ok == false)
    #expect(decoded.command == "send")
    #expect(decoded.schemaVersion == "prowl.cli.send.v1")
    #expect(decoded.error?.code == "EMPTY_INPUT")
  }

  // MARK: - RawJSON round-tripping

  @Test func rawJSONFromEncodableRoundTrips() throws {
    struct Payload: Codable, Equatable {
      let count: Int
      let name: String
    }
    let original = Payload(count: 42, name: "test")
    let raw = try RawJSON(encoding: original)
    let decoded = try raw.decode(as: Payload.self)
    #expect(decoded == original)
  }

  @Test func rawJSONPreservesNestedStructure() throws {
    let nested: [String: Any] = [
      "items": [
        ["id": "a", "value": 1],
        ["id": "b", "value": 2],
      ]
    ]
    let rawData = try JSONSerialization.data(withJSONObject: nested)
    let raw = RawJSON(rawData)

    // Embed in response and round-trip
    let response = CommandResponse(
      ok: true,
      command: "list",
      schemaVersion: "prowl.cli.list.v1",
      data: raw
    )
    let encoded = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(CommandResponse.self, from: encoded)
    #expect(decoded.data != nil)

    // Verify nested data survived
    let decodedPayload = try JSONSerialization.jsonObject(with: decoded.data!.bytes)
    let dict = try #require(decodedPayload as? [String: Any])
    let items = try #require(dict["items"] as? [[String: Any]])
    #expect(items.count == 2)
  }

  // MARK: - Error codes constants

  @Test func errorCodeConstantsAreDefined() {
    #expect(CLIErrorCode.appNotRunning == "APP_NOT_RUNNING")
    #expect(CLIErrorCode.invalidArgument == "INVALID_ARGUMENT")
    #expect(CLIErrorCode.targetNotFound == "TARGET_NOT_FOUND")
    #expect(CLIErrorCode.emptyInput == "EMPTY_INPUT")
    #expect(CLIErrorCode.invalidRepeat == "INVALID_REPEAT")
    #expect(CLIErrorCode.transportFailed == "TRANSPORT_FAILED")
    #expect(CLIErrorCode.timeout == "TIMEOUT")
    #expect(CLIErrorCode.pathNotFound == "PATH_NOT_FOUND")
    #expect(CLIErrorCode.pathNotDirectory == "PATH_NOT_DIRECTORY")
  }
}
