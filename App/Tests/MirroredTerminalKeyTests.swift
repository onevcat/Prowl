import AppKit
import Testing

@testable import supacode

struct MirroredTerminalKeyTests {
  @Test func enterEventNormalizes() throws {
    let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "\r",
      charactersIgnoringModifiers: "\r",
      isARepeat: false,
      keyCode: 36
    )

    let key = MirroredTerminalKey(event: try #require(event))

    #expect(key?.kind == .enter)
    #expect(key?.keyCode == 36)
  }

  @Test func commandModifiedEventsAreFilteredOut() throws {
    let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [.command],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "c",
      charactersIgnoringModifiers: "c",
      isARepeat: false,
      keyCode: 8
    )

    #expect(MirroredTerminalKey(event: try #require(event)) == nil)
  }

  @Test func controlCharacterEventNormalizes() throws {
    let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [.control],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "\u{03}",
      charactersIgnoringModifiers: "c",
      isARepeat: false,
      keyCode: 8
    )

    let key = MirroredTerminalKey(event: try #require(event))

    #expect(key?.kind == .controlCharacter)
    #expect(key?.charactersIgnoringModifiers == "c")
    #expect(key?.modifiers == [.control])
  }

  @Test func commandBackspaceIsAllowed() throws {
    let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [.command],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "\u{7F}",
      charactersIgnoringModifiers: "\u{7F}",
      isARepeat: false,
      keyCode: 51
    )

    let key = MirroredTerminalKey(event: try #require(event))

    #expect(key?.kind == .backspace)
    #expect(key?.modifiers == [.command])
  }

  @Test func commandArrowIsAllowed() throws {
    let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [.command],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "",
      charactersIgnoringModifiers: "",
      isARepeat: false,
      keyCode: 124
    )

    let key = MirroredTerminalKey(event: try #require(event))

    #expect(key?.kind == .arrowRight)
    #expect(key?.modifiers == [.command])
  }

  @Test func plainTextEventDoesNotNormalizeAsMirroredKey() throws {
    let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "a",
      charactersIgnoringModifiers: "a",
      isARepeat: false,
      keyCode: 0
    )

    #expect(MirroredTerminalKey(event: try #require(event)) == nil)
  }

  @Test func ghosttyTextIgnoresFlagsChangedEvents() throws {
    let event = NSEvent.keyEvent(
      with: .flagsChanged,
      location: .zero,
      modifierFlags: [.command],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "",
      charactersIgnoringModifiers: "",
      isARepeat: false,
      keyCode: 55
    )

    #expect(GhosttyEventText.characters(for: try #require(event)) == nil)
  }

  @Test func ghosttyTextReadsKeyEvents() throws {
    let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "a",
      charactersIgnoringModifiers: "a",
      isARepeat: false,
      keyCode: 0
    )

    #expect(GhosttyEventText.characters(for: try #require(event)) == "a")
  }
}
