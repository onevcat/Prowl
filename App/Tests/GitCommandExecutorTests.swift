import ConcurrencyExtras
import Foundation
import Testing

@testable import Prowl

struct GitCommandExecutorTests {
  @Test func gitClientRunsThroughItsExecutor() async throws {
    let invocations = LockIsolated<[[String]]>([])
    let shell = ShellClient(
      run: { executableURL, arguments, _ in
        invocations.withValue { $0.append([executableURL.path(percentEncoded: false)] + arguments) }
        return ShellOutput(stdout: "/tmp/repo\n", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in
        Issue.record("repoRoot does not use a login shell")
        return ShellOutput(stdout: "", stderr: "", exitCode: 0)
      }
    )
    let revalidations = LockIsolated<[Bool]>([])
    let executor = GitCommandExecutor(
      shell: shell,
      resolveGit: { revalidate in
        revalidations.withValue { $0.append(revalidate) }
        return GitExecutable(url: URL(fileURLWithPath: "/custom/git"), searchPath: "/custom/bin")
      },
      wtScriptURL: { URL(fileURLWithPath: "/custom/wt") }
    )

    _ = try await GitClient(executor: executor).repoRoot(for: URL(fileURLWithPath: "/tmp/repo/worktree"))

    #expect(invocations.value.count == 2)
    #expect(invocations.value[0].contains("/custom/git"))
    #expect(invocations.value[0].suffix(2) == ["rev-parse", "--git-dir"])
    #expect(invocations.value[1].contains("/custom/wt"))
    #expect(invocations.value[1].contains("PATH=/custom/bin"))
    #expect(revalidations.value == [true, false])
  }

  @Test func localClientUsesTheBundledScript() throws {
    #expect(try GitCommandExecutor.local.wtScriptURL().lastPathComponent == "wt")
  }
}
