import Foundation
import Testing

@testable import Prowl

@MainActor
struct MirrorScrollBoundsStateTests {
  @Test func boundariesCommitOnlyWithMatchingPresentedFrame() throws {
    var state = MirrorScrollBoundsState()
    let lease = UUID()
    #expect(state.canScroll(.upward) && state.canScroll(.downward))
    try state.stage(.init(atTop: true, atBottom: false, sequence: 1, subscriptionID: lease))
    try state.receiveFrame(sequence: 1)
    #expect(state.canScroll(.upward))
    try state.didPresent(sequence: 1)
    #expect(!state.canScroll(.upward) && state.canScroll(.downward))
    try state.stage(.init(atTop: false, atBottom: true, sequence: 2, subscriptionID: lease))
    try state.receiveFrame(sequence: 2)
    try state.didPresent(sequence: 2)
    #expect(state.canScroll(.upward) && !state.canScroll(.downward))
    try state.stage(.init(atTop: nil, atBottom: nil, sequence: 3, subscriptionID: lease))
    try state.receiveFrame(sequence: 3)
    try state.didPresent(sequence: 3)
    #expect(state.canScroll(.upward) && state.canScroll(.downward))
  }

  @Test func rejectsMissingDuplicateAndMismatchedMetadata() throws {
    var state = MirrorScrollBoundsState()
    #expect(throws: MirrorProtocolError.self) { try state.receiveFrame(sequence: 1) }
    let payload = MirrorMessage.ScrollStatePayload(atTop: true, atBottom: true, sequence: 1, subscriptionID: UUID())
    try state.stage(payload)
    #expect(throws: MirrorProtocolError.self) { try state.stage(payload) }
    #expect(throws: MirrorProtocolError.self) { try state.receiveFrame(sequence: 2) }
    #expect(throws: MirrorProtocolError.self) { try state.didPresent(sequence: 1) }
    try state.receiveFrame(sequence: 1)
    #expect(throws: MirrorProtocolError.self) { try state.receiveFrame(sequence: 1) }
    #expect(throws: MirrorProtocolError.self) { try state.didPresent(sequence: 2) }
    try state.didPresent(sequence: 1)
    #expect(!state.canScroll(.upward) && !state.canScroll(.downward))
    #expect(throws: MirrorProtocolError.self) { try state.stage(payload) }
    state = MirrorScrollBoundsState()
    #expect(state.canScroll(.upward) && state.canScroll(.downward))
    try state.stage(payload)
  }
}
