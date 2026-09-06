import AppKit
import Carbon
import ProwlCLIShared

/// Maps canonical CLI key tokens to macOS NSEvent parameters.
struct CLIKeySpec {
  let keyCode: UInt16
  let characters: String
  let charactersIgnoringModifiers: String
  let modifiers: NSEvent.ModifierFlags

  static func from(token: String) -> CLIKeySpec? {
    guard let descriptor = KeyTokens.descriptor(for: token),
      let base = baseSpec(for: descriptor.baseToken)
    else {
      return nil
    }

    var modifierFlags = eventModifiers(from: descriptor.modifiers)
    if base.usesFunctionModifier {
      modifierFlags.insert(.function)
    }

    let charactersIgnoringModifiers = base.charactersIgnoringModifiers
    let characters: String
    if usesControlCharacter(for: descriptor.modifiers),
      let controlCharacter = controlCharacter(for: descriptor.baseToken)
    {
      characters = controlCharacter
    } else if descriptor.modifiers.contains(.shift) {
      characters = shiftedCharacters(for: descriptor.baseToken) ?? charactersIgnoringModifiers
    } else {
      characters = charactersIgnoringModifiers
    }

    return CLIKeySpec(
      keyCode: base.keyCode,
      characters: characters,
      charactersIgnoringModifiers: charactersIgnoringModifiers,
      modifiers: modifierFlags
    )
  }

  private struct BaseSpec {
    let keyCode: UInt16
    let charactersIgnoringModifiers: String
    let usesFunctionModifier: Bool
  }

  private static let namedBaseSpecs: [String: BaseSpec] = [
    "enter": BaseSpec(
      keyCode: UInt16(kVK_Return),
      charactersIgnoringModifiers: "\r",
      usesFunctionModifier: false
    ),
    "esc": BaseSpec(
      keyCode: UInt16(kVK_Escape),
      charactersIgnoringModifiers: "\u{1B}",
      usesFunctionModifier: false
    ),
    "tab": BaseSpec(
      keyCode: UInt16(kVK_Tab),
      charactersIgnoringModifiers: "\t",
      usesFunctionModifier: false
    ),
    "backspace": BaseSpec(
      keyCode: UInt16(kVK_Delete),
      charactersIgnoringModifiers: "\u{7F}",
      usesFunctionModifier: false
    ),
    "delete-forward": BaseSpec(
      keyCode: UInt16(kVK_ForwardDelete),
      charactersIgnoringModifiers: String(UnicodeScalar(NSDeleteFunctionKey)!),
      usesFunctionModifier: true
    ),
    "insert": BaseSpec(
      keyCode: UInt16(kVK_Help),
      charactersIgnoringModifiers: String(UnicodeScalar(NSInsertFunctionKey)!),
      usesFunctionModifier: true
    ),
    "up": BaseSpec(
      keyCode: UInt16(kVK_UpArrow),
      charactersIgnoringModifiers: String(UnicodeScalar(NSUpArrowFunctionKey)!),
      usesFunctionModifier: true
    ),
    "down": BaseSpec(
      keyCode: UInt16(kVK_DownArrow),
      charactersIgnoringModifiers: String(UnicodeScalar(NSDownArrowFunctionKey)!),
      usesFunctionModifier: true
    ),
    "left": BaseSpec(
      keyCode: UInt16(kVK_LeftArrow),
      charactersIgnoringModifiers: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
      usesFunctionModifier: true
    ),
    "right": BaseSpec(
      keyCode: UInt16(kVK_RightArrow),
      charactersIgnoringModifiers: String(UnicodeScalar(NSRightArrowFunctionKey)!),
      usesFunctionModifier: true
    ),
    "pageup": BaseSpec(
      keyCode: UInt16(kVK_PageUp),
      charactersIgnoringModifiers: String(UnicodeScalar(NSPageUpFunctionKey)!),
      usesFunctionModifier: true
    ),
    "pagedown": BaseSpec(
      keyCode: UInt16(kVK_PageDown),
      charactersIgnoringModifiers: String(UnicodeScalar(NSPageDownFunctionKey)!),
      usesFunctionModifier: true
    ),
    "home": BaseSpec(
      keyCode: UInt16(kVK_Home),
      charactersIgnoringModifiers: String(UnicodeScalar(NSHomeFunctionKey)!),
      usesFunctionModifier: true
    ),
    "end": BaseSpec(
      keyCode: UInt16(kVK_End),
      charactersIgnoringModifiers: String(UnicodeScalar(NSEndFunctionKey)!),
      usesFunctionModifier: true
    ),
  ]

