// ProwlCLI/CLIRunner.swift
// Central execution point: send envelope to app, render response.

import ArgumentParser
import Foundation
import ProwlCLIShared

enum CLIRunner {
  /// Execute a command envelope by sending it to the running app
  /// and rendering the response. A response validator must throw `ExitError`
  /// so contract failures retain the command's error code instead of becoming transport failures.
  static func execute(
    _ envelope: CommandEnvelope,
    validateResponse: ((CommandResponse) throws -> Void)? = nil
  ) throws {
    do {
      let responseData = try SocketTransportClient.send(envelope)
      let decoder = JSONDecoder()
      let response = try decoder.decode(CommandResponse.self, from: responseData)
      if response.ok {
        try validateResponse?(response)
      }
      switch envelope.output {
      case .json:
        renderJSONData(responseData)
      case .text:
        OutputRenderer.render(response, mode: .text)
      }
      if !response.ok {
        throw ExitCode.failure
      }
    } catch let error as ExitError {
      OutputRenderer.renderError(
        code: error.code,
        message: error.message,
        command: envelope.command.name,
        mode: envelope.output
      )
      throw ExitCode.failure
    } catch is ExitCode {
      throw ExitCode.failure
    } catch {
      OutputRenderer.renderError(
        code: CLIErrorCode.transportFailed,
        message: error.localizedDescription,
        command: envelope.command.name,
        mode: envelope.output
      )
      throw ExitCode.failure
    }
  }

  private static func renderJSONData(_ data: Data) {
    FileHandle.standardOutput.write(data)
    if data.last != UInt8(ascii: "\n") {
      FileHandle.standardOutput.write(Data([UInt8(ascii: "\n")]))
    }
  }
}
