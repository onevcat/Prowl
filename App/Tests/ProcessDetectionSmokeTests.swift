import Darwin
import Foundation
import Testing

@testable import Prowl

struct ProcessDetectionSmokeTests {
  @Test func readsCurrentProcessArguments() throws {
    let pid = getpid()

    let argv0 = try #require(ProcessDetection.processArgv0Name(pid: pid))
    let cmdline = try #require(ProcessDetection.processCommandLine(pid: pid))
    let info = try #require(ProcessDetection.processBSDInfo(pid: pid))
    let comm = try #require(ProcessDetection.comm(from: info))

    #expect(!argv0.isEmpty)
    #expect(!cmdline.isEmpty)
    #expect(!comm.isEmpty)
  }

  @Test func parsesEnvironmentAfterArgvInProcargs2() {
    var buffer: [UInt8] = []
    withUnsafeBytes(of: Int32(2)) { buffer.append(contentsOf: $0) }
    for string in ["/usr/bin/prowl", "", "", "prowl", "agents", "CODEX_THREAD_ID=abc", "PATH=/bin"] {
      buffer.append(contentsOf: Array(string.utf8))
      buffer.append(0)
    }

    #expect(ProcessDetection.procargs2Argv(buffer) == ["prowl", "agents"])
    #expect(ProcessDetection.procargs2Environment(buffer) == ["CODEX_THREAD_ID=abc", "PATH=/bin"])
  }

  @Test func emptyArgumentsDoNotShiftTheEnvironmentBoundary() {
    var buffer: [UInt8] = []
    withUnsafeBytes(of: Int32(3)) { buffer.append(contentsOf: $0) }
    for string in ["/usr/bin/prowl", "", "prowl", "", "list", "CODEX_THREAD_ID=abc", "PATH=/bin"] {
      buffer.append(contentsOf: string.utf8)
      buffer.append(0)
    }

    #expect(ProcessDetection.procargs2Argv(buffer) == ["prowl", "", "list"])
    #expect(ProcessDetection.procargs2Environment(buffer) == ["CODEX_THREAD_ID=abc", "PATH=/bin"])
  }

  // The kernel hides the environment of Apple platform binaries (`/bin/sleep`), so the test
  // reads its own host process, which, like the `prowl` CLI, is not one.
  @Test func readsAProcessLaunchEnvironmentValue() throws {
    let home = try #require(ProcessInfo.processInfo.environment["HOME"])

    #expect(ProcessDetection.processEnvironmentValue(pid: getpid(), name: "HOME") == home)
    #expect(ProcessDetection.processEnvironmentValue(pid: getpid(), name: "HOM") == nil)
    #expect(ProcessDetection.processEnvironmentValue(pid: -1, name: "HOME") == nil)
  }

