import Testing

@testable import supacode

struct FocusedActionTests {
  @Test func equalWhenEnabledAndTokenMatchDespiteDifferentClosures() {
    // Two distinct closure instances with the same enabled flag and token must
    // compare equal so SwiftUI does not treat a no-op body run as a value change.
    let lhs = FocusedAction<Void>(isEnabled: true, token: "a") {}
    let rhs = FocusedAction<Void>(isEnabled: true, token: "a") {}
    #expect(lhs == rhs)
  }

  @Test func notEqualWhenEnabledDiffers() {
    let lhs = FocusedAction<Void>(isEnabled: true, token: "a") {}
    let rhs = FocusedAction<Void>(isEnabled: false, token: "a") {}
    #expect(lhs != rhs)
  }

  @Test func notEqualWhenTokenDiffers() {
    let lhs = FocusedAction<Void>(isEnabled: true, token: "a") {}
    let rhs = FocusedAction<Void>(isEnabled: true, token: "b") {}
    #expect(lhs != rhs)
  }

  @Test func nilTokensCompareEqual() {
    let lhs = FocusedAction<Void>(isEnabled: true, token: nil) {}
    let rhs = FocusedAction<Void>(isEnabled: true, token: nil) {}
    #expect(lhs == rhs)
  }

  @Test func callExecutesPerformWhenEnabled() {
    var ran = false
    let action = FocusedAction<Void>(isEnabled: true) { ran = true }
    action()
    #expect(ran)
  }

  @Test func callDoesNotExecutePerformWhenDisabled() {
    var ran = false
    let action = FocusedAction<Void>(isEnabled: false) { ran = true }
    action()
    #expect(!ran)
  }

  @Test func callForwardsInputValue() {
    var received: Int?
    let action = FocusedAction<Int>(isEnabled: true) { received = $0 }
    action(42)
    #expect(received == 42)
  }

  @Test func tokensOfDifferentHashableTypesCompareUnequal() {
    let lhs = FocusedAction<Void>(isEnabled: true, token: ["w1"]) {}
    let rhs = FocusedAction<Void>(isEnabled: true, token: ["w2"]) {}
    #expect(lhs != rhs)
  }
}
