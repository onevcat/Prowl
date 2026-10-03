import Foundation

struct MirrorScrollBoundsState {
  private(set) var bounds: MirrorScrollBounds?
  private var pending: MirrorMessage.ScrollStatePayload?
  private var receivedSequence: UInt64?
  private var presentedSequence: UInt64 = 0

  func canScroll(_ direction: MirrorMessage.ScrollDirection) -> Bool {
    (direction == .upward ? bounds?.atTop : bounds?.atBottom) != true
  }

  mutating func stage(_ payload: MirrorMessage.ScrollStatePayload) throws {
    guard pending == nil, payload.sequence > presentedSequence else { throw MirrorProtocolError.invalidMessage }
    pending = payload
  }

  mutating func receiveFrame(sequence: UInt64) throws {
    guard pending?.sequence == sequence, receivedSequence == nil else { throw MirrorProtocolError.invalidMessage }
    receivedSequence = sequence
  }

  mutating func didPresent(sequence: UInt64) throws {
    guard let pending, pending.sequence == sequence, receivedSequence == sequence else {
      throw MirrorProtocolError.invalidMessage
    }
    bounds = .init(atTop: pending.atTop, atBottom: pending.atBottom)
    presentedSequence = sequence
    self.pending = nil
    receivedSequence = nil
  }
}
