import Foundation

@MainActor
final class MirrorCommandChannel {
  enum Failure: Error, Equatable, LocalizedError {
    case unavailable, timedOut, disconnected
    var errorDescription: String? {
      switch self {
      case .unavailable: String(localized: "The Host is not ready for another request.")
      case .timedOut: String(localized: "The Host did not confirm the request in time.")
      case .disconnected: String(localized: "The connection closed before Host confirmed the request.")
      }
    }
  }

  private struct Pending {
    let id: UUID
    let continuation: CheckedContinuation<MirrorJSON, any Error>
  }
  private let clock: any Clock<Duration>
  private let send: (MirrorMessage) -> Void
  private var pending: Pending?
  private var timeout: Task<Void, Never>?
  var isPending: Bool { pending != nil }

  init(clock: any Clock<Duration> = ContinuousClock(), send: @escaping (MirrorMessage) -> Void) {
    self.clock = clock
    self.send = send
  }

  func execute(_ command: MirrorCommandRequest.Command) async throws -> MirrorJSON {
    guard pending == nil else { throw Failure.unavailable }
    try Task.checkCancellation()
    let request = MirrorCommandRequest(requestID: UUID(), request: .init(command: command))
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending = Pending(id: request.requestID, continuation: continuation)
        let clock = clock
        timeout = Task { [weak self] in
          do { try await clock.sleep(for: .seconds(30)) } catch { return }
          guard self?.pending?.id == request.requestID else { return }
          self?.finish(.failure(Failure.timedOut))
        }
        send(.command(.init(subscriptionID: nil, commandRequest: request)))
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard self?.pending?.id == request.requestID else { return }
        self?.finish(.failure(CancellationError()))
      }
    }
  }

  func receive(_ response: MirrorCommandResponse) {
    guard response.requestID == pending?.id else { return }
    finish(.success(response.response))
  }

  func disconnect() { finish(.failure(Failure.disconnected)) }

  private func finish(_ result: Result<MirrorJSON, any Error>) {
    timeout?.cancel()
    timeout = nil
    let previous = pending
    pending = nil
    previous?.continuation.resume(with: result)
  }
}
