import AppKit
import Carbon
import Testing

@testable import supacode

struct CanvasDirectionalNewTerminalShortcutTests {
  @Test func leaderShortcutMatchesCommandT() {
    #expect(
      CanvasView.isDirectionalNewTerminalLeaderShortcut(
        keyCode: UInt16(kVK_ANSI_T),
        charactersIgnoringModifiers: nil,
        modifierFlags: [.command]
      )
    )
  }

  @Test func leaderShortcutRejectsShiftCommandT() {
    #expect(
      !CanvasView.isDirectionalNewTerminalLeaderShortcut(
        keyCode: UInt16(kVK_ANSI_T),
        charactersIgnoringModifiers: "t",
        modifierFlags: [.command, .shift]
      )
    )
  }

  @Test func directionalInputUsesCurrentDirectoryForLowercase() {
    let input = CanvasView.directionalNewTerminalInput(
      keyCode: UInt16(kVK_ANSI_H),
      characters: "h",
      charactersIgnoringModifiers: "h",
      modifierFlags: []
    )

    #expect(input?.direction == .left)
    #expect(input?.directoryMode == .currentDirectory)
  }

  @Test func directionalInputUsesWorktreeDirectoryForUppercase() {
    let input = CanvasView.directionalNewTerminalInput(
      keyCode: UInt16(kVK_ANSI_J),
      characters: "J",
      charactersIgnoringModifiers: "j",
      modifierFlags: [.shift]
    )

    #expect(input?.direction == .down)
    #expect(input?.directoryMode == .worktreeDirectory)
  }

  @Test func directionalInputFallsBackToShiftWhenCharactersAreMissing() {
    let input = CanvasView.directionalNewTerminalInput(
      keyCode: UInt16(kVK_ANSI_K),
      characters: nil,
      charactersIgnoringModifiers: nil,
      modifierFlags: [.shift]
    )

    #expect(input?.direction == .up)
    #expect(input?.directoryMode == .worktreeDirectory)
  }

  @Test func freestyleShortcutMatchesByKeyCodeWhenCharactersMissing() {
    #expect(
      CanvasView.isFreestyleNewTerminalChordKey(
        keyCode: UInt16(kVK_ANSI_N),
        charactersIgnoringModifiers: nil
      )
    )
  }

  @Test func freestyleShortcutMatchesFallbackCharacters() {
    #expect(
      CanvasView.isFreestyleNewTerminalChordKey(
        keyCode: 0,
        charactersIgnoringModifiers: "n"
      )
    )
  }

  @Test func directionalChordConsumableKeyMatchesFallbackCharacters() {
    #expect(
      CanvasDirectionalNewTerminalChordCoordinator.isDirectionalChordConsumableKey(
        keyCode: 0,
        charactersIgnoringModifiers: "k"
      )
    )
    #expect(
      CanvasDirectionalNewTerminalChordCoordinator.isDirectionalChordConsumableKey(
        keyCode: 0,
        charactersIgnoringModifiers: "N"
      )
    )
  }

  @MainActor
  @Test func chordCoordinatorBlocksTerminalInputOnlyWhenCanvasIsActiveAndAwaiting() {
    let coordinator = CanvasDirectionalNewTerminalChordCoordinator.shared
    defer {
      coordinator.setCanvasActive(false)
    }
    coordinator.setCanvasActive(false)
    coordinator.setAwaitingDirectionalChordKey(false)

    let event = directionalChordKeyEvent(
      keyCode: UInt16(kVK_ANSI_H),
      characters: "h",
      charactersIgnoringModifiers: "h"
    )

    #expect(!coordinator.shouldBlockTerminalInput(event))

    coordinator.setCanvasActive(true)
    coordinator.setAwaitingDirectionalChordKey(true)
    #expect(coordinator.shouldBlockTerminalInput(event))

    coordinator.setCanvasActive(false)
    #expect(!coordinator.shouldBlockTerminalInput(event))
  }

  private func directionalChordKeyEvent(
    keyCode: UInt16,
    characters: String,
    charactersIgnoringModifiers: String,
    modifierFlags: NSEvent.ModifierFlags = []
  ) -> NSEvent {
    guard let event = NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifierFlags,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: charactersIgnoringModifiers,
      isARepeat: false,
      keyCode: keyCode
    )
    else {
      fatalError("failed to create test key event")
    }
    return event
  }
}