  private static let functionKeyMap: [String: (UInt16, Int)] = [
    "f1": (UInt16(kVK_F1), NSF1FunctionKey),
    "f2": (UInt16(kVK_F2), NSF2FunctionKey),
    "f3": (UInt16(kVK_F3), NSF3FunctionKey),
    "f4": (UInt16(kVK_F4), NSF4FunctionKey),
    "f5": (UInt16(kVK_F5), NSF5FunctionKey),
    "f6": (UInt16(kVK_F6), NSF6FunctionKey),
    "f7": (UInt16(kVK_F7), NSF7FunctionKey),
    "f8": (UInt16(kVK_F8), NSF8FunctionKey),
    "f9": (UInt16(kVK_F9), NSF9FunctionKey),
    "f10": (UInt16(kVK_F10), NSF10FunctionKey),
    "f11": (UInt16(kVK_F11), NSF11FunctionKey),
    "f12": (UInt16(kVK_F12), NSF12FunctionKey),
  ]

  private static let printableKeyCodes: [String: UInt16] = [
    "a": UInt16(kVK_ANSI_A),
    "b": UInt16(kVK_ANSI_B),
    "c": UInt16(kVK_ANSI_C),
    "d": UInt16(kVK_ANSI_D),
    "e": UInt16(kVK_ANSI_E),
    "f": UInt16(kVK_ANSI_F),
    "g": UInt16(kVK_ANSI_G),
    "h": UInt16(kVK_ANSI_H),
    "i": UInt16(kVK_ANSI_I),
    "j": UInt16(kVK_ANSI_J),
    "k": UInt16(kVK_ANSI_K),
    "l": UInt16(kVK_ANSI_L),
    "m": UInt16(kVK_ANSI_M),
    "n": UInt16(kVK_ANSI_N),
    "o": UInt16(kVK_ANSI_O),
    "p": UInt16(kVK_ANSI_P),
    "q": UInt16(kVK_ANSI_Q),
    "r": UInt16(kVK_ANSI_R),
    "s": UInt16(kVK_ANSI_S),
    "t": UInt16(kVK_ANSI_T),
    "u": UInt16(kVK_ANSI_U),
    "v": UInt16(kVK_ANSI_V),
    "w": UInt16(kVK_ANSI_W),
    "x": UInt16(kVK_ANSI_X),
    "y": UInt16(kVK_ANSI_Y),
    "z": UInt16(kVK_ANSI_Z),
    "0": UInt16(kVK_ANSI_0),
    "1": UInt16(kVK_ANSI_1),
    "2": UInt16(kVK_ANSI_2),
    "3": UInt16(kVK_ANSI_3),
    "4": UInt16(kVK_ANSI_4),
    "5": UInt16(kVK_ANSI_5),
    "6": UInt16(kVK_ANSI_6),
    "7": UInt16(kVK_ANSI_7),
    "8": UInt16(kVK_ANSI_8),
    "9": UInt16(kVK_ANSI_9),
    "space": UInt16(kVK_Space),
    "minus": UInt16(kVK_ANSI_Minus),
    "equal": UInt16(kVK_ANSI_Equal),
    "comma": UInt16(kVK_ANSI_Comma),
    "period": UInt16(kVK_ANSI_Period),
    "slash": UInt16(kVK_ANSI_Slash),
    "backslash": UInt16(kVK_ANSI_Backslash),
    "semicolon": UInt16(kVK_ANSI_Semicolon),
    "quote": UInt16(kVK_ANSI_Quote),
    "grave": UInt16(kVK_ANSI_Grave),
    "left-bracket": UInt16(kVK_ANSI_LeftBracket),
    "right-bracket": UInt16(kVK_ANSI_RightBracket),
  ]

