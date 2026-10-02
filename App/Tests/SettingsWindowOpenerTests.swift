import Testing

@testable import supacode

@MainActor
struct SettingsWindowOpenerTests {
  @Test func returnsFalseWhenNoOpenerRegistered() {
    let opener = SettingsWindowOpener()

    #expect(opener.hasRegisteredOpener == false)
    #expect(opener.openSettingsWindow() == false)
  }

  @Test func invokesRegisteredOpenerAndReturnsTrue() {
    let opener = SettingsWindowOpener()
    var callCount = 0
    opener.register { callCount += 1 }

    #expect(opener.hasRegisteredOpener == true)
    #expect(opener.openSettingsWindow() == true)
    #expect(callCount == 1)
  }

  @Test func reregisteringReplacesPreviousOpener() {
    let opener = SettingsWindowOpener()
    var firstCount = 0
    var secondCount = 0
    opener.register { firstCount += 1 }
    opener.register { secondCount += 1 }

    _ = opener.openSettingsWindow()

    #expect(firstCount == 0)
    #expect(secondCount == 1)
  }
}
