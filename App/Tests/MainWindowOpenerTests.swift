import Testing

@testable import supacode

@MainActor
struct MainWindowOpenerTests {
  @Test func returnsFalseWhenNoOpenerRegistered() {
    let opener = MainWindowOpener()
    #expect(opener.hasRegisteredOpener == false)
    #expect(opener.openMainWindow() == false)
  }

  @Test func invokesRegisteredOpenerAndReturnsTrue() {
    let opener = MainWindowOpener()
    var callCount = 0
    opener.register { callCount += 1 }
    #expect(opener.hasRegisteredOpener == true)
    #expect(opener.openMainWindow() == true)
    #expect(callCount == 1)
  }

  @Test func reregisteringReplacesPreviousOpener() {
    let opener = MainWindowOpener()
    var firstCount = 0
    var secondCount = 0
    opener.register { firstCount += 1 }
    opener.register { secondCount += 1 }
    _ = opener.openMainWindow()
    #expect(firstCount == 0)
    #expect(secondCount == 1)
  }
}
