import Foundation
import ProwlCLIShared

@MainActor
final class MirrorCommandService {
  private struct Execution {
    let request: MirrorCommandRequest.Request
    let task: Task<MirrorJSON, Never>
  }
  private let router: CLICommandRouter
  private var executions: [UUID: Execution] = [:]
  private let maximumRequests: Int

  init(router: CLICommandRouter, maximumRequests: Int = 1024) {
    self.router = router
    self.maximumRequests = maximumRequests
  }

  func execute(_ message: MirrorCommandRequest) async -> MirrorCommandResponse {
    let result = await perform(message)
    return MirrorCommandResponse(requestID: message.requestID, response: result)
  }

  private func perform(_ message: MirrorCommandRequest) async -> MirrorJSON {
    // Code security: remote requests expose only catalog reads and ordinary Profile-backed tabs.
    guard message.request.output == "json" else { return failure("Command is not allowed.") }
    if let existing = executions[message.requestID] {
      guard existing.request == message.request else {
        return failure("Request ID was reused with different parameters.")
      }
      return await existing.task.value
    }
    switch message.request.command {
    case .list, .profiles: break
    case .create(let input):
      guard input.resource == "tab", input.background,
        !input.launch.profile.isEmpty,
        (input.launch.prompt?.utf8.count ?? 0) <= MirrorWire.maximumInput
      else { return failure("Choose a valid Host Profile and a prompt within the size limit.") }
    }
    guard executions.count < maximumRequests else {
      return failure("The remote command request limit has been reached. Restart Prowl before issuing more commands.")
    }
    do {
      let data = try JSONEncoder().encode(message.request)
      let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: data)
      let task = Task { @MainActor [router] in
        let response = await router.route(envelope)
        do { return try JSONDecoder().decode(MirrorJSON.self, from: JSONEncoder().encode(response)) } catch {
          return Self.encodingFailure
        }
      }
      // Code security: reserve the ID before awaiting; duplicates share the original operation.
      // Keep request receipts for the App lifetime rather than evicting and replaying a mutation.
      executions[message.requestID] = Execution(request: message.request, task: task)
      return await task.value
    } catch { return failure("Invalid command request.") }
  }

  private func failure(_ message: String) -> MirrorJSON { Self.failure(message) }

  private static let encodingFailure = failure(
    "Could not encode the command result. Check Host before retrying.", code: "REMOTE_COMMAND_UNCONFIRMED")

  private static func failure(_ message: String, code: String = "REMOTE_COMMAND_REJECTED") -> MirrorJSON {
    .object([
      "ok": .bool(false), "command": .string("remote"),
      "schema_version": .string("prowl.remote.command.v1"),
      "error": .object(["code": .string(code), "message": .string(message)]),
    ])
  }
}
