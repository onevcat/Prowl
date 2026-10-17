import Foundation
import Testing

@testable import Prowl

/// The single quoting boundary for remote work (docs-ai 082, C5). The script runs in a
/// local `/bin/sh -s`, which is what the host's `sh -s` receives.
struct RemoteShellCommandTests {
  private func run(_ script: String) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = ["-s"]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(bytes: data, encoding: .utf8) ?? "")
  }

  @Test func argumentsArriveByteForByte() throws {
    let hostile = [
      "", "two words", "it's", #"back\slash"#, "$HOME", "$(echo nope)", "`echo nope`", "*", "line\nbreak",
      "tab\there", "ünïcødé", "--", "-n",
    ]
    let command = RemoteShellCommand(executable: "/usr/bin/printf", arguments: ["[%s]\n"] + hostile)
    let result = try run(try command.script())
    #expect(result.status == 0)
    #expect(result.output == hostile.map { "[\($0)]\n" }.joined())
  }

  @Test func workingDirectoryAndEnvironmentApplyBeforeExec() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "prowl remote 'cmd' %x", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let command = RemoteShellCommand(
      executable: "/bin/sh", arguments: ["-c", #"printf '%s|%s' "$(pwd -P)" "$PROWL_TEST_VALUE""#],
      workingDirectory: directory.path(percentEncoded: false), environment: [("PROWL_TEST_VALUE", "a 'b' $c")])
    let result = try run(try command.script())
    #expect(result.status == 0)
    #expect(result.output.hasSuffix("/prowl remote 'cmd' %x|a 'b' $c"))
  }

  @Test func missingWorkingDirectoryFailsWithItsOwnStatus() throws {
    let command = RemoteShellCommand(executable: "/usr/bin/true", workingDirectory: "/nonexistent/prowl/path")
    #expect(try run(try command.script()).status == RemoteShellCommand.workingDirectoryFailureStatus)
  }

  @Test func invalidInputIsRejectedInsteadOfQuoted() {
    #expect(throws: RemoteShellCommand.ValidationError.emptyExecutable) {
      try RemoteShellCommand(executable: "").script()
    }
    #expect(throws: RemoteShellCommand.ValidationError.invalidEnvironmentName("A-B")) {
      try RemoteShellCommand(executable: "env", environment: [("A-B", "x")]).script()
    }
    #expect(throws: RemoteShellCommand.ValidationError.invalidEnvironmentName("1A")) {
      try RemoteShellCommand(executable: "env", environment: [("1A", "x")]).script()
    }
    #expect(throws: RemoteShellCommand.ValidationError.nulByte) {
      try RemoteShellCommand(executable: "echo", arguments: ["a\u{0}b"]).script()
    }
  }
}
