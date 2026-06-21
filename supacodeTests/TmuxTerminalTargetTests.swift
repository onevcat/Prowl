import Foundation
import Testing

@testable import supacode

internal struct TmuxTerminalTargetTests {
  @Test internal func targetUsesGlobalCardContainerAndStableCardID() throws {
    let tabID = TerminalTabID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let cardID = TmuxCardID(rawValue: "card-111111111111")

    let target = TmuxTerminalTarget.make(
      appNamespace: "prowl",
      worktreeID: "/Users/yam/Developer/Prowl",
      tabID: tabID,
      cardID: cardID,
      socketRoot: URL(fileURLWithPath: "/tmp/prowl-tmux", isDirectory: true)
    )

    #expect(target.groupSession == "prowl-cards")
    #expect(target.clientSession == "prowl-tab-111111111111")
    #expect(target.cardID == cardID)
    #expect(target.socketURL.path == "/tmp/prowl-tmux/prowl.sock")
  }

  @Test internal func restoredTargetKeepsWindowCardIDAndUsesNewClientSession() throws {
    let tabID = TerminalTabID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
    let target = TmuxTerminalTarget.restored(
      socketURL: URL(fileURLWithPath: "/tmp/prowl-tmux/prowl.sock", isDirectory: false),
      tabID: tabID,
      cardID: TmuxCardID(rawValue: "card-original"),
      windowID: TmuxWindowID(rawValue: "@21")!,
      paneID: TmuxPaneID(rawValue: "%9")!
    )

    #expect(target.groupSession == "prowl-cards")
    #expect(target.clientSession == "prowl-tab-222222222222")
    #expect(target.cardID.rawValue == "card-original")
    #expect(target.windowID?.rawValue == "@21")
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
