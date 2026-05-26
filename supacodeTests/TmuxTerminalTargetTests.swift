import Foundation
import Testing

@testable import supacode

internal struct TmuxTerminalTargetTests {
  @Test internal func sessionNamesAreStableAndShellSafe() {
    let target = TmuxTerminalTarget.make(
      appNamespace: "prowl",
      worktreeID: "/Users/yam/Developer/Prowl",
      tabID: TerminalTabID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
      socketRoot: URL(fileURLWithPath: "/tmp/prowl-tmux", isDirectory: true)
    )

    #expect(target.groupSession.hasPrefix("prowl-wt-"))
    #expect(target.clientSession == "prowl-tab-111111111111")
    #expect(target.socketURL.path == "/tmp/prowl-tmux/prowl.sock")
  }

  @Test internal func tmuxIdsRejectInvalidPrefixes() {
    #expect(TmuxWindowID(rawValue: "@12") != nil)
    #expect(TmuxPaneID(rawValue: "%34") != nil)
    #expect(TmuxWindowID(rawValue: "%12") == nil)
    #expect(TmuxPaneID(rawValue: "@34") == nil)
    #expect(TmuxWindowID(rawValue: "@") == nil)
    #expect(TmuxPaneID(rawValue: "%") == nil)
    #expect(TmuxWindowID(rawValue: "@١٢") == nil)
    #expect(TmuxPaneID(rawValue: "%１２") == nil)
  }

  @Test internal func tmuxIdsRejectInvalidDecodedRawValues() {
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(TmuxWindowID.self, from: Data(#"{"rawValue":"%12"}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(TmuxWindowID.self, from: Data(#"{"rawValue":"@"}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(TmuxPaneID.self, from: Data(#"{"rawValue":"@34"}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(TmuxPaneID.self, from: Data(#"{"rawValue":"%"}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(TmuxWindowID.self, from: Data(#"{"rawValue":"@١٢"}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(TmuxPaneID.self, from: Data(#"{"rawValue":"%１２"}"#.utf8))
    }
  }
}
