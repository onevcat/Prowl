import Foundation
import Testing

@testable import supacode

actor DiffPathShellCallStore {
  private(set) var calls: [[String]] = []

  func record(_ arguments: [String]) {
    calls.append(arguments)
  }
}

struct GitClientDiffPathEncodingTests {
  @Test func diffNameStatusDisablesQuotePath() async {
    let store = DiffPathShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        return ShellOutput(stdout: "M\t中文文件.md\n", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell, resolveGit: { _ in .testExecutable })

    let output = await client.diffNameStatus(at: URL(fileURLWithPath: "/tmp/repo"))

    #expect(output.contains("中文文件.md"))
    let calls = await store.calls
    #expect(calls.count == 1)
    let args = calls[0]
    #expect(args.contains("/usr/bin/git"))
    #expect(args.contains("-c"))
    #expect(args.contains("core.quotePath=false"))
    #expect(args.contains("diff"))
    #expect(args.contains("--name-status"))
  }

  @Test func untrackedFilePathsDisablesQuotePath() async {
    let store = DiffPathShellCallStore()
    let shell = ShellClient(
      run: { _, arguments, _ in
        await store.record(arguments)
        return ShellOutput(stdout: "中文文件.md\n", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let client = GitClient(shell: shell, resolveGit: { _ in .testExecutable })

    let paths = await client.untrackedFilePaths(at: URL(fileURLWithPath: "/tmp/repo"))

    #expect(paths == ["中文文件.md"])
    let calls = await store.calls
    #expect(calls.count == 1)
    let args = calls[0]
    #expect(args.contains("/usr/bin/git"))
    #expect(args.contains("-c"))
    #expect(args.contains("core.quotePath=false"))
    #expect(args.contains("ls-files"))
    #expect(args.contains("--others"))
    #expect(args.contains("--exclude-standard"))
  }
}
