import Foundation
import Testing

@testable import supacode

internal struct TmuxCardRecoveryTests {
  @Test internal func rawRecordBuildsManagedCandidateWithRuntimeFallbackTitle() throws {
    let record = TmuxRawWindowRecord(
      sessionName: "prowl-cards",
      windowID: "@21",
      windowName: "shell",
      activePath: "/Users/yam/Developer/Prowl",
      activeCommand: "zsh",
      activeTitle: "",
      managed: "1",
      cardID: "card-21",
      worktreeID: "/Users/yam/Developer/Prowl/.worktrees/feature",
      worktreePath: "/Users/yam/Developer/Prowl/.worktrees/feature",
      repositoryRoot: "/Users/yam/Developer/Prowl",
      createdAt: "2026-05-28T12:00:00Z"
    )

    let candidate = try #require(TmuxDetachedCardCandidate(record: record))

    #expect(candidate.id.rawValue == "prowl.sock:@21")
    #expect(candidate.windowID.rawValue == "@21")
    #expect(candidate.paneID == nil)
    #expect(candidate.cardID.rawValue == "card-21")
    #expect(candidate.runtimeTitle == "shell")
    #expect(candidate.activePath == "/Users/yam/Developer/Prowl")
  }

  @Test internal func rawRecordRejectsUnmanagedBootstrapAndInvalidWindowIDs() {
    let unmanaged = TmuxRawWindowRecord(
      sessionName: "prowl-cards",
      windowID: "@21",
      windowName: "shell",
      activePath: "/tmp",
      activeCommand: "zsh",
      activeTitle: "zsh",
      managed: "0",
      cardID: "card-21",
      worktreeID: "/tmp/wt",
      worktreePath: "/tmp/wt",
      repositoryRoot: "/tmp",
      createdAt: "2026-05-28T12:00:00Z"
    )
    let bootstrap = TmuxRawWindowRecord(
      sessionName: "prowl-cards",
      windowID: "@22",
      windowName: "__prowl_bootstrap",
      activePath: "/tmp",
      activeCommand: "zsh",
      activeTitle: "zsh",
      managed: "1",
      cardID: "card-22",
      worktreeID: "/tmp/wt",
      worktreePath: "/tmp/wt",
      repositoryRoot: "/tmp",
      createdAt: "2026-05-28T12:00:00Z"
    )
    let invalidID = TmuxRawWindowRecord(
      sessionName: "prowl-cards",
      windowID: "%22",
      windowName: "shell",
      activePath: "/tmp",
      activeCommand: "zsh",
      activeTitle: "zsh",
      managed: "1",
      cardID: "card-22",
      worktreeID: "/tmp/wt",
      worktreePath: "/tmp/wt",
      repositoryRoot: "/tmp",
      createdAt: "2026-05-28T12:00:00Z"
    )

    #expect(TmuxDetachedCardCandidate(record: unmanaged) == nil)
    #expect(TmuxDetachedCardCandidate(record: bootstrap) == nil)
    #expect(TmuxDetachedCardCandidate(record: invalidID) == nil)
  }

  @Test internal func presentationUsesRepositoryTitleDisplayPathAndRuntimeTitle() throws {
    let candidate = try #require(TmuxDetachedCardCandidate(record: TmuxRawWindowRecord(
      sessionName: "prowl-cards",
      windowID: "@21",
      windowName: "shell",
      activePath: "/Users/yam/Developer/Prowl/.worktrees/feature",
      activeCommand: "zsh",
      activeTitle: "codex",
      managed: "1",
      cardID: "card-21",
      worktreeID: "/Users/yam/Developer/Prowl/.worktrees/feature",
      worktreePath: "/Users/yam/Developer/Prowl/.worktrees/feature",
      repositoryRoot: "/Users/yam/Developer/Prowl",
      createdAt: "2026-05-28T12:00:00Z"
    )))

    let presentation = TmuxDetachedCardPresentation(
      candidate: candidate,
      repositoryName: "Prowl",
      homePath: "/Users/yam"
    )

    #expect(presentation.title == "Prowl / feature")
    #expect(presentation.subtitleLines == [
      "cwd: ~/Developer/Prowl/.worktrees/feature",
      "title: codex",
      "window: @21  card: card-21",
      "created: 2026-05-28T12:00:00Z",
    ])
  }
}
