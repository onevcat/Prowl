import Foundation
import Testing

@testable import supacode

struct CallerPaneResolverTests {
  @Test func resolvesDirectAndNestedCallerAncestry() {
    let pane = CallerPane(worktreeID: "wt", surfaceID: UUID())
    let parents: [pid_t: pid_t] = [400: 300, 300: 200, 200: 100]

    #expect(
      CallerPaneResolver.pane(
        forCallerProcess: 100,
        paneByShellPID: [100: pane],
        parentProcessID: { parents[$0] },
        processStartDate: { _ in nil }
      ) == pane
    )
    #expect(
      CallerPaneResolver.pane(
        forCallerProcess: 400,
        paneByShellPID: [100: pane],
        parentProcessID: { parents[$0] },
        processStartDate: { _ in nil }
      ) == pane
    )
  }

  @Test func resolvesFromAnAncestrySnapshotAfterTheCallerIsGone() throws {
    let pane = CallerPane(worktreeID: "wt", surfaceID: UUID())
    let callerStart = Date(timeIntervalSince1970: 100)
    let agentStart = Date(timeIntervalSince1970: 90)
    let identities = [
      CallerProcessIdentity(processID: 400, startedAt: callerStart),
      CallerProcessIdentity(processID: 300, startedAt: agentStart),
      CallerProcessIdentity(processID: 100, startedAt: nil),
    ]

    let resolved = try #require(
      CallerPaneResolver.pane(
        forCallerProcessAncestry: identities,
        paneByShellPID: [100: pane]
      )
    )

    #expect(resolved.surfaceID == pane.surfaceID)
    #expect(
      resolved.processAncestry == [
        AgentProcessGeneration(pid: 400, startedAt: callerStart),
        AgentProcessGeneration(pid: 300, startedAt: agentStart),
      ]
    )
  }

  @Test func unresolvedAndCyclicAncestryNeverGuess() {
    let focusedButUnrelated = CallerPane(worktreeID: "focused", surfaceID: UUID())

    #expect(
      CallerPaneResolver.pane(
        forCallerProcess: 400,
        paneByShellPID: [100: focusedButUnrelated],
        parentProcessID: { _ in nil },
        processStartDate: { _ in nil }
      ) == nil
    )
    #expect(
      CallerPaneResolver.pane(
        forCallerProcess: 400,
        paneByShellPID: [100: focusedButUnrelated],
        parentProcessID: { $0 },
        processStartDate: { _ in nil }
      ) == nil
    )
  }

  @Test func ancestryWalkIsBounded() {
    let pane = CallerPane(worktreeID: "wt", surfaceID: UUID())

    #expect(
      CallerPaneResolver.pane(
        forCallerProcess: 100,
        paneByShellPID: [67: pane],
        parentProcessID: { $0 - 1 },
        processStartDate: { _ in nil }
      ) == nil
    )
    #expect(
      CallerPaneResolver.pane(
        forCallerProcess: 100,
        paneByShellPID: [69: pane],
        parentProcessID: { $0 - 1 },
        processStartDate: { _ in nil }
      ) == pane
    )
  }

  // Codex's shared daemon keeps the TUI that started it as its parent. A command from any
  // other pane must not resolve to that starter pane through the daemon.
  @Test func walkStopsAtTheCodexDaemonInsteadOfReachingTheStarterPane() {
    let starterPane = CallerPane(worktreeID: "starter", surfaceID: UUID())
    // prowl(400) -> sh(350) -> daemon(300) -> starter TUI(200) -> starter shell(100)
    let parents: [pid_t: pid_t] = [400: 350, 350: 300, 300: 200, 200: 100]

    let walk = CallerPaneResolver.processWalk(
      forCallerProcess: 400,
      parentProcessID: { parents[$0] },
      processStartDate: { _ in nil },
      isCodexDaemon: { $0 == 300 }
    )

    #expect(walk.ancestry.map(\.processID) == [400, 350])
    #expect(walk.codexDaemon?.processID == 300)
    #expect(
      CallerPaneResolver.pane(
        forCallerProcess: 400,
        paneByShellPID: [100: starterPane],
        parentProcessID: { parents[$0] },
        processStartDate: { _ in nil },
        isCodexDaemon: { $0 == 300 }
      ) == nil
    )
  }

  @Test func codexDaemonCallerResolvesOnlyThroughItsMappedPane() {
    let starterPane = CallerPane(worktreeID: "starter", surfaceID: UUID())
    let drivingPane = CallerPane(worktreeID: "driver", surfaceID: UUID())
    let started = Date(timeIntervalSince1970: 1_000)
    let callerStart = Date(timeIntervalSince1970: 1_100)
    let daemon = CallerProcessIdentity(processID: 300, startedAt: nil)
    let ancestry = [CallerProcessIdentity(processID: 400, startedAt: callerStart)]
    let mapped = CLICommandContext(
      callerProcessID: 400,
      callerProcessAncestry: ancestry,
      codexDaemonCaller: CodexDaemonCaller(
        daemon: daemon, threadID: "thread",
        pane: CodexThreadPane(surfaceID: drivingPane.surfaceID, sessionStartedAt: started))
    )
    let unmapped = CLICommandContext(
      callerProcessID: 400,
      callerProcessAncestry: ancestry,
      codexDaemonCaller: CodexDaemonCaller(daemon: daemon, threadID: "thread", pane: nil)
    )
    let panes: [pid_t: CallerPane] = [100: starterPane, 500: drivingPane]

    let resolved = CallerPaneResolver.pane(for: mapped, paneByShellPID: panes)
    #expect(resolved?.surfaceID == drivingPane.surfaceID)
    #expect(resolved?.worktreeID == "driver")
    #expect(resolved?.codexSessionStartedAt == started)
    #expect(resolved?.processAncestry == [AgentProcessGeneration(pid: 400, startedAt: callerStart)])
    #expect(CallerPaneResolver.pane(for: unmapped, paneByShellPID: panes) == nil)
  }

  @Test func codexSessionProvesOnlyTheTUIThatStartedIt() {
    let tuiStart = Date(timeIntervalSince1970: 1_000)
    let tui = AgentProcessGeneration(pid: 200, startedAt: tuiStart)
    func caller(sessionStartedAt: Date?) -> CallerPane {
      CallerPane(worktreeID: "wt", surfaceID: UUID(), codexSessionStartedAt: sessionStartedAt)
    }

    #expect(caller(sessionStartedAt: tuiStart.addingTimeInterval(2)).belongs(to: tui))
    #expect(!caller(sessionStartedAt: tuiStart.addingTimeInterval(-60)).belongs(to: tui))
    #expect(!caller(sessionStartedAt: tuiStart.addingTimeInterval(600)).belongs(to: tui))
    #expect(!caller(sessionStartedAt: nil).belongs(to: tui))
    #expect(CallerPane(worktreeID: "wt", surfaceID: UUID(), processAncestry: [tui]).belongs(to: tui))
  }
}
