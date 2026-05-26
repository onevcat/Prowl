import Testing

@testable import supacode

internal struct TmuxControlModeParserTests {
  @Test internal func parsesWindowNotifications() {
    let parser = TmuxControlModeParser()
    let events = parser.parseLines([
      "%session-changed $0 probe",
      "%window-add @1",
      "%window-renamed @1",
      "%session-window-changed $0 @1",
      "%window-close @0",
      "%exit",
    ])

    #expect(events == [
      .sessionChanged("$0", "probe"),
      .windowAdded(TmuxWindowID(rawValue: "@1")!),
      .windowRenamed(TmuxWindowID(rawValue: "@1")!),
      .sessionWindowChanged(sessionID: "$0", windowID: TmuxWindowID(rawValue: "@1")!),
      .windowClosed(TmuxWindowID(rawValue: "@0")!),
      .exit,
    ])
  }

  @Test internal func parsesCommandBlockOutput() {
    let parser = TmuxControlModeParser()
    let events = parser.parseLines([
      "%begin 1779800572 281 1",
      "@0 0 zsh 1",
      "@1 1 prowl-card 0",
      "%end 1779800572 281 1",
    ])

    #expect(events == [
      .commandOutput(commandNumber: 281, lines: [
        "@0 0 zsh 1",
        "@1 1 prowl-card 0",
      ]),
    ])
  }
}