  @Test func recognizesOnlyTheManagedCodexDaemon() {
    #expect(
      ProcessDetection.isCodexManagedDaemon(arguments: [
        "codex", "app-server", "--listen", "unix://", "--managed-daemon",
      ]))
    #expect(!ProcessDetection.isCodexManagedDaemon(arguments: ["codex", "app-server", "--listen", "stdio://"]))
    #expect(!ProcessDetection.isCodexManagedDaemon(arguments: ["codex", "--yolo"]))
    #expect(!ProcessDetection.isCodexManagedDaemon(pid: getpid()))
  }

  @Test func listsCurrentProcessGroupWithoutScanningAllProcesses() {
    let pids = ProcessDetection.processGroupPIDs(getpgrp())

    #expect(pids.contains(getpid()))
  }

  // A Codex daemon inherits the tty of the pane that started it; the tty is revoked when that
  // pane closes. The inventory names the failure; the strict wrapper still rejects it.
  @Test func revokedTerminalIsReportedAsAnUnreadableDescriptor() throws {
    var primary: Int32 = -1
    var secondary: Int32 = -1
    #expect(openpty(&primary, &secondary, nil, nil, nil) == 0)
    defer {
      close(secondary)
      close(primary)
    }
    let terminal = try #require(ttyname(secondary).map { String(cString: $0) })
    #expect(revoke(terminal) == 0)
    let url = FileManager.default.temporaryDirectory.appending(path: "prowl-revoked-\(UUID().uuidString).jsonl")
    FileManager.default.createFile(atPath: url.path, contents: Data())
    let descriptor = open(url.path, O_WRONLY)
    #expect(descriptor >= 0)
    defer {
      close(descriptor)
      try? FileManager.default.removeItem(at: url)
    }

    let inventory = try #require(ProcessDetection.openFileInventory(pid: getpid()))
    var complete = true
    _ = ProcessDetection.openFilePaths(pid: getpid(), complete: &complete)

    #expect(inventory.failures.contains(ENOENT))
    #expect(inventory.paths.contains { URL(fileURLWithPath: $0).lastPathComponent == url.lastPathComponent })
    #expect(!complete)
  }

  @Test func missingProcessDoesNotReturnACompleteInventory() {
    var complete = true
    #expect(ProcessDetection.openFilePaths(pid: -1, complete: &complete).isEmpty)
    #expect(!complete)
    #expect(ProcessDetection.openFileInventory(pid: -1) == nil)
  }

  // MARK: - The launcher-hosted descendant walk

  /// A fake process tree for the walk, so its traversal rules can be checked without
  /// spawning one. `tree` maps a pid to its children.
  private func walkSource(
    tree: [pid_t: [pid_t]],
    agents: Set<pid_t> = [],
    launchers: Set<pid_t> = []
  ) -> ProcessDetection.HostedWalkSource {
    ProcessDetection.HostedWalkSource(
      children: { tree[$0] ?? [] },
      describe: { pid in
        if agents.contains(pid) {
          return ForegroundProcess(
            pid: pid, name: "claude", argv0: "/usr/local/bin/claude", cmdline: "claude",
            arguments: ["/usr/local/bin/claude"]
          )
        }
        if launchers.contains(pid) {
          return ForegroundProcess(
            pid: pid, name: "node", argv0: "node", cmdline: "node /opt/homebrew/bin/happy",
            arguments: ["node", "/opt/homebrew/bin/happy"]
          )
        }
        return ForegroundProcess(
          pid: pid, name: "node", argv0: "node", cmdline: "node /tmp/shim.js",
          arguments: ["node", "/tmp/shim.js"]
        )
      }
    )
  }

  /// A job whose single member is a Happy launcher at pid 1.
  private var launcherJob: [ForegroundProcess] {
    [
      ForegroundProcess(
        pid: 1, name: "node", argv0: "node", cmdline: "node /opt/homebrew/bin/happy",
        arguments: ["node", "/opt/homebrew/bin/happy"]
      )
    ]
  }

  @Test func walksNothingWhenNoJobMemberIsALauncher() {
    let plain = [
      ForegroundProcess(pid: 1, name: "zsh", argv0: "zsh", cmdline: "-zsh", arguments: ["-zsh"])
    ]
    let hosted = ProcessDetection.hostedProcesses(
      of: plain, source: walkSource(tree: [1: [2, 3]]))
    #expect(hosted.isEmpty)
  }

  @Test func walkKeepsDescendingPastAnAgentItFinds() {
    // 1 -> 2 -> 3(agent) -> 4. The walk cannot stop at an agent: a wrapped runtime's
    // real engine is the *child* of the script that names it (`codex` is a node script
    // that spawns a native binary), and that child holds the session file. Breadth
    // order is what identification relies on, so assert it.
    let hosted = ProcessDetection.hostedProcesses(
      of: launcherJob,
      source: walkSource(tree: [1: [2], 2: [3], 3: [4]], agents: [3])
    )
    #expect(hosted.map(\.ref) == [.local(2), .local(3), .local(4)])
  }

  @Test func walkExcludesProcessesAlreadyInTheJob() {
    var job = launcherJob
    job.append(
      ForegroundProcess(pid: 2, name: "node", argv0: "node", cmdline: "node", arguments: ["node"]))
    let hosted = ProcessDetection.hostedProcesses(
      of: job, source: walkSource(tree: [1: [2, 3]]))
    #expect(hosted.map(\.ref) == [.local(3)])
  }

  @Test func walkHonorsItsDepthLimit() {
    // A chain that never reaches an agent is cut at the depth limit instead of being
    // walked to its leaves.
    var chain: [pid_t: [pid_t]] = [:]
    for pid in pid_t(1)...pid_t(20) { chain[pid] = [pid + 1] }
    let hosted = ProcessDetection.hostedProcesses(of: launcherJob, source: walkSource(tree: chain))
    #expect(hosted.count == ProcessDetection.hostedWalkDepthLimit)
  }

  @Test func walkHonorsItsCountLimit() {
    let wide = Array(pid_t(2)...pid_t(400))
    let hosted = ProcessDetection.hostedProcesses(
      of: launcherJob, source: walkSource(tree: [1: wide]))
    #expect(hosted.count == ProcessDetection.hostedWalkCountLimit)
  }

  @Test func walkSkipsAChildThatExitedBeforeItCouldBeDescribed() {
    // A pid that is gone by the time the walk reaches it yields no process, and its
    // own subtree is not pursued — but its siblings still are.
    let source = ProcessDetection.HostedWalkSource(
      children: { [1: [2, 3], 2: [4]][$0] ?? [] },
      describe: { pid in
        pid == 2
          ? nil
          : ForegroundProcess(
            pid: pid, name: "node", argv0: "node", cmdline: "node", arguments: ["node"])
      }
    )
    #expect(ProcessDetection.hostedProcesses(of: launcherJob, source: source).map(\.ref) == [.local(3)])
  }

  @Test func walkDoesNotRevisitAPidOnACorruptCycle() {
    let hosted = ProcessDetection.hostedProcesses(
      of: launcherJob, source: walkSource(tree: [1: [2], 2: [1, 2, 3]]))
    #expect(hosted.map(\.ref) == [.local(2), .local(3)])
  }

  /// `PROC_PPID_ONLY` is what lets detection reach an engine a launcher runs outside
  /// the pane's job, so prove against the live kernel that it really lists a
  /// process's children.
  @Test func listsTheChildrenOfARunningProcess() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sh")
    child.arguments = ["-c", "sleep 30"]
    try child.run()
    defer {
      child.terminate()
      child.waitUntilExit()
    }

    let children = ProcessDetection.childPIDs(getpid())
    #expect(children.contains(child.processIdentifier))
    #expect(!children.contains(getpid()))
    // A leaf has none, and an impossible pid is not an error.
    #expect(ProcessDetection.childPIDs(-1).isEmpty)
  }
}
