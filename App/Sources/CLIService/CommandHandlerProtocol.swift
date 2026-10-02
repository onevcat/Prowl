// supacode/CLIService/CommandHandlerProtocol.swift
// Protocol for command handlers on the app side.

import Foundation
import ProwlCLIShared

/// Each CLI command has a corresponding handler that executes
/// within the app's process context.
protocol CommandHandler {
  /// Execute the command and return a structured response.
  func handle(envelope: CommandEnvelope) async -> CommandResponse
  /// Context-aware variant; handlers that need caller identity override this.
  func handle(envelope: CommandEnvelope, context: CLICommandContext) async -> CommandResponse
}

extension CommandHandler {
  func handle(envelope: CommandEnvelope, context: CLICommandContext) async -> CommandResponse {
    await handle(envelope: envelope)
  }
}
