import Foundation
import ProwlCLIShared

@MainActor
final class MirrorCommandService {
  private struct Execution {
    let request: MirrorCommandRequest.Request
    let task: Task<MirrorJSON, Never>
  }
  private let protectInput: @MainActor (UUID) -> String?
  private let router: CLICommandRouter
  private var executions: [UUID: Execution] = [:]
  private let maximumRequests: Int

  init(
    router: CLICommandRouter, maximumRequests: Int = 1024,
    protectInput: @escaping @MainActor (UUID) -> String? = { _ in nil }
  ) {
    self.protectInput = protectInput
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
    guard executions.count < maximumRequests else {
      return failure("The remote command request limit has been reached. Restart Prowl before issuing more commands.")
    }
    do {
      let data = try JSONEncoder().encode(message.request)
      let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: data)
      let task = Task { @MainActor [router, protectInput] in
        guard authorize(), !Task.isCancelled else { return Self.failure("The mirror no longer owns this pane.") }
        if case .send(let input) = message.request.command,
          let refusal = await Self.shellRefusal(
            input, router: router, authorize: authorize, protectInput: protectInput) {
          return refusal
        }
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

  private func validate(_ command: MirrorCommandRequest.Command) -> MirrorJSON? {
    switch command {
    case .list, .profiles: break
    case .agentsDispatch(let input):
      guard UUID(uuidString: input.pane) != nil, input.prompt.utf8.count <= MirrorWire.maximumInput else {
        return failure("Invalid dispatch target or prompt size.")
      }
    case .send(let input):
      guard input.trailingEnter, !input.wait, !input.captureOutput, input.source == "argv",
        command.targetPaneID != nil,
        !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        input.text.utf8.count <= MirrorWire.maximumInput,
        DispatchInput(pane: input.selector.value, prompt: input.text).validationErrorMessage == nil
      else { return failure("Invalid shell input.") }
    case .create(let input):
      guard input.resource == "tab", input.background,
        !input.launch.profile.isEmpty,
        (input.launch.prompt?.utf8.count ?? 0) <= MirrorWire.maximumInput
      else { return failure("Choose a valid Host Profile and a prompt within the size limit.") }
    }
    return nil
  }

  private static func shellRefusal(
    _ input: MirrorShellInput, router: CLICommandRouter,
    authorize: @escaping @MainActor () -> Bool, protectInput: @MainActor (UUID) -> String?
  ) async -> MirrorJSON? {
    let catalog = await router.route(CommandEnvelope(output: .json, command: .list(.init())))
    guard catalog.ok, let data = catalog.data,
      let list = try? data.decode(as: ListCommandPayload.self),
      let target = list.items.first(where: { $0.pane.id == input.selector.value }),
      target.pane.agent == nil, target.task.status == .idle else {
      return failure("Shell input requires an idle task with no detected Agent. Refresh and try again.")
    }
    guard authorize(), !Task.isCancelled, let pane = UUID(uuidString: input.selector.value) else {
      return failure("The mirror no longer owns this pane.")
    }
    if let reason = protectInput(pane) { return failure(reason) }
    return nil
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
