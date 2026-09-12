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

  init(
    router: CLICommandRouter, maximumRequests: Int = 1024
  ) {
    self.router = router
    self.maximumRequests = maximumRequests
  }

  func execute(
    _ message: MirrorCommandRequest, authorize: @escaping @MainActor () -> Bool = { true }
  ) async -> MirrorCommandResponse {
    let result = await perform(message, authorize: authorize)
    return MirrorCommandResponse(requestID: message.requestID, response: result)
  }

  func cancel(_ requestID: UUID) { executions[requestID]?.task.cancel() }

  func receipt(_ requestID: UUID, paneID: UUID) async -> MirrorCommandResponse {
    guard let entry = executions[requestID],
      entry.request.command.targetPaneID == paneID
    else { return .init(requestID: requestID, response: Self.encodingFailure) }
    return .init(requestID: requestID, response: await entry.task.value)
  }

  private func perform(
    _ message: MirrorCommandRequest, authorize: @escaping @MainActor () -> Bool
  ) async -> MirrorJSON {
    guard authorize() else { return failure("The mirror no longer owns this pane.") }
    // Code security: remote requests expose only catalog reads and ordinary Profile-backed tabs.
    guard message.request.output == "json" else { return failure("Command is not allowed.") }
    if let existing = executions[message.requestID] {
      guard existing.request == message.request else {
        return failure("Request ID was reused with different parameters.")
      }
      return await existing.task.value
    }
    if let refusal = validate(message.request.command) { return refusal }
    let retainsReceipt: Bool
    switch message.request.command {
    case .list, .profiles: retainsReceipt = false
    default: retainsReceipt = true
    }
    guard !retainsReceipt || executions.count < maximumRequests else {
      return failure(
        "The remote command request limit has been reached. Restart Prowl before issuing more commands."
      )
    }
    do {
      let data = try JSONEncoder().encode(message.request)
      let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: data)
      let task = Task { @MainActor [router] in
        guard authorize(), !Task.isCancelled else {
          return Self.failure("The mirror no longer owns this pane.")
        }
        let response = await router.route(envelope)
        do {
          return try JSONDecoder().decode(MirrorJSON.self, from: JSONEncoder().encode(response))
        } catch {
          return Self.encodingFailure
        }
      }
      // Code security: reserve the ID before awaiting; duplicates share the original operation.
      // Keep mutation receipts for the App lifetime rather than evicting and replaying them.
      // Fresh catalog reads do not consume this bounded mutation budget.
      if retainsReceipt {
        executions[message.requestID] = Execution(request: message.request, task: task)
      }
      return await task.value
    } catch { return failure("Invalid command request.") }
  }

  private func validate(_ command: MirrorCommandRequest.Command) -> MirrorJSON? {
    switch command {
    case .list, .profiles: break
    case .agentsDispatch(let input):
      guard UUID(uuidString: input.pane) != nil, input.prompt.utf8.count <= MirrorWire.maximumInput
      else {
        return failure("Invalid dispatch target or prompt size.")
      }
    case .send:
      return failure(
        "Host cannot verify an empty shell command line. Use an Agent Profile or control the shell on Host."
      )
    case .create(let input):
      guard input.resource == "tab", input.background,
        !input.launch.profile.isEmpty,
        (input.launch.prompt?.utf8.count ?? 0) <= MirrorWire.maximumInput
      else { return failure("Choose a valid Host Profile and a prompt within the size limit.") }
    }
    return nil
  }

  private func failure(_ message: String) -> MirrorJSON { Self.failure(message) }

  private static let encodingFailure = failure(
    "Could not encode the command result. Check Host before retrying.",
    code: "REMOTE_COMMAND_UNCONFIRMED")

  private static func failure(_ message: String, code: String = "REMOTE_COMMAND_REJECTED")
    -> MirrorJSON
  {
    .object([
      "ok": .bool(false), "command": .string("remote"),
      "schema_version": .string("prowl.remote.command.v1"),
      "error": .object(["code": .string(code), "message": .string(message)]),
    ])
  }
}
