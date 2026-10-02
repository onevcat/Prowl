import Foundation
import Testing

@testable import supacode

struct BaguaWorkingIndicatorTests {
  @Test func framesUseFullTrigramSequence() {
    #expect(BaguaWorkingIndicator.frames == ["☰", "☱", "☲", "☳", "☴", "☵", "☶", "☷"])
  }

  @Test func frameSelectionLoopsByDuration() {
    let duration = BaguaWorkingIndicator.frameDuration

    #expect(BaguaWorkingIndicator.frame(at: Date(timeIntervalSinceReferenceDate: 0)) == "☰")
    #expect(BaguaWorkingIndicator.frame(at: Date(timeIntervalSinceReferenceDate: duration)) == "☱")
    #expect(BaguaWorkingIndicator.frame(at: Date(timeIntervalSinceReferenceDate: duration * 7)) == "☷")
    #expect(BaguaWorkingIndicator.frame(at: Date(timeIntervalSinceReferenceDate: duration * 8)) == "☶")
    #expect(BaguaWorkingIndicator.frame(at: Date(timeIntervalSinceReferenceDate: duration * 13)) == "☱")
    #expect(BaguaWorkingIndicator.frame(at: Date(timeIntervalSinceReferenceDate: duration * 14)) == "☰")
  }
}
