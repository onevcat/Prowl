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
    #expect(probe.paths == [
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
        windowID: nil,
        paneID: nil
      )
    )

    #expect(command == "'/tmp/tmux' -S '/tmp/prowl'\"'\"'s.sock' -CC attach-session -t 'prowl-tab-it'\"'\"'s'")
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
  fileprivate func containsSetGlobalOption(name: String, value: String) -> Bool {
    contains {
      $0 == ["-S", "/tmp/prowl-tmux/prowl.sock", "set-option", "-g", name, value]
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
