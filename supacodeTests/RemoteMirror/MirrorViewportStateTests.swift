import Foundation
import Testing

@testable import supacode

@MainActor
struct MirrorViewportStateTests {
  @Test func styledArchiveIsBoundedAndStagedWithItsFrame() throws {
    var state = MirrorViewportState()
    let lease = UUID()
    let valid = MirrorStyledScrollback(bytes: Data("styled".utf8), rowOffset: 20)
    try state.stage(
      .init(styledScrollback: valid, text: "expected", sequence: 1, subscriptionID: lease))
    #expect(state.pendingStyledScrollback == valid)
    try state.receiveFrame(sequence: 1)
    try state.didPresent(sequence: 1)
    #expect(state.pendingStyledScrollback == nil)
    for invalid in [
      MirrorStyledScrollback(bytes: Data(), rowOffset: 1),
      MirrorStyledScrollback(bytes: Data([1]), rowOffset: -1),
      MirrorStyledScrollback(
        bytes: Data(repeating: 1, count: MirrorStyledScrollback.maximumBytes + 1), rowOffset: 1),
    ] {
      #expect(throws: MirrorProtocolError.invalidMessage) {
        try state.stage(
          .init(styledScrollback: invalid, text: "fallback", sequence: 2, subscriptionID: lease))
      }
    }
  }

  @Test func textChangesOnlyWhenTheMatchingTerminalFrameIsPresented() throws {
    var state = MirrorViewportState()
    let lease = UUID()
    try state.stage(.init(text: "earlier output", sequence: 1, subscriptionID: lease))
    #expect(state.text == nil)
    try state.receiveFrame(sequence: 1)
    #expect(state.text == nil)
    try state.didPresent(sequence: 1)
    #expect(state.text == "earlier output")
    try state.stage(.init(text: nil, sequence: 2, subscriptionID: lease))
    try state.receiveFrame(sequence: 2)
    #expect(state.text == "earlier output")
    try state.didPresent(sequence: 2)
    #expect(state.text == nil)
  }

  @Test func blankViewportIsVisibleAndMultibyteTextIsPreserved() throws {
    var state = MirrorViewportState()
    let lease = UUID()
    for (index, text) in ["", "中🌍e\u{301}\nwrapped row"].enumerated() {
      let sequence = UInt64(index + 1)
      try state.stage(.init(text: text, sequence: sequence, subscriptionID: lease))
      try state.receiveFrame(sequence: sequence)
      try state.didPresent(sequence: sequence)
      #expect(state.text == text)
    }
  }

  @Test func rejectsMissingOrMismatchedFrameAndOutOfOrderMetadata() throws {
    var state = MirrorViewportState()
    let lease = UUID()
    #expect(throws: MirrorProtocolError.invalidMessage) { try state.receiveFrame(sequence: 1) }
    try state.stage(.init(text: "first", sequence: 1, subscriptionID: lease))
    #expect(throws: MirrorProtocolError.invalidMessage) { try state.didPresent(sequence: 1) }
    #expect(throws: MirrorProtocolError.invalidMessage) {
      try state.stage(.init(text: "second", sequence: 2, subscriptionID: lease))
    }
    #expect(throws: MirrorProtocolError.invalidMessage) { try state.receiveFrame(sequence: 2) }
    try state.receiveFrame(sequence: 1)
    #expect(throws: MirrorProtocolError.invalidMessage) { try state.receiveFrame(sequence: 1) }
    #expect(throws: MirrorProtocolError.invalidMessage) { try state.didPresent(sequence: 2) }
    try state.didPresent(sequence: 1)
    #expect(throws: MirrorProtocolError.invalidMessage) {
      try state.stage(.init(text: "stale", sequence: 1, subscriptionID: lease))
    }
  }

  @Test func rejectsOversizedViewportAndNewConnectionStartsWithoutOldText() throws {
    var state = MirrorViewportState()
    let lease = UUID()
    #expect(throws: MirrorProtocolError.invalidMessage) {
      try state.stage(
        .init(
          text: String(repeating: "x", count: MirrorWire.maximumPayload / 8 + 1), sequence: 1, subscriptionID: lease))
    }
    try state.stage(.init(text: "previous connection", sequence: 1, subscriptionID: lease))
    try state.receiveFrame(sequence: 1)
    try state.didPresent(sequence: 1)
    state = MirrorViewportState()
    #expect(state.text == nil)
    try state.stage(.init(text: nil, sequence: 1, subscriptionID: UUID()))
    try state.receiveFrame(sequence: 1)
    try state.didPresent(sequence: 1)
    #expect(state.text == nil)
  }
}
