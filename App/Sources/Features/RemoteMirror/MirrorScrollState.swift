import Foundation
import Observation

@MainActor
@Observable
final class MirrorScrollState {
  private(set) var requestID: UUID?
  private(set) var completedRequestID: UUID?
  private(set) var error: String?
  var isLoading: Bool { requestID != nil }
  @ObservationIgnored private var presentedSequence: UInt64 = 0
  @ObservationIgnored private var baseline: UInt64 = 0
  @ObservationIgnored private var resultSequence: UInt64?
  @ObservationIgnored private var timeout: Task<Void, Never>?
  @ObservationIgnored private let clock: any Clock<Duration>

  init(clock: any Clock<Duration> = ContinuousClock()) { self.clock = clock }

  func begin() -> UUID? {
    guard requestID == nil else { return nil }
    let id = UUID()
    requestID = id
    baseline = presentedSequence
    resultSequence = nil
    error = nil
    let clock = clock
    timeout = Task { [weak self] in
      do { try await clock.sleep(for: .seconds(5)) } catch { return }
      guard let self, self.requestID == id else { return }
      self.fail(
        String(localized: "Scrolling timed out. The Host may have moved; check the live view before trying again."))
    }
    return id
  }

  func receiveResult(requestID: UUID, sequence: UInt64) {
    guard self.requestID == requestID else { return }
    guard sequence > baseline else {
      fail(String(localized: "Host returned an invalid scroll result."))
      return
    }
    resultSequence = sequence
    finishIfPresented()
  }

  func didPresent(sequence: UInt64) {
    presentedSequence = max(presentedSequence, sequence)
    finishIfPresented()
  }

  func fail(_ message: String) {
    cancel()
    error = message
  }

  func cancel() {
    timeout?.cancel()
    timeout = nil
    requestID = nil
    resultSequence = nil
  }

  func reset() {
    cancel()
    completedRequestID = nil
    presentedSequence = 0
    baseline = 0
    error = nil
  }

  private func finishIfPresented() {
    guard let resultSequence, presentedSequence >= resultSequence else { return }
    completedRequestID = requestID
    cancel()
  }
}
