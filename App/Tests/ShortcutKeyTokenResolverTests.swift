import Testing

@testable import supacode

@MainActor
struct ShortcutKeyTokenResolverTests {
  @Test func prefersLayoutBaseKeyOverShiftedCharacter() {
    let resolver = ShortcutKeyTokenResolver(
      keyboardLayoutProvider: .init(baseScalarForKeyCode: { _ in "[".unicodeScalars.first })
    )

    let token = resolver.resolveKeyToken(
      keyCode: 33,
      charactersIgnoringModifiers: "{"
    )

    #expect(token == "[")
  }

  @Test func fallsBackToCharactersIgnoringModifiersWhenLayoutUnavailable() {
    let resolver = ShortcutKeyTokenResolver(
      keyboardLayoutProvider: .init(baseScalarForKeyCode: { _ in nil })
    )

    let token = resolver.resolveKeyToken(
      keyCode: 33,
      charactersIgnoringModifiers: "{"
    )

    #expect(token == "{")
  }

  @Test func specialArrowAndReturnKeysUseStableTokens() {
    let resolver = ShortcutKeyTokenResolver(
      keyboardLayoutProvider: .init(baseScalarForKeyCode: { _ in "x".unicodeScalars.first })
    )

    #expect(resolver.resolveKeyToken(keyCode: 36, charactersIgnoringModifiers: nil) == "return")
    #expect(resolver.resolveKeyToken(keyCode: 123, charactersIgnoringModifiers: nil) == "arrow_left")
    #expect(resolver.resolveKeyToken(keyCode: 124, charactersIgnoringModifiers: nil) == "arrow_right")
    #expect(resolver.resolveKeyToken(keyCode: 125, charactersIgnoringModifiers: nil) == "arrow_down")
    #expect(resolver.resolveKeyToken(keyCode: 126, charactersIgnoringModifiers: nil) == "arrow_up")
  }

  @Test func numberRowAndNumpadUsePhysicalDigitTokens() {
    let resolver = ShortcutKeyTokenResolver(
      keyboardLayoutProvider: .init(baseScalarForKeyCode: { _ in nil })
    )

    #expect(resolver.resolveKeyToken(keyCode: 18, charactersIgnoringModifiers: "!") == "digit_1")
    #expect(resolver.resolveKeyToken(keyCode: 19, charactersIgnoringModifiers: "@") == "digit_2")
    #expect(resolver.resolveKeyToken(keyCode: 82, charactersIgnoringModifiers: "0") == "digit_0")
    #expect(resolver.resolveKeyToken(keyCode: 92, charactersIgnoringModifiers: "9") == "digit_9")
  }

  @Test func lowercasesLetterTokens() {
    let resolver = ShortcutKeyTokenResolver(
      keyboardLayoutProvider: .init(baseScalarForKeyCode: { _ in "A".unicodeScalars.first })
    )

    let token = resolver.resolveKeyToken(
      keyCode: 0,
      charactersIgnoringModifiers: "A"
    )

    #expect(token == "a")
  }
}
