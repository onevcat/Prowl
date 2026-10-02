import Carbon
import Foundation

@MainActor
struct ShortcutKeyTokenResolver {
  struct KeyboardLayoutProvider {
    let baseScalarForKeyCode: @MainActor @Sendable (UInt16) -> UnicodeScalar?

    @MainActor
    static var live: KeyboardLayoutProvider {
      KeyboardLayoutProvider { keyCode in
        ShortcutKeyTokenResolver.baseScalarFromCurrentKeyboardLayout(for: keyCode)
      }
    }
  }

  let keyboardLayoutProvider: KeyboardLayoutProvider

  init(keyboardLayoutProvider: KeyboardLayoutProvider = .live) {
    self.keyboardLayoutProvider = keyboardLayoutProvider
  }

  func resolveKeyToken(
    keyCode: UInt16,
    charactersIgnoringModifiers: String?
  ) -> String? {
    if let token = specialKeyToken(for: keyCode) {
      return token
    }

    if let token = physicalDigitToken(for: keyCode) {
      return token
    }

    if let scalar = keyboardLayoutProvider.baseScalarForKeyCode(keyCode),
      let token = normalizedToken(from: scalar)
    {
      return token
    }

    guard let fallbackScalar = charactersIgnoringModifiers?.trimmingCharacters(in: .whitespacesAndNewlines).first else {
      return nil
    }

    return String(fallbackScalar).lowercased()
  }

  private func specialKeyToken(for keyCode: UInt16) -> String? {
    switch keyCode {
    case 36, 76:
      return "return"
    case 123:
      return "arrow_left"
    case 124:
      return "arrow_right"
    case 125:
      return "arrow_down"
    case 126:
      return "arrow_up"
    default:
      return nil
    }
  }

  private func physicalDigitToken(for keyCode: UInt16) -> String? {
    switch keyCode {
    case 29, 82:
      return "digit_0"
    case 18, 83:
      return "digit_1"
    case 19, 84:
      return "digit_2"
    case 20, 85:
      return "digit_3"
    case 21, 86:
      return "digit_4"
    case 23, 87:
      return "digit_5"
    case 22, 88:
      return "digit_6"
    case 26, 89:
      return "digit_7"
    case 28, 91:
      return "digit_8"
    case 25, 92:
      return "digit_9"
    default:
      return nil
    }
  }

  private func normalizedToken(from scalar: UnicodeScalar) -> String? {
    let raw = String(scalar).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let token = raw.first else { return nil }
    return String(token).lowercased()
  }

  private static func baseScalarFromCurrentKeyboardLayout(for keyCode: UInt16) -> UnicodeScalar? {
    guard let layoutData = currentKeyboardLayoutData(),
      let bytes = CFDataGetBytePtr(layoutData)
    else {
      return nil
    }

    let keyboardLayout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
    var deadKeyState: UInt32 = 0
    let maxLength: Int = 4
    var actualLength: Int = 0
    var unicodeChars = [UniChar](repeating: 0, count: maxLength)

    let status = UCKeyTranslate(
      keyboardLayout,
      keyCode,
      UInt16(kUCKeyActionDisplay),
      0,
      UInt32(LMGetKbdType()),
      OptionBits(kUCKeyTranslateNoDeadKeysBit),
      &deadKeyState,
      maxLength,
      &actualLength,
      &unicodeChars
    )

    guard status == noErr, actualLength > 0 else {
      return nil
    }

    return UnicodeScalar(unicodeChars[0])
  }

  private static func currentKeyboardLayoutData() -> CFData? {
    if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let rawLayoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    {
      return unsafeBitCast(rawLayoutData, to: CFData.self)
    }

    if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
      let rawLayoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    {
      return unsafeBitCast(rawLayoutData, to: CFData.self)
    }

    return nil
  }
}
