// ProwlCLI/CLIExecution.swift
// Common command execution wrapper for consistent JSON/text error rendering.

import ArgumentParser
import ProwlCLIShared
@preconcurrency import Rainbow

enum CLIExecution {
  static func run(command: String, output: OutputMode, colorEnabled: Bool = true, _ body: () throws -> Void) throws {
    Rainbow.enabled = colorEnabled
    do {
      try body()
    } catch let error as ExitError {
      OutputRenderer.renderError(
        code: error.code,
        message: error.message,
        command: command,
        mode: output
      )
      throw ExitCode.failure
    }
  }
}
