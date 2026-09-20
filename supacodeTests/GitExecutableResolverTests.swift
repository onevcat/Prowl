import ConcurrencyExtras
import Foundation
import Testing

@testable import supacode

struct GitExecutableResolverTests {
  @Test func brokenAppleGitFallsBackAndResolutionDoesNotChangeDeveloperDirectory() async throws {
    let broken = LockIsolated(true)
    let calls = LockIsolated<[[String]]>([])
    let shell = ShellClient(
      run: { _, arguments, _ in
        calls.withValue { $0.append(arguments) }
        if broken.value {
          throw ShellClientError(
            command: "git --version", stdout: "", stderr: "xcrun: invalid developer path", exitCode: 1)
        }
        return ShellOutput(stdout: "git version 2.50\n", stderr: "", exitCode: 0)
      },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) }
    )
    let resolver = GitExecutableResolver(processPath: "/usr/bin", fallbackPaths: [])
    await #expect(throws: GitClientError.self) { try await resolver.resolve(shell: shell) }
    #expect(resolver.cachedExecutable == nil)
    broken.setValue(false)
    let result = try await resolver.resolve(shell: shell)
    #expect(result.url.path == "/usr/bin/git")
    let developerArguments = calls.value.joined().filter { $0.hasPrefix("DEVELOPER_DIR=") }
    if let original = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
      #expect(developerArguments.allSatisfy { $0 == "DEVELOPER_DIR=\(original)" })
    } else {
      #expect(developerArguments.isEmpty)
    }
    broken.setValue(true)
    await #expect(throws: GitClientError.self) { try await resolver.resolve(revalidate: true, shell: shell) }
    #expect(resolver.cachedExecutable == nil)
  }

  @Test func loginPathCanSupplyIndependentGit() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appending(path: "git")
    try Data().write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    let shell = ShellClient(
      run: { _, arguments, _ in
        if arguments.contains(executable.path(percentEncoded: false)) {
          #expect(arguments.contains(where: { $0.hasPrefix("PATH=\(directory.path)") }))
          return ShellOutput(stdout: "git version 2.50\n", stderr: "", exitCode: 0)
        }
        throw ShellClientError(command: "git --version", stdout: "", stderr: "xcrun failed", exitCode: 1)
      },
      runLoginImpl: { _, _, _, _ in
        ShellOutput(stdout: "\(directory.path):/usr/bin:/bin\n", stderr: "", exitCode: 0)
      }
    )
    let resolver = GitExecutableResolver(processPath: "/usr/bin", fallbackPaths: [])
    #expect(try await resolver.resolve(shell: shell).url == executable)
  }
}