  private static let shiftedCharacterMap: [String: String] = [
    "1": "!",
    "2": "@",
    "3": "#",
    "4": "$",
    "5": "%",
    "6": "^",
    "7": "&",
    "8": "*",
    "9": "(",
    "0": ")",
    "minus": "_",
    "equal": "+",
    "comma": "<",
    "period": ">",
    "slash": "?",
    "backslash": "|",
    "semicolon": ":",
    "quote": "\"",
    "grave": "~",
    "left-bracket": "{",
    "right-bracket": "}",
  ]

  private static func eventModifiers(from modifiers: [KeyModifier]) -> NSEvent.ModifierFlags {
    modifiers.reduce(into: NSEvent.ModifierFlags()) { result, modifier in
      switch modifier {
      case .cmd: result.insert(.command)
      case .shift: result.insert(.shift)
      case .opt: result.insert(.option)
      case .ctrl: result.insert(.control)
      }
    }
  }

  private static func baseSpec(for token: String) -> BaseSpec? {
    if let base = namedBaseSpecs[token] { return base }
    if let (keyCode, scalar) = functionKeyMap[token] {
      return BaseSpec(
        keyCode: keyCode,
        charactersIgnoringModifiers: String(UnicodeScalar(scalar)!),
        usesFunctionModifier: true
      )
    }
    return printableBaseSpec(for: token)
  }

  private static func printableBaseSpec(for token: String) -> BaseSpec? {
    guard let character = printableCharacter(for: token),
      let keyCode = printableKeyCode(for: token)
    else { return nil }

    return BaseSpec(
      keyCode: keyCode,
      charactersIgnoringModifiers: String(character),
      usesFunctionModifier: false
    )
  }

  private static func printableCharacter(for token: String) -> Character? {
    switch token {
    case "space": return " "
    case "minus": return "-"
    case "equal": return "="
    case "comma": return ","
    case "period": return "."
    case "slash": return "/"
    case "backslash": return "\\"
    case "semicolon": return ";"
    case "quote": return "'"
    case "grave": return "`"
    case "left-bracket": return "["
    case "right-bracket": return "]"
    default:
      guard token.count == 1 else { return nil }
      return token.first
    }
  }

  private static func printableKeyCode(for token: String) -> UInt16? {
    printableKeyCodes[token]
  }

  private static func shiftedCharacters(for token: String) -> String? {
    if token.count == 1, let character = token.first, character.isLetter {
      return String(character).uppercased()
    }

    return shiftedCharacterMap[token]
  }

  private static func usesControlCharacter(for modifiers: [KeyModifier]) -> Bool {
    let modifierSet = Set(modifiers)
    return modifierSet.contains(.ctrl) && modifierSet.isSubset(of: [.ctrl, .shift])
  }

  private static func controlCharacter(for token: String) -> String? {
    if token.count == 1, let scalar = token.unicodeScalars.first, scalar.properties.isAlphabetic {
      return String(UnicodeScalar(scalar.value & 0x1F)!)
    }

    switch token {
    case "left-bracket": return String(UnicodeScalar(27)!)
    case "backslash": return String(UnicodeScalar(28)!)
    case "right-bracket": return String(UnicodeScalar(29)!)
    case "6": return String(UnicodeScalar(30)!)
    case "minus": return String(UnicodeScalar(31)!)
    default: return nil
    }
  }
}
