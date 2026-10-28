import Foundation
import Testing

@testable import Prowl

/// The test host is the app, so `Bundle.main` is the built bundle with its `ghostty` entry.
struct GhosttyCLIEntryTests {
  @Test func programNameSelectsTheCLI() {
    #expect(GhosttyCLIEntry.isGhosttyInvocation(argv0: "/Applications/Prowl.app/Contents/MacOS/ghostty"))
    #expect(GhosttyCLIEntry.isGhosttyInvocation(argv0: "ghostty"))
    #expect(GhosttyCLIEntry.isGhosttyInvocation(argv0: "./ghostty"))
  }

  @Test func otherProgramNamesStartTheApp() {
    #expect(!GhosttyCLIEntry.isGhosttyInvocation(argv0: nil))
    #expect(!GhosttyCLIEntry.isGhosttyInvocation(argv0: ""))
    #expect(!GhosttyCLIEntry.isGhosttyInvocation(argv0: "/Applications/Prowl.app/Contents/MacOS/ProwlApp"))
    #expect(!GhosttyCLIEntry.isGhosttyInvocation(argv0: "/Applications/ghostty/ProwlApp"))
    #expect(!GhosttyCLIEntry.isGhosttyInvocation(argv0: "ghostty-bench"))
    #expect(!GhosttyCLIEntry.isGhosttyInvocation(argv0: "Ghostty"))
  }

  @Test func bundleHasRelativeSymlinkToAppExecutable() throws {
    let executable = try #require(Bundle.main.executableURL)
    let entry = executable.deletingLastPathComponent().appending(path: GhosttyCLIEntry.programName)
    let destination = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
    #expect(destination == executable.lastPathComponent)
  }

  @Test func entryRunsGhosttyAction() async throws {
    let result = try await Self.runEntry(arguments: ["+version"])
    #expect(result.exitCode == 0)
    #expect(result.stdout.hasPrefix("Ghostty "))
  }

  @Test func entryWithoutActionExitsWithoutStartingTheApp() async throws {
    let result = try await Self.runEntry(arguments: [])
    #expect(result.exitCode == 1)
    #expect(result.stderr.contains("runs only Ghostty CLI actions"))
  }

  @Test func entryRejectsUnknownAction() async throws {
    let result = try await Self.runEntry(arguments: ["+no-such-action"])
    #expect(result.exitCode == 1)
    #expect(result.stderr.contains("ghostty +help"))
  }

  private struct RunResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
  }

  /// Runs `Contents/MacOS/ghostty` of the test host. The child gets only `PATH` and `HOME`:
  /// the test runner's `DYLD_*` and `XCTest*` variables would inject the test bundle into it.
  private static func runEntry(arguments: [String]) async throws -> RunResult {
    let executable = try #require(Bundle.main.executableURL)
    let entry = executable.deletingLastPathComponent().appending(path: GhosttyCLIEntry.programName)
    let environment = ProcessInfo.processInfo.environment
    return try await withCheckedThrowingContinuation { continuation in
      let process = Process()
      process.executableURL = entry
      process.arguments = arguments
      process.environment = [
        "PATH": environment["PATH"] ?? "/usr/bin:/bin",
        "HOME": environment["HOME"] ?? NSHomeDirectory(),
      ]
      let out = Pipe()
      let err = Pipe()
      process.standardOutput = out
      process.standardError = err
      process.standardInput = FileHandle.nullDevice
      process.terminationHandler = { proc in
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        continuation.resume(
          returning: RunResult(
            stdout: String(bytes: stdout, encoding: .utf8) ?? "",
            stderr: String(bytes: stderr, encoding: .utf8) ?? "",
            exitCode: proc.terminationStatus
          ))
      }
      do { try process.run() } catch { continuation.resume(throwing: error) }
      // A broken entry starts the full app, which never exits: end it so the test fails
      // instead of hanging.
      DispatchQueue.global().asyncAfter(deadline: .now() + 60) { [process] in
        if process.isRunning { process.terminate() }
      }
    }
  }
}
