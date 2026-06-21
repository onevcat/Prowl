import Foundation
import Testing

@testable import supacode

internal struct TmuxTerminalControllerTests {
  @Test internal func reportsUnavailableWhenResolverFindsNoExecutable() {
    let controller = TmuxTerminalController(
      resolveExecutable: { nil },
      execute: { _, _ in TmuxCommandResult(stdout: "", stderr: "", exitCode: 0) }
    )

    #expect(controller.isAvailable == false)
  }

  @Test internal func resolvesFirstExecutableCandidate() {
    let probe = TmuxExecutableProbe(availablePath: "/usr/local/bin/tmux")

    let resolved = TmuxTerminalController.resolveExecutable(isExecutable: probe.isExecutable)

    #expect(resolved == URL(fileURLWithPath: "/usr/local/bin/tmux", isDirectory: false))
    #expect(
      probe.paths == [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
      ])
  }

  @Test internal func attachCommandUsesSharedShellQuoting() {
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, _ in TmuxCommandResult(stdout: "", stderr: "", exitCode: 0) }
    )

    let command = controller.attachCommand(
      for: TmuxTerminalTarget(
        socketURL: URL(fileURLWithPath: "/tmp/prowl's.sock", isDirectory: false),
        groupSession: "prowl-wt-test",
        clientSession: "prowl-tab-it's",
        cardID: TmuxCardID(rawValue: "card-quoted"),
        windowID: nil,
        paneID: nil
      )
    )

    #expect(
      command
        == "'/tmp/tmux' -S '/tmp/prowl'\"'\"'s.sock' attach-session -t 'prowl-tab-it'\"'\"'s'"
    )
  }

  @Test internal func createWindowWritesProwlMetadataToWindowOptions() async throws {
    let recorder = TmuxCommandRecorder()
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        await recorder.record(arguments)
        if arguments.contains("new-window") {
          return TmuxCommandResult(stdout: "@7 %9\n", stderr: "", exitCode: 0)
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let target = TmuxTerminalTarget.make(
      appNamespace: "prowl",
      worktreeID: "/tmp/repo/wt",
      tabID: TerminalTabID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
      cardID: TmuxCardID(rawValue: "card-7"),
      socketRoot: URL(fileURLWithPath: "/tmp/prowl-tmux", isDirectory: true)
    )
    let metadata = TmuxWindowMetadata(
      cardID: target.cardID,
      worktreeID: "/tmp/repo/wt",
      worktreePath: "/tmp/repo/wt",
      repositoryRoot: "/tmp/repo",
      createdAt: "2026-05-28T12:00:00Z"
    )

    _ = try await controller.createWindow(
      target: target,
      cwd: URL(fileURLWithPath: "/tmp/repo/wt", isDirectory: true),
      title: "wt 1",
      metadata: metadata
    )

    let arguments = await recorder.arguments
    #expect(arguments.containsSetWindowOption(name: "@prowl.managed", value: "1"))
    #expect(arguments.containsSetWindowOption(name: "@prowl.card_id", value: "card-7"))
    #expect(arguments.containsSetWindowOption(name: "@prowl.worktree_id", value: "/tmp/repo/wt"))
    #expect(arguments.containsSetWindowOption(name: "@prowl.worktree_path", value: "/tmp/repo/wt"))
    #expect(arguments.containsSetWindowOption(name: "@prowl.repository_root", value: "/tmp/repo"))
    #expect(arguments.containsSetWindowOption(name: "@prowl.created_at", value: "2026-05-28T12:00:00Z"))
    #expect(arguments.containsSetOption(target: "prowl-tab-111111111111", name: "mouse", value: "on"))
  }

  @Test internal func ensureGroupConfiguresProwlCopyModeBindings() async throws {
    let recorder = TmuxCommandRecorder()
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      userConfigPath: "/tmp/prowl-home/.config/prowl/tmux.conf",
      execute: { _, arguments in
        await recorder.record(arguments)
        if arguments.contains("has-session") {
          return TmuxCommandResult(stdout: "", stderr: "missing session", exitCode: 1)
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let target = TmuxTerminalTarget.make(
      appNamespace: "prowl",
      worktreeID: "/tmp/repo/wt",
      tabID: TerminalTabID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
      cardID: TmuxCardID(rawValue: "card-7"),
      socketRoot: URL(fileURLWithPath: "/tmp/prowl-tmux", isDirectory: true)
    )

    try await controller.ensureGroup(
      target: target,
      cwd: URL(fileURLWithPath: "/tmp/repo/wt", isDirectory: true)
    )

    let arguments = await recorder.arguments
    #expect(arguments.containsSetGlobalOption(name: "prefix2", value: "C-q"))
    #expect(arguments.containsBindKey(["C-q", "send-prefix", "-2"]))
    #expect(arguments.containsBindKey(["-T", "copy-mode-vi", "v", "send-keys", "-X", "begin-selection"]))
    #expect(
      arguments.containsBindKey([
        "-T", "copy-mode-vi", "y", "send-keys", "-X", "copy-pipe-and-cancel", "reattach-to-user-namespace pbcopy",
      ]))
    #expect(
      arguments.containsBindKey([
        "-T", "copy-mode-vi", "Enter", "send-keys", "-X", "copy-pipe-and-cancel",
        "reattach-to-user-namespace pbcopy",
      ]))
    #expect(arguments.containsSourceFile(path: "/tmp/prowl-home/.config/prowl/tmux.conf"))
  }

  @Test internal func ensureGroupReloadsProwlConfigForExistingSession() async throws {
    let recorder = TmuxCommandRecorder()
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      userConfigPath: "/tmp/prowl-home/.config/prowl/tmux.conf",
      execute: { _, arguments in
        await recorder.record(arguments)
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let target = TmuxTerminalTarget.make(
      appNamespace: "prowl",
      worktreeID: "/tmp/repo/wt",
      tabID: TerminalTabID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
      cardID: TmuxCardID(rawValue: "card-7"),
      socketRoot: URL(fileURLWithPath: "/tmp/prowl-tmux", isDirectory: true)
    )

    try await controller.ensureGroup(
      target: target,
      cwd: URL(fileURLWithPath: "/tmp/repo/wt", isDirectory: true)
    )

    let arguments = await recorder.arguments
    #expect(arguments.contains { $0.contains("has-session") })
    #expect(!arguments.contains { $0.contains("new-session") })
    #expect(arguments.containsSetGlobalOption(name: "prefix2", value: "C-q"))
    #expect(arguments.containsSourceFile(path: "/tmp/prowl-home/.config/prowl/tmux.conf"))
  }

  @Test internal func createWindowCleansUpWindowWhenMetadataWriteFails() async {
    let recorder = TmuxCommandRecorder()
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        await recorder.record(arguments)
        if arguments.contains("new-window") {
          return TmuxCommandResult(stdout: "@7 %9\n", stderr: "", exitCode: 0)
        }
        if arguments.contains("set-window-option") {
          return TmuxCommandResult(stdout: "", stderr: "metadata failed", exitCode: 1)
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let target = TmuxTerminalTarget.make(
      appNamespace: "prowl",
      worktreeID: "/tmp/repo/wt",
      tabID: TerminalTabID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!),
      cardID: TmuxCardID(rawValue: "card-7"),
      socketRoot: URL(fileURLWithPath: "/tmp/prowl-tmux", isDirectory: true)
    )
    let metadata = TmuxWindowMetadata(
      cardID: target.cardID,
      worktreeID: "/tmp/repo/wt",
      worktreePath: "/tmp/repo/wt",
      repositoryRoot: "/tmp/repo",
      createdAt: "2026-05-28T12:00:00Z"
    )

    await #expect(throws: TmuxTerminalControllerError.self) {
      _ = try await controller.createWindow(
        target: target,
        cwd: URL(fileURLWithPath: "/tmp/repo/wt", isDirectory: true),
        title: "wt 1",
        metadata: metadata
      )
    }

    let arguments = await recorder.arguments
    #expect(arguments.containsKillWindow(windowID: "@7"))
  }

  @Test internal func prepareExistingWindowSelectsWindowInFreshAttachSession() async throws {
    let recorder = TmuxCommandRecorder()
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        await recorder.record(arguments)
        if arguments.contains("display-message") {
          return TmuxCommandResult(stdout: "@21\n", stderr: "", exitCode: 0)
        }
        if arguments.contains("has-session") {
          return TmuxCommandResult(stdout: "", stderr: "missing session", exitCode: 1)
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let target = TmuxTerminalTarget.restored(
      socketURL: URL(fileURLWithPath: "/tmp/prowl.sock", isDirectory: false),
      tabID: TerminalTabID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!),
      cardID: TmuxCardID(rawValue: "card-21"),
      windowID: try #require(TmuxWindowID(rawValue: "@21")),
      paneID: nil
    )

    let prepared = try await controller.prepareExistingWindowForAttach(target: target)

    let arguments = await recorder.arguments
    #expect(prepared == target)
    #expect(arguments.contains { $0.contains("display-message") && $0.contains("@21") })
    #expect(arguments.contains { $0.contains("kill-session") && $0.contains("prowl-tab-222222222222") })
    #expect(arguments.contains { $0.contains("new-session") && $0.contains("prowl-tab-222222222222") })
    #expect(arguments.contains { $0.contains("link-window") && $0.contains("@21") })
    #expect(arguments.contains { $0.contains("select-window") && $0.contains("prowl-tab-222222222222:@21") })
    #expect(arguments.containsSetOption(target: "prowl-tab-222222222222", name: "mouse", value: "on"))
    #expect(
      arguments.contains {
        $0.contains("kill-window") && $0.contains { $0.contains("__prowl_client_bootstrap") }
      })
  }

  @Test internal func panePIDQueriesStoredTmuxPane() async throws {
    let recorder = TmuxCommandRecorder()
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        await recorder.record(arguments)
        return TmuxCommandResult(stdout: "77759\n", stderr: "", exitCode: 0)
      }
    )
    let target = TmuxTerminalTarget.restored(
      socketURL: URL(fileURLWithPath: "/tmp/prowl.sock", isDirectory: false),
      tabID: TerminalTabID(rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!),
      cardID: TmuxCardID(rawValue: "card-33"),
      windowID: try #require(TmuxWindowID(rawValue: "@33")),
      paneID: TmuxPaneID(rawValue: "%33")!
    )

    let pid = try await controller.panePID(for: target)

    let arguments = await recorder.arguments
    #expect(pid == 77759)
    #expect(
      arguments == [[
        "-S", "/tmp/prowl.sock",
        "display-message",
        "-p",
        "-t", "%33",
        "#{pane_pid}",
      ]]
    )
  }

  @Test internal func detachedCardScanFiltersVisibleWindowsAndReportsLegacyContainers() async throws {
    let separator = "\u{1F}"
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        if arguments.contains("list-sessions") {
          return TmuxCommandResult(
            stdout: [
              ["prowl-cards", "2", "prowl-cards"].joined(separator: separator),
              ["prowl-tab-111111111111", "2", "prowl-cards"].joined(separator: separator),
              ["prowl-wt-old", "1", "prowl-wt-old"].joined(separator: separator),
              ["prowl-tab-222222222222", "1", "prowl-wt-old"].joined(separator: separator),
            ].joined(separator: "\n"),
            stderr: "",
            exitCode: 0
          )
        }
        if arguments.contains("list-windows") {
          return TmuxCommandResult(
            stdout: [
              [
                "prowl-cards", "@21", "shell", "/tmp/repo/wt", "zsh", "", "1", "card-21",
                "/tmp/repo/wt", "/tmp/repo/wt", "/tmp/repo", "2026-05-28T12:00:01Z",
              ].joined(separator: separator),
              [
                "prowl-cards", "@22", "visible", "/tmp/repo/wt", "zsh", "", "1", "card-22",
                "/tmp/repo/wt", "/tmp/repo/wt", "/tmp/repo", "2026-05-28T12:00:00Z",
              ].joined(separator: separator),
            ].joined(separator: "\n"),
            stderr: "",
            exitCode: 0
          )
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )

    let visibleWindowID = try #require(TmuxWindowID(rawValue: "@22"))
    let snapshot = try await controller.detachedCardSnapshot(visibleWindowIDs: [visibleWindowID])

    #expect(snapshot.candidates.map(\.windowID.rawValue) == ["@21"])
    #expect(snapshot.diagnostics.count == 1)
    #expect(
      snapshot.diagnostics.first?.sessionNames == [
        "prowl-cards",
        "prowl-tab-111111111111",
        "prowl-tab-222222222222",
        "prowl-wt-old",
      ])
    #expect(
      snapshot.diagnostics.first?.windowCountsBySession == [
        "prowl-cards": 2,
        "prowl-tab-111111111111": 2,
        "prowl-tab-222222222222": 1,
        "prowl-wt-old": 1,
      ])
  }

  @Test internal func detachedCardScanDoesNotReportCurrentClientSessions() async throws {
    let separator = "\u{1F}"
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        if arguments.contains("list-sessions") {
          return TmuxCommandResult(
            stdout: [
              ["prowl-cards", "2", "prowl-cards"].joined(separator: separator),
              ["prowl-tab-111111111111", "2", "prowl-cards"].joined(separator: separator),
              ["prowl-tab-222222222222", "1", ""].joined(separator: separator),
            ].joined(separator: "\n"),
            stderr: "",
            exitCode: 0
          )
        }
        if arguments.contains("list-windows") {
          return TmuxCommandResult(
            stdout: [
              "prowl-cards", "@21", "shell", "/tmp/repo/wt", "zsh", "", "1", "card-21",
              "/tmp/repo/wt", "/tmp/repo/wt", "/tmp/repo", "2026-05-28T12:00:01Z",
            ].joined(separator: separator),
            stderr: "",
            exitCode: 0
          )
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )

    let snapshot = try await controller.detachedCardSnapshot(visibleWindowIDs: [])

    #expect(snapshot.candidates.map(\.windowID.rawValue) == ["@21"])
    #expect(snapshot.diagnostics.isEmpty)
  }

  @Test internal func killWindowAttemptsClientCleanupWhenKillWindowFails() async throws {
    let recorder = TmuxCommandRecorder()
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, arguments in
        await recorder.record(arguments)
        if arguments.contains("kill-window") {
          return TmuxCommandResult(stdout: "", stderr: "missing window", exitCode: 1)
        }
        return TmuxCommandResult(stdout: "", stderr: "", exitCode: 0)
      }
    )

    try await controller.killWindow(
      target: TmuxTerminalTarget(
        socketURL: URL(fileURLWithPath: "/tmp/prowl.sock", isDirectory: false),
        groupSession: "prowl-wt-test",
        clientSession: "prowl-tab-test",
        cardID: TmuxCardID(rawValue: "card-kill-window"),
        windowID: TmuxWindowID(rawValue: "@42"),
        paneID: nil
      )
    )

    let arguments = await recorder.arguments
    #expect(arguments.contains { $0.contains("kill-window") })
    #expect(arguments.contains { $0.contains("kill-session") })
  }

  @Test internal func killWindowPropagatesExecutorThrownErrors() async {
    let controller = TmuxTerminalController(
      executableURL: URL(fileURLWithPath: "/tmp/tmux", isDirectory: false),
      execute: { _, _ in throw TmuxExecutorTestError.boom }
    )

    await #expect(throws: TmuxExecutorTestError.self) {
      try await controller.killWindow(
        target: TmuxTerminalTarget(
          socketURL: URL(fileURLWithPath: "/tmp/prowl.sock", isDirectory: false),
          groupSession: "prowl-wt-test",
          clientSession: "prowl-tab-test",
          cardID: TmuxCardID(rawValue: "card-thrown-error"),
          windowID: TmuxWindowID(rawValue: "@42"),
          paneID: nil
        )
      )
    }
  }
}

