import Foundation
import Testing

@testable import supacode

@MainActor
struct WorktreeEnvironmentTests {
  @Test func scriptEnvironmentContainsExpectedKeys() {
    let worktree = Worktree(
      id: "/tmp/repo/wt-1",
      name: "feature-branch",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo"),
    )
    let env = worktree.scriptEnvironment
    #expect(env["PROWL_WORKTREE_PATH"] == "/tmp/repo/wt-1")
    #expect(env["PROWL_ROOT_PATH"] == "/tmp/repo")
    #expect(env.count == 2)
  }

  @Test func exportPrefixFormatsCorrectly() {
    let worktree = Worktree(
      id: "/tmp/repo/wt-1",
      name: "feature-branch",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo/.bare"),
    )
    let exports = worktree.scriptEnvironmentExportPrefix
    #expect(exports.contains("export PROWL_WORKTREE_PATH='/tmp/repo/wt-1'"))
    #expect(exports.contains("export PROWL_ROOT_PATH='/tmp/repo/.bare'"))
    #expect(exports.hasSuffix("\n"))
  }

  @Test func exportPrefixIsSortedByKey() {
    let worktree = Worktree(
      id: "/tmp/repo/wt-1",
      name: "feature-branch",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/repo/wt-1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/repo/.bare"),
    )
    let lines = worktree.scriptEnvironmentExportPrefix
      .trimmingCharacters(in: .newlines)
      .components(separatedBy: "\n")
    #expect(lines.count == 2)
    #expect(lines[0].contains("PROWL_ROOT_PATH"))
    #expect(lines[1].contains("PROWL_WORKTREE_PATH"))
  }

  @Test func exportPrefixQuotesPathsWithSpaces() {
    let worktree = Worktree(
      id: "/tmp/my repo/wt 1",
      name: "feature-branch",
      detail: "detail",
      workingDirectory: URL(fileURLWithPath: "/tmp/my repo/wt 1"),
      repositoryRootURL: URL(fileURLWithPath: "/tmp/my repo/.bare"),
    )
    let exports = worktree.scriptEnvironmentExportPrefix
    #expect(exports.contains("export PROWL_WORKTREE_PATH='/tmp/my repo/wt 1'"))
    #expect(exports.contains("export PROWL_ROOT_PATH='/tmp/my repo/.bare'"))
  }

  @Test func blockingScriptInputUsesPortableBareExit() {
    let input = makeBlockingScriptInput(
      script: """
        docker compose down
        codex exec "test"
        """
    )

    #expect(input?.contains("docker compose down\ncodex exec \"test\"\nexit\n") == true)
    #expect(input?.contains("(\n") == false)
    #expect(input?.contains("exit $?") == false)
  }

  @Test func commandInputDoesNotPrependEnvExports() {
    // Environment variables are injected via ghostty_surface_config.env_vars
    // now, so the shell input itself must stay free of `export` prefixes.
    let input = makeCommandInput(script: "make build")
    #expect(input == "make build\n")
  }

  @Test func blockingScriptInputReturnsNilForWhitespaceOnlyScripts() {
    #expect(makeBlockingScriptInput(script: "   \n  ") == nil)
  }
}
