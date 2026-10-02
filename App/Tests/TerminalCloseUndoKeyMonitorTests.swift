import AppKit
import Testing

@testable import supacode

/// Window and responder guards for the no-terminal undo key (docs-ai 069.002).
@MainActor
struct TerminalCloseUndoKeyMonitorTests {
  @Test func eventsFromAnotherWindowAreNotDispatched() {
    let owner = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
    let other = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
    let event = keyEvent("z", [.command], windowNumber: other.windowNumber)
    #expect(event.window === other)

    #expect(!TerminalCloseUndoKeyMonitor.shouldDispatch(event, ownerWindow: owner))
    #expect(!TerminalCloseUndoKeyMonitor.shouldDispatch(event, ownerWindow: nil))
    #expect(TerminalCloseUndoKeyMonitor.shouldDispatch(event, ownerWindow: other))
  }

  @Test func aTextFieldFirstResponderKeepsItsOwnUndo() {
    let owner = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
    let event = keyEvent("z", [.command], windowNumber: owner.windowNumber)
    #expect(TerminalCloseUndoKeyMonitor.shouldDispatch(event, ownerWindow: owner))

    let field = NSTextView(frame: .zero)
    owner.contentView?.addSubview(field)
    owner.makeFirstResponder(field)
    #expect(owner.firstResponder === field)
    #expect(!TerminalCloseUndoKeyMonitor.shouldDispatch(event, ownerWindow: owner))
  }

  @Test func firstResponderKindsThatOwnUndo() {
    #expect(TerminalCloseUndoKeyMonitor.firstResponderOwnsUndo(NSTextView()))
    #expect(!TerminalCloseUndoKeyMonitor.firstResponderOwnsUndo(NSView()))
    #expect(!TerminalCloseUndoKeyMonitor.firstResponderOwnsUndo(nil))
  }

  private func keyEvent(_ characters: String, _ flags: NSEvent.ModifierFlags, windowNumber: Int) -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: flags,
      timestamp: 0,
      windowNumber: windowNumber,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters,
      isARepeat: false,
      keyCode: 6
    )!
  }
}
