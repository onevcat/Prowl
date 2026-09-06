import AppKit
import Foundation
import ProwlCLIShared

struct MirroredTerminalKey: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case enter
    case backspace
    case deleteForward
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case tab
    case escape
    case controlCharacter
  }

  let kind: Kind
  let keyCode: UInt16
  let characters: String
  let charactersIgnoringModifiers: String
  /// Raw value of `NSEvent.ModifierFlags` (device-independent only) to satisfy `Sendable`.
  let modifierFlagsRawValue: UInt
  let isRepeat: Bool

  var modifiers: NSEvent.ModifierFlags {
    NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
  }

  /// Key codes allowed to pass through even with the Command modifier held.
  private static let commandAllowedKeyCodes: Set<UInt16> = [
    51,  // backspace
    123,  // arrowLeft
    124,  // arrowRight
    125,  // arrowDown
    126,  // arrowUp
  ]

  init?(
    kind: Kind,
    keyCode: UInt16,
    characters: String,
    charactersIgnoringModifiers: String,
    modifiers: NSEvent.ModifierFlags,
    isRepeat: Bool
  ) {
    if modifiers.contains(.command), !Self.commandAllowedKeyCodes.contains(keyCode) { return nil }
    self.kind = kind
    self.keyCode = keyCode
    self.characters = characters
    self.charactersIgnoringModifiers = charactersIgnoringModifiers
    modifierFlagsRawValue = modifiers.intersection(.deviceIndependentFlagsMask).rawValue
    self.isRepeat = isRepeat
  }

  init?(event: NSEvent) {
    guard event.type == .keyDown else { return nil }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if modifiers.contains(.command), !Self.commandAllowedKeyCodes.contains(event.keyCode) { return nil }
    guard let kind = Self.kind(for: event, modifiers: modifiers) else { return nil }
    self.kind = kind
    keyCode = event.keyCode
    characters = event.characters ?? ""
    charactersIgnoringModifiers = event.charactersIgnoringModifiers ?? event.characters ?? ""
    modifierFlagsRawValue = modifiers.rawValue
    isRepeat = event.isARepeat
  }

  private static func kind(
    for event: NSEvent,
    modifiers: NSEvent.ModifierFlags
  ) -> Kind? {
    switch event.keyCode {
    case 36, 76: return .enter
    case 48: return .tab
    case 51: return .backspace
    case 117: return .deleteForward
    case 53: return .escape
    case 123: return .arrowLeft
    case 124: return .arrowRight
    case 125: return .arrowDown
    case 126: return .arrowUp
    default:
      break
    }

    if modifiers == [.control],
      let charactersIgnoringModifiers = event.charactersIgnoringModifiers,
      !charactersIgnoringModifiers.isEmpty
    {
      return .controlCharacter
    }

    return nil
  }

  func keyDownEvent(windowNumber: Int) -> NSEvent? {
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: windowNumber,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: charactersIgnoringModifiers,
      isARepeat: isRepeat,
      keyCode: keyCode
    )
  }

  func keyUpEvent(windowNumber: Int) -> NSEvent? {
    NSEvent.keyEvent(
      with: .keyUp,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: windowNumber,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: charactersIgnoringModifiers,
      isARepeat: false,
      keyCode: keyCode
    )
  }
}
