import Foundation
import Testing

@testable import supacode

nonisolated final class BootstrapShellRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var environmentValue: [String: String] = [:]
  private var currentDirectoryURLValue: URL?
  private var scriptsValue: [String] = []

  func record(script: String? = nil, environment: [String: String], currentDirectoryURL: URL?) {
    lock.lock()
    environmentValue = environment
    currentDirectoryURLValue = currentDirectoryURL
    if let script {
      scriptsValue.append(script)
    }
    lock.unlock()
  }

  var environment: [String: String] {
    lock.lock()
    defer { lock.unlock() }
    return environmentValue
  }

  var currentDirectoryURL: URL? {
    lock.lock()
    defer { lock.unlock() }
    return currentDirectoryURLValue
  }

  var scripts: [String] {
    lock.lock()
    defer { lock.unlock() }
    return scriptsValue
  }
}

struct ProjectWorkspaceBootstrapExecutorTests {
  @Test func runsProfileWithWorkspaceEnvironmentAndWritesState() async throws {
    let rootURL = try makeTemporaryRoot()
    let repoURL = rootURL.appending(path: "app", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let recorder = BootstrapShellRecorder()
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginStreamWithEnvironmentImpl: { _, arguments, currentDirectoryURL, environment, _ in
        recorder.record(script: arguments.last, environment: environment, currentDirectoryURL: currentDirectoryURL)
        return AsyncThrowingStream { continuation in
          continuation.yield(.line(ShellStreamLine(source: .stdout, text: "hello")))
          continuation.yield(.finished(ShellOutput(stdout: "hello", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      }
    )
    let executor = ProjectWorkspaceBootstrapExecutor(
      profiles: [
        ProjectWorkspaceBootstrapProfile(
          id: "sync-app",
          name: "Sync App",
          command: "bash $script",
          environment: ["CUSTOM_BOOTSTRAP": "yes"],
          script: "echo hello",
          timeoutSeconds: 300
        )
      ],
      shellClient: shell,
      now: { Date(timeIntervalSince1970: 1_234) }
    )
    let entry = ProjectWorkspace.RepositoryEntry(
      id: "app",
      name: "App",
      path: "app",
      sourceKind: .remote,
      sourceLocation: "git@github.com:onevcat/app.git",
      branchName: "codex/app",
      baseRef: "origin/main",
      bootstrap: ProjectWorkspaceRepositoryBootstrap(
        scriptKind: .userProfile,
        scriptID: "sync-app",
        runOn: [.create],
        required: true
      )
    )

    try await executor.runner.run(
      try #require(entry.bootstrap),
      ProjectWorkspaceBootstrapContext(
        workspaceRootURL: rootURL,
        repositoryRootURL: repoURL,
        repository: entry,
        timing: .create
      )
    )

    #expect(recorder.currentDirectoryURL == repoURL)
    #expect(recorder.environment["PROWL_WORKSPACE_ROOT"] == rootURL.path(percentEncoded: false))
    #expect(recorder.environment["PROWL_REPOSITORY_ROOT"] == repoURL.path(percentEncoded: false))
    #expect(recorder.environment["PROWL_REPOSITORY_ID"] == "app")
    #expect(recorder.environment["PROWL_REPOSITORY_NAME"] == "App")
    #expect(recorder.environment["PROWL_SOURCE_KIND"] == "remote")
    #expect(recorder.environment["CUSTOM_BOOTSTRAP"] == "yes")
    let scriptPath = try #require(recorder.environment["script"])
    #expect(scriptPath.hasSuffix(".sh"))
    #expect(recorder.scripts.first == "bash $script")

    let stateURL =
      rootURL
      .appending(path: ProjectWorkspace.metadataDirectoryName)
      .appending(path: "bootstrap-state.json")
    let stateData = try Data(contentsOf: stateURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let state = try decoder.decode(ProjectWorkspaceBootstrapState.self, from: stateData)
    #expect(state.repositories["app"]?.lastStatus == .succeeded)
    #expect(state.repositories["app"]?.lastScriptID == "sync-app")
    #expect(state.repositories["app"]?.lastScriptIDs == ["sync-app"])
    let logPath = try #require(state.repositories["app"]?.lastLogPath)
    let log = try String(contentsOf: rootURL.appending(path: logPath), encoding: .utf8)
    #expect(log.contains("[stdout] hello"))
    #expect(log.contains("[exit] 0"))
  }

  @Test func runsMultipleProfilesInOrderAndContinuesOptionalFailures() async throws {
    let rootURL = try makeTemporaryRoot()
    let repoURL = rootURL.appending(path: "app", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let recorder = BootstrapShellRecorder()
    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginStreamWithEnvironmentImpl: { _, arguments, currentDirectoryURL, environment, _ in
        recorder.record(
          script: arguments.last,
          environment: environment,
          currentDirectoryURL: currentDirectoryURL
        )
        return AsyncThrowingStream { continuation in
          let scriptPath = environment["script"] ?? ""
          if scriptPath.contains("failing") {
            continuation.finish(
              throwing: ProjectWorkspaceCreationError.bootstrapFailed(
                repository: "App",
                message: "failed"
              )
            )
          } else {
            continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
            continuation.finish()
          }
        }
      }
    )
    let executor = ProjectWorkspaceBootstrapExecutor(
      profiles: [
        ProjectWorkspaceBootstrapProfile(id: "first", name: "First", script: "echo first"),
        ProjectWorkspaceBootstrapProfile(id: "failing", name: "Failing", script: "exit 1"),
        ProjectWorkspaceBootstrapProfile(id: "last", name: "Last", script: "echo last"),
      ],
      shellClient: shell,
      now: { Date(timeIntervalSince1970: 1_234) }
    )
    let entry = ProjectWorkspace.RepositoryEntry(
      id: "app",
      name: "App",
      path: "app",
      bootstrap: ProjectWorkspaceRepositoryBootstrap(
        scriptKind: .userProfile,
        scriptIDs: ["first", "failing", "last"],
        runOn: [.create],
        required: false
      )
    )

    try await executor.runner.run(
      try #require(entry.bootstrap),
      ProjectWorkspaceBootstrapContext(
        workspaceRootURL: rootURL,
        repositoryRootURL: repoURL,
        repository: entry,
        timing: .create
      )
    )

    #expect(
      recorder.scripts == [
        ProjectWorkspaceBootstrapProfile.defaultCommand,
        ProjectWorkspaceBootstrapProfile.defaultCommand,
        ProjectWorkspaceBootstrapProfile.defaultCommand,
      ])
    let stateURL =
      rootURL
      .appending(path: ProjectWorkspace.metadataDirectoryName)
      .appending(path: "bootstrap-state.json")
    let stateData = try Data(contentsOf: stateURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let state = try decoder.decode(ProjectWorkspaceBootstrapState.self, from: stateData)
    #expect(state.repositories["app"]?.lastStatus == .failed)
    #expect(state.repositories["app"]?.lastScriptIDs == ["first", "failing", "last"])
  }

  private func makeTemporaryRoot() throws -> URL {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "prowl-bootstrap-executor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: rootURL.appending(path: ProjectWorkspace.metadataDirectoryName),
      withIntermediateDirectories: true
    )
    return rootURL
  }
}
