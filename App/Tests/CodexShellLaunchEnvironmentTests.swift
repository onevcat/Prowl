import Foundation
import Testing

@testable import supacode

struct CodexShellLaunchEnvironmentTests {
  @Test func probeUsesLoginShellAndReturnsOnlyValidatedLaunchFacts() async throws {
    let cwd = URL(filePath: "/tmp/Project Space/界", directoryHint: .isDirectory)
    let run: @Sendable (URL, String) async throws -> ShellOutput = { currentDirectory, script in
      #expect(currentDirectory == cwd)
      #expect(script.contains("command -v -- codex"))
      return ShellOutput(
        stdout: """
          __PROWL_CODEX_EXECUTABLE__/opt/custom/bin/codex
          __PROWL_CODEX_HOME_BASE__/Users/tester
          __PROWL_CODEX_HOME__/tmp/codex-home
          __PROWL_CODEX_END__

          """,
        stderr: "ignored",
        exitCode: 0
      )
    }

    let environment = try #require(
      await CodexShellLaunchEnvironmentProbe.resolve(
        cwd: cwd,
        run: run,
        isExecutable: { $0 == "/opt/custom/bin/codex" }
      )
    )

    #expect(environment.executableURL.path(percentEncoded: false) == "/opt/custom/bin/codex")
    #expect(
      environment.processEnvironment == [
        "HOME": "/Users/tester",
        "CODEX_HOME": "/tmp/codex-home",
      ])
  }

  @Test func loginShellBannerDoesNotHideTheFramedLaunchFacts() async throws {
    let output = ShellOutput(
      stdout: """
        Welcome from zprofile
        __PROWL_CODEX_EXECUTABLE__/opt/codex
        __PROWL_CODEX_HOME_BASE__/Users/tester
        __PROWL_CODEX_HOME__
        __PROWL_CODEX_END__
        Login complete
        """,
      stderr: "",
      exitCode: 0
    )

    let environment = try #require(
      await CodexShellLaunchEnvironmentProbe.resolve(
        cwd: URL(filePath: "/tmp", directoryHint: .isDirectory),
        run: { _, _ in output },
        isExecutable: { $0 == "/opt/codex" }
      )
    )

    #expect(environment.executableURL.path(percentEncoded: false) == "/opt/codex")
    #expect(environment.processEnvironment == ["HOME": "/Users/tester"])
  }

  @Test func multilineMarkerValueDegradesInsteadOfUsingItsFirstLine() async {
    let output = ShellOutput(
      stdout: """
        Login banner
        __PROWL_CODEX_EXECUTABLE__/opt/codex
        __PROWL_CODEX_HOME_BASE__/Users/tester
        __PROWL_CODEX_HOME__/tmp/first
        second
        __PROWL_CODEX_END__
        Login complete
        """,
      stderr: "",
      exitCode: 0
    )

    #expect(
      await CodexShellLaunchEnvironmentProbe.resolve(
        cwd: URL(filePath: "/tmp", directoryHint: .isDirectory),
        run: { _, _ in output },
        isExecutable: { $0 == "/opt/codex" }
      ) == nil
    )
  }

  @Test func malformedNonAbsoluteAndFailedProbeDegrade() async {
    for output in [
      ShellOutput(stdout: "not-json", stderr: "", exitCode: 0),
      ShellOutput(
        stdout: """
          __PROWL_CODEX_EXECUTABLE__codex
          __PROWL_CODEX_HOME_BASE__/Users/tester
          __PROWL_CODEX_HOME__

          """,
        stderr: "",
        exitCode: 0
      ),
      ShellOutput(
        stdout: """
          __PROWL_CODEX_EXECUTABLE__/opt/codex
          __PROWL_CODEX_HOME_BASE__/Users/tester
          __PROWL_CODEX_HOME__

          """,
        stderr: "",
        exitCode: 1
      ),
    ] {
      #expect(
        await CodexShellLaunchEnvironmentProbe.resolve(
          cwd: URL(filePath: "/tmp", directoryHint: .isDirectory),
          run: { _, _ in output },
          isExecutable: { $0 == "/opt/codex" }
        ) == nil
      )
    }
  }

  @Test func profilePATHOverrideParticipatesInExecutableResolution() async throws {
    let output = """
      __PROWL_CODEX_EXECUTABLE__/custom/bin/codex
      __PROWL_CODEX_HOME_BASE__/Users/tester
      __PROWL_CODEX_HOME__
      __PROWL_CODEX_END__

      """
    let result = await CodexShellLaunchEnvironmentProbe.resolve(
      cwd: URL(filePath: "/tmp", directoryHint: .isDirectory),
      pathOverride: "/custom/bin:/usr/bin",
      run: { _, script in
        #expect(script.contains("PATH='/custom/bin:/usr/bin'; export PATH"))
        return ShellOutput(stdout: output, stderr: "", exitCode: 0)
      },
      isExecutable: { $0 == "/custom/bin/codex" }
    )

    #expect(result?.executableURL.path(percentEncoded: false) == "/custom/bin/codex")
  }

  @Test func capturedShellHomeDefinesDefaultCodexHome() throws {
    let shell = CodexShellLaunchEnvironment(
      executableURL: URL(filePath: "/opt/codex"),
      processEnvironment: ["HOME": "/Users/shell-home"]
    )
    let context = try CodexLaunchContext.capture(
      invocation: AgentInvocation(executable: "/opt/codex", arguments: []),
      inheritedCWD: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
      environment: shell.processEnvironment
    )

    #expect(context.codexHome.path(percentEncoded: false) == "/Users/shell-home/.codex/")
  }
}
