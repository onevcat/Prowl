import Foundation
import Testing

@testable import supacode

struct GitClientShellFallbackTests {
  private func shellError(
    stderr: String = "",
    stdout: String = "",
    exitCode: Int32 = 1
  ) -> ShellClientError {
    ShellClientError(command: "wt root", stdout: stdout, stderr: stderr, exitCode: exitCode)
  }

  @Test func fallsBackWhenExecutableNotFound() {
    #expect(shouldFallbackToLoginShell(shellError(exitCode: 127)))
  }

  @Test func fallsBackOnCommandNotFoundMessage() {
    #expect(shouldFallbackToLoginShell(shellError(stderr: "env: git: command not found")))
  }

  @Test func fallsBackWhenXcodeLicenseUnaccepted() {
    let stderr = """
      You have not agreed to the Xcode license agreements. Please run 'sudo xcodebuild -license' \
      from within a Terminal window to review and agree to the Xcode and Apple SDKs license.
      error: not a git repository
      """
    #expect(shouldFallbackToLoginShell(shellError(stderr: stderr, exitCode: 1)))
  }

  @Test func fallsBackOnInvalidActiveDeveloperPath() {
    let stderr = "xcode-select: error: invalid active developer path (/Library/Developer/CommandLineTools)"
    #expect(shouldFallbackToLoginShell(shellError(stderr: stderr, exitCode: 1)))
  }

  @Test func doesNotFallBackForGenuineNonGitDirectory() {
    #expect(shouldFallbackToLoginShell(shellError(stderr: "fatal: not a git repository", exitCode: 128)) == false)
  }

  @Test func doesNotFallBackForNonShellError() {
    struct OtherError: Error {}
    #expect(shouldFallbackToLoginShell(OtherError()) == false)
  }
}
