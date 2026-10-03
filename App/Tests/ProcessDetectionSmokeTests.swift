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

  @Test func missingProcessDoesNotReturnACompleteInventory() {
    var complete = true
    #expect(ProcessDetection.openFilePaths(pid: -1, complete: &complete).isEmpty)
    #expect(!complete)
  }
}
