import ArgumentParser
import Foundation
import ProwlCLIShared

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

extension AgentNativeHookRuntime: ExpressibleByArgument {}

struct AgentsHookCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "_hook",
    shouldDisplay: false
  )

  @Argument var runtime: AgentNativeHookRuntime
  @Argument var nativeEvent: String
  /// Codex appends its native JSON payload as the final notifier argv.
  @Argument var payload: String?

  mutating func run() throws {
    let environment = ProcessInfo.processInfo.environment
    let lease = forwardingLease(environment: environment)
    let stdin = readBoundedStdin()
    if let input = try? makeInput(environment: environment, stdin: stdin) {
      let envelope = CommandEnvelope(output: .json, command: .agentsHook(input))
      _ = try? SocketTransportClient.send(envelope, timeoutMilliseconds: 250)
    }
    if runtime == .codex, let lease, let payload {
      execForwardedNotifier(lease.argv, payload: payload)
    }
    lease?.close()
  }

  func makeInput(
    environment: [String: String],
    stdin: Data
  ) throws -> AgentNativeHookInput {
    guard let token = environment[AgentNativeHookInput.tokenEnvironmentKey], !token.isEmpty else {
      throw ValidationError("Missing managed hook token.")
    }
    let nativePayload: Data
    switch runtime {
    case .claude, .copilot, .droid, .qoder, .pi, .omp, .opencode:
      guard payload == nil else { throw ValidationError("This runtime's hooks read JSON from stdin.") }
      nativePayload = stdin
    case .codex:
      guard let payload else { throw ValidationError("Codex hooks require a final JSON payload argument.") }
      nativePayload = Data(payload.utf8)
    }
    let signal = try AgentNativeHookDecoder.decode(
      runtime: runtime,
      nativeEvent: nativeEvent,
      payload: nativePayload
    )
    let input = AgentNativeHookInput(runtime: runtime, token: token, signal: signal)
    if let message = input.validationErrorMessage { throw ValidationError(message) }
    return input
  }

  private func readBoundedStdin() -> Data {
    // Codex is the only runtime that delivers its payload as a final argv value; every other
    // supported runtime writes JSON to the hook's stdin.
    guard runtime != .codex else { return Data() }
    var payload = Data()
    while payload.count <= AgentNativeHookDecoder.maximumPayloadBytes {
      let remaining = AgentNativeHookDecoder.maximumPayloadBytes + 1 - payload.count
      do {
        guard let chunk = try FileHandle.standardInput.read(upToCount: remaining),
          !chunk.isEmpty
        else { break }
        payload.append(chunk)
      } catch {
        break
      }
    }
    return payload
  }

  private func forwardingLease(
    environment: [String: String]
  ) -> CodexForwardingRecordLease? {
    guard runtime == .codex,
      let path = environment[AgentNativeHookInput.forwardRecordEnvironmentKey],
      !path.isEmpty
    else { return nil }
    return try? CodexForwardingRecordReader.open(
      URL(filePath: path, directoryHint: .notDirectory)
    )
  }

  private func execForwardedNotifier(_ argv: [String], payload: String) -> Never {
    unsetenv(AgentNativeHookInput.tokenEnvironmentKey)
    unsetenv(AgentNativeHookInput.forwardRecordEnvironmentKey)
    let arguments = argv + [payload]
    var pointers: [UnsafeMutablePointer<CChar>?] = []
    for argument in arguments {
      guard let pointer = strdup(argument) else {
        for allocated in pointers { free(allocated) }
        _exit(127)
      }
      pointers.append(pointer)
    }
    pointers.append(nil)
    execvp(pointers[0], &pointers)
    for pointer in pointers { free(pointer) }
    _exit(127)
  }
}
