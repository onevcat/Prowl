import Foundation
import Testing
import UIKit

@testable import ProwlMirror_iOS

@MainActor
struct MirrorComposerTests {
  @Test func physicalReturnInsertsOnceThenSubmitsWithoutRemovingExistingNewlines() {
    let view = ComposerTextView()
    view.canSubmit = true
    view.text = "message\n"
    view.selectedRange = NSRange(location: 8, length: 0)
    var sends = 0
    view.onSubmit = { sends += 1 }
    let press = ReturnPress()
    let event = KeyEvent()
    view.pressesBegan([press], with: event)
    #expect(view.text == "message\n\n")
    #expect(sends == 0)
    view.pressesEnded([press], with: event)
    event.time = 0.2
    view.pressesBegan([press], with: event)
    #expect(view.text == "message\n")
    #expect(sends == 1)
    view.pressesBegan([press], with: event)
    #expect(sends == 1)
  }

  @Test func nativeMarkedTextInvalidatesReturnAndReportsComposition() {
    let view = ComposerTextView()
    var composing = false
    var observedText = ""
    view.onChange = { text, marked in
      observedText = text
      composing = marked
    }
    view.text = "hello\n"
    view.selectedRange = NSRange(location: 6, length: 0)
    view.gesture.record(
      before: "hello", selection: NSRange(location: 5, length: 0),
      after: view.text, afterSelection: view.selectedRange, time: 0)
    view.setMarkedText("中", selectedRange: NSRange(location: 1, length: 0))
    #expect(view.markedTextRange != nil)
    #expect(composing)
    #expect(observedText.hasSuffix("中"))
    view.unmarkText()
    #expect(!composing)
    #expect(
      view.gesture.consume(text: "hello\n", selection: NSRange(location: 6, length: 0), time: 0.1)
        == nil)
  }

  private final class ReturnKey: UIKey {
    override var keyCode: UIKeyboardHIDUsage { .keyboardReturnOrEnter }
    override var modifierFlags: UIKeyModifierFlags { [] }
    override var characters: String { "\r" }
    override var charactersIgnoringModifiers: String { "\r" }
  }
  private final class ReturnPress: UIPress {
    override var key: UIKey? { ReturnKey() }
  }
  private final class KeyEvent: UIPressesEvent {
    var time: TimeInterval = 0
    override var timestamp: TimeInterval { time }
  }
}
