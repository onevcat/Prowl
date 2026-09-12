import Foundation
import Testing

@testable import ProwlMirror_iOS

struct MirrorReturnGestureTests {
  @Test func onlyRemovesItsOwnNewlineAtTheIntervalBoundary() {
    var gesture = MirrorReturnGesture()
    gesture.record(
      before: "中\n", selection: NSRange(location: 2, length: 0),
      after: "中\n\n", afterSelection: NSRange(location: 3, length: 0), time: 1)
    #expect(
      gesture.consume(
        text: "中\n\n", selection: NSRange(location: 3, length: 0),
        time: 1 + MirrorReturnGesture.interval) == "中\n")
    #expect(
      gesture.consume(text: "中\n\n", selection: NSRange(location: 3, length: 0), time: 0.35) == nil)
  }

  @Test func timeoutEditingSelectionAndCancellationInvalidateThePair() {
    for scenario in 0..<5 {
      var gesture = MirrorReturnGesture()
      gesture.record(
        before: "hello", selection: NSRange(location: 5, length: 0),
        after: "hello\n", afterSelection: NSRange(location: 6, length: 0), time: 1)
      if scenario == 1 {
        gesture.validate(text: "changed", selection: NSRange(location: 7, length: 0))
      }
      if scenario == 2 {
        gesture.validate(text: "hello\n", selection: NSRange(location: 0, length: 0))
      }
      if scenario == 3 { gesture.cancel() }
      let now = scenario == 0 ? 1.351 : (scenario == 4 ? 0.9 : 1.1)
      #expect(
        gesture.consume(text: "hello\n", selection: NSRange(location: 6, length: 0), time: now)
          == nil)
    }
  }

  @Test func selectedTextAndEmojiUseCorrectUTF16Ranges() {
    var gesture = MirrorReturnGesture()
    gesture.record(
      before: "😀old!", selection: NSRange(location: 2, length: 3),
      after: "😀\n!", afterSelection: NSRange(location: 3, length: 0), time: 0)
    #expect(
      gesture.consume(text: "😀\n!", selection: NSRange(location: 3, length: 0), time: 0.2) == "😀!")
    gesture.record(
      before: "😀", selection: NSRange(location: 1, length: 0),
      after: "😀\n", afterSelection: NSRange(location: 2, length: 0), time: 0)
    #expect(
      gesture.consume(text: "😀\n", selection: NSRange(location: 2, length: 0), time: 0.2) == nil)
  }
}
