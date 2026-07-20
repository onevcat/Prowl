import Foundation
import Testing

@testable import supacode

nonisolated final class BootstrapShellRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var environmentValue: [String: String] = [:]
  private var currentDirectoryURLValue: URL?
  private var scriptsValue: [String] = []
  private var scriptPathsValue: [String] = []

  func record(script: String? = nil, environment: [String: String], currentDirectoryURL: URL?) {
    lock.lock()
    environmentValue = environment
    currentDirectoryURLValue = currentDirectoryURL
    if let script {
      scriptsValue.append(script)
    }
    if let scriptPath = environment[ScriptProfile.scriptEnvironmentKey] {
      scriptPathsValue.append(scriptPath)
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

  var scriptPaths: [String] {
    lock.lock()
    defer { lock.unlock() }
    return scriptPathsValue
  }
}

nonisolated final class BootstrapStateReadBarrier: @unchecked Sendable {
  private let lock = NSLock()
  private let secondReadReached = DispatchSemaphore(value: 0)
  private var readCount = 0

  func read(_ operation: () throws -> Data) throws -> Data {
    let result = Result { try operation() }
    lock.lock()
    readCount += 1
    let currentReadCount = readCount
    lock.unlock()

    if currentReadCount == 1 {
      _ = secondReadReached.wait(timeout: .now() + .milliseconds(200))
    } else if currentReadCount == 2 {
      secondReadReached.signal()
    }
    return try result.get()
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
        recorder.record(
          script: arguments.last, environment: environment, currentDirectoryURL: currentDirectoryURL
        )
        return AsyncThrowingStream { continuation in
          continuation.yield(.line(ShellStreamLine(source: .stdout, text: "hello")))
          continuation.yield(.finished(ShellOutput(stdout: "hello", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      }
    )
    let executor = ProjectWorkspaceBootstrapExecutor(
      profiles: [
        ScriptProfile(
          id: "sync-app",
          name: "Sync App",
          command: "bash $PROWL_SCRIPT",
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
    let scriptPath = try #require(
      recorder.environment[ScriptProfile.scriptEnvironmentKey])
    #expect(scriptPath.hasSuffix(".sh"))
    #expect(recorder.scripts.first == "bash $PROWL_SCRIPT")

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

  @Test func runsMultipleProfilesInOrderAndReportsOptionalFailures() async throws {
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
          let scriptPath = environment[ScriptProfile.scriptEnvironmentKey] ?? ""
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
        ScriptProfile(id: "first", name: "First", script: "echo first"),
        ScriptProfile(id: "failing", name: "Failing", script: "exit 1"),
        ScriptProfile(id: "last", name: "Last", script: "echo last"),
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

    await #expect(
      throws: ProjectWorkspaceCreationError.bootstrapFailed(repository: "App", message: "failed")
    ) {
      try await executor.runner.run(
        try #require(entry.bootstrap),
        ProjectWorkspaceBootstrapContext(
          workspaceRootURL: rootURL,
          repositoryRootURL: repoURL,
          repository: entry,
          timing: .create
        )
      )
    }

    #expect(
      recorder.scripts == [
        ScriptProfile.defaultCommand,
        ScriptProfile.defaultCommand,
        ScriptProfile.defaultCommand,
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

  @Test func usesUniqueArtifactsForRunsWithSameTimestamp() async throws {
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
          continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      }
    )
    let executor = ProjectWorkspaceBootstrapExecutor(
      profiles: [ScriptProfile(id: "sync-app", name: "Sync App", script: "echo hello")],
      shellClient: shell,
      now: { Date(timeIntervalSince1970: 1_234) }
    )
    let entry = ProjectWorkspace.RepositoryEntry(
      id: "app",
      name: "App",
      path: "app",
      bootstrap: ProjectWorkspaceRepositoryBootstrap(
        scriptKind: .userProfile,
        scriptID: "sync-app",
        runOn: [.manual],
        required: true
      )
    )
    let context = ProjectWorkspaceBootstrapContext(
      workspaceRootURL: rootURL,
      repositoryRootURL: repoURL,
      repository: entry,
      timing: .manual
    )

    try await executor.runner.run(try #require(entry.bootstrap), context)
    let firstState = try loadState(from: rootURL)
    let firstLogPath = try #require(firstState.repositories["app"]?.lastLogPath)

    try await executor.runner.run(try #require(entry.bootstrap), context)
    let secondState = try loadState(from: rootURL)
    let secondLogPath = try #require(secondState.repositories["app"]?.lastLogPath)

    #expect(Set(recorder.scriptPaths).count == 2)
    #expect(firstLogPath != secondLogPath)
  }

  @Test func concurrentRunsPreserveRuntimeStateForEachRepository() async throws {
    let rootURL = try makeTemporaryRoot()
    let appURL = rootURL.appending(path: "app", directoryHint: .isDirectory)
    let apiURL = rootURL.appending(path: "api", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: apiURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let shell = ShellClient(
      run: { _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginImpl: { _, _, _, _ in ShellOutput(stdout: "", stderr: "", exitCode: 0) },
      runLoginStreamWithEnvironmentImpl: { _, _, _, _, _ in
        AsyncThrowingStream { continuation in
          continuation.yield(.finished(ShellOutput(stdout: "", stderr: "", exitCode: 0)))
          continuation.finish()
        }
      }
    )
    let readBarrier = BootstrapStateReadBarrier()
    var fileClient = ProjectWorkspaceBootstrapFileClient.live
    let liveReadData = fileClient.readData
    fileClient.readData = { url in
      try readBarrier.read { try liveReadData(url) }
    }
    let executor = ProjectWorkspaceBootstrapExecutor(
      profiles: [ScriptProfile(id: "sync", name: "Sync", script: "echo sync")],
      shellClient: shell,
      fileClient: fileClient,
      now: { Date(timeIntervalSince1970: 1_234) }
    )
    let bootstrap = ProjectWorkspaceRepositoryBootstrap(
      scriptKind: .userProfile,
      scriptID: "sync",
      runOn: [.manual],
      required: true
    )
    let app = ProjectWorkspace.RepositoryEntry(
      id: "app",
      name: "App",
      path: "app",
      bootstrap: bootstrap
    )
    let api = ProjectWorkspace.RepositoryEntry(
      id: "api",
      name: "API",
      path: "api",
      bootstrap: bootstrap
    )

    async let appRun: Void = executor.runner.run(
      bootstrap,
      ProjectWorkspaceBootstrapContext(
        workspaceRootURL: rootURL,
        repositoryRootURL: appURL,
        repository: app,
        timing: .manual
      )
    )
    async let apiRun: Void = executor.runner.run(
      bootstrap,
      ProjectWorkspaceBootstrapContext(
        workspaceRootURL: rootURL,
        repositoryRootURL: apiURL,
        repository: api,
        timing: .manual
      )
    )
    _ = try await (appRun, apiRun)

    let state = try loadState(from: rootURL)
    #expect(state.repositories.keys.sorted() == ["api", "app"])
  }

  @Test func runtimeSnapshotLoadsLatestStateAndAvailableLog() throws {
    let rootURL = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let logURL =
      rootURL
      .appending(path: ProjectWorkspace.metadataDirectoryName)
      .appending(path: "bootstrap-runs", directoryHint: .isDirectory)
      .appending(path: "app.log", directoryHint: .notDirectory)
    try FileManager.default.createDirectory(
      at: logURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("ok".utf8).write(to: logURL)
    try writeState(
      ProjectWorkspaceBootstrapState(
        repositories: [
          "app": ProjectWorkspaceBootstrapRepositoryState(
            lastRunAt: Date(timeIntervalSince1970: 1_234),
            lastStatus: .succeeded,
            lastScriptIDs: ["sync-app"],
            lastLogPath: ".prowl/bootstrap-runs/app.log"
          )
        ]
      ),
      to: rootURL
    )

    let snapshot = try ProjectWorkspaceBootstrapRuntimeSnapshot.load(workspaceRootURL: rootURL)

    #expect(snapshot.state.repositories["app"]?.lastStatus == .succeeded)
    #expect(snapshot.logURLsByRepositoryID["app"] == logURL)
  }

  @Test func runtimeSnapshotKeepsStateWhenLogIsMissing() throws {
    let rootURL = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try writeState(
      ProjectWorkspaceBootstrapState(
        repositories: [
          "app": ProjectWorkspaceBootstrapRepositoryState(
            lastRunAt: Date(timeIntervalSince1970: 1_234),
            lastStatus: .failed,
            lastScriptIDs: ["sync-app"],
            lastLogPath: ".prowl/bootstrap-runs/missing.log"
          )
        ]
      ),
      to: rootURL
    )

    let snapshot = try ProjectWorkspaceBootstrapRuntimeSnapshot.load(workspaceRootURL: rootURL)

    #expect(snapshot.state.repositories["app"]?.lastStatus == .failed)
    #expect(snapshot.logURLsByRepositoryID["app"] == nil)
  }

  @Test func runtimeSnapshotTreatsMissingStateAsEmpty() throws {
    let rootURL = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let snapshot = try ProjectWorkspaceBootstrapRuntimeSnapshot.load(workspaceRootURL: rootURL)

    #expect(snapshot == .empty)
  }

  @Test func runtimeSnapshotDoesNotTreatEmptyLogPathAsWorkspaceRoot() throws {
    let rootURL = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try writeState(
      ProjectWorkspaceBootstrapState(
        repositories: [
          "app": ProjectWorkspaceBootstrapRepositoryState(
            lastRunAt: Date(timeIntervalSince1970: 1_234),
            lastStatus: .succeeded,
            lastScriptIDs: ["sync-app"],
            lastLogPath: "  "
          )
        ]
      ),
      to: rootURL
    )

    let snapshot = try ProjectWorkspaceBootstrapRuntimeSnapshot.load(workspaceRootURL: rootURL)

    #expect(snapshot.state.repositories["app"]?.lastStatus == .succeeded)
    #expect(snapshot.logURLsByRepositoryID["app"] == nil)
  }

  @Test func rejectsUnsupportedRepoLocalBootstrap() async throws {
    let rootURL = try makeTemporaryRoot()
    let repoURL = rootURL.appending(path: "app", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let executor = ProjectWorkspaceBootstrapExecutor(
      profiles: [],
      shellClient: .testValue
    )
    let entry = ProjectWorkspace.RepositoryEntry(
      id: "app",
      name: "App",
      path: "app",
      bootstrap: ProjectWorkspaceRepositoryBootstrap(
        scriptKind: .repoLocal,
        scriptPath: ".prowl/bootstrap.sh",
        runOn: [.manual],
        required: true
      )
    )

    await #expect(
      throws: ProjectWorkspaceCreationError.bootstrapFailed(
        repository: "App",
        message: "Repo-local bootstrap scripts are not supported."
      )
    ) {
      try await executor.runner.run(
        try #require(entry.bootstrap),
        ProjectWorkspaceBootstrapContext(
          workspaceRootURL: rootURL,
          repositoryRootURL: repoURL,
          repository: entry,
          timing: .manual
        )
      )
    }
  }

  private func loadState(from rootURL: URL) throws -> ProjectWorkspaceBootstrapState {
    let stateURL =
      rootURL
      .appending(path: ProjectWorkspace.metadataDirectoryName)
      .appending(path: "bootstrap-state.json")
    let data = try Data(contentsOf: stateURL)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(ProjectWorkspaceBootstrapState.self, from: data)
  }

  private func writeState(_ state: ProjectWorkspaceBootstrapState, to rootURL: URL) throws {
    let stateURL =
      rootURL
      .appending(path: ProjectWorkspace.metadataDirectoryName)
      .appending(path: "bootstrap-state.json")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(state).write(to: stateURL)
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