private enum TmuxExecutorTestError: Error {
  case boom
}

private actor TmuxCommandRecorder {
  private var recordedArguments: [[String]] = []

  fileprivate var arguments: [[String]] {
    recordedArguments
  }

  fileprivate func record(_ arguments: [String]) {
    recordedArguments.append(arguments)
  }
}

extension [[String]] {
  fileprivate func containsSetOption(target: String, name: String, value: String) -> Bool {
    contains {
      $0.contains("set-option") && $0.contains("-t") && $0.contains(target) && $0.contains(name) && $0.contains(value)
    }
  }

  fileprivate func containsSetWindowOption(name: String, value: String) -> Bool {
    contains {
      $0 == ["-S", "/tmp/prowl-tmux/prowl.sock", "set-window-option", "-t", "@7", name, value]
    }
  }

  fileprivate func containsSetGlobalOption(name: String, value: String) -> Bool {
    contains {
      $0 == ["-S", "/tmp/prowl-tmux/prowl.sock", "set-option", "-g", name, value]
    }
  }

  fileprivate func containsKillWindow(windowID: String) -> Bool {
    contains {
      $0 == ["-S", "/tmp/prowl-tmux/prowl.sock", "kill-window", "-t", windowID]
    }
  }

  fileprivate func containsBindKey(_ suffix: [String]) -> Bool {
    contains {
      $0 == ["-S", "/tmp/prowl-tmux/prowl.sock", "bind-key"] + suffix
    }
  }

  fileprivate func containsSourceFile(path: String) -> Bool {
    contains {
      $0 == ["-S", "/tmp/prowl-tmux/prowl.sock", "source-file", path]
    }
  }
}

private final class TmuxExecutableProbe: @unchecked Sendable {
  private let availablePath: String
  private let lock = NSLock()
  private var recordedPaths: [String] = []

  fileprivate init(availablePath: String) {
    self.availablePath = availablePath
  }

  fileprivate var paths: [String] {
    lock.withLock {
      recordedPaths
    }
  }

  fileprivate func isExecutable(_ path: String) -> Bool {
    lock.withLock {
      recordedPaths.append(path)
    }
    return path == availablePath
  }
}
