import Foundation

/// Viewport text travels beside the VT frame and becomes visible with that frame's acknowledgement.
struct MirrorViewportState {
  private(set) var text: String?
  private var pending: MirrorMessage.ViewportPayload?
  var pendingText: String? { pending?.text }
  var pendingStyledScrollback: MirrorStyledScrollback? { pending?.styledScrollback }
  private var receivedSequence: UInt64?
  private var presentedSequence: UInt64 = 0

  mutating func stage(_ payload: MirrorMessage.ViewportPayload) throws {
    guard pending == nil, payload.sequence > presentedSequence,
      (payload.text?.utf8.count ?? 0) <= MirrorWire.maximumPayload / 8,
      payload.styledScrollback?.isValid != false
    else { throw MirrorProtocolError.invalidMessage }
    pending = payload
  }

  mutating func receiveFrame(sequence: UInt64) throws {
    guard pending?.sequence == sequence, receivedSequence == nil else {
      throw MirrorProtocolError.invalidMessage
    }
    receivedSequence = sequence
  }

  mutating func didPresent(sequence: UInt64) throws {
    guard let pending, pending.sequence == sequence, receivedSequence == sequence else {
      throw MirrorProtocolError.invalidMessage
    }
    text = pending.text
    presentedSequence = sequence
    self.pending = nil
    receivedSequence = nil
  }
}
