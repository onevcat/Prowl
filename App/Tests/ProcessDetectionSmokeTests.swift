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
}
