import Foundation

nonisolated struct ProjectWorkspaceBootstrapState: Codable, Equatable, Sendable {
  var repositories: [String: ProjectWorkspaceBootstrapRepositoryState]

  static func fileURL(for workspaceRootURL: URL) -> URL {
    workspaceRootURL
      .appending(path: ProjectWorkspace.metadataDirectoryName, directoryHint: .isDirectory)
      .appending(path: "bootstrap-state.json", directoryHint: .notDirectory)
  }
}

nonisolated struct ProjectWorkspaceBootstrapRepositoryState: Codable, Equatable, Sendable {
  var lastRunAt: Date
  var lastStatus: ProjectWorkspaceBootstrapStatus
  var lastScriptIDs: [String]
  var lastLogPath: String

  enum CodingKeys: String, CodingKey {
    case lastRunAt = "last_run_at"
    case lastStatus = "last_status"
    case lastScriptID = "last_script_id"
    case lastScriptIDs = "last_script_ids"
    case lastLogPath = "last_log_path"
  }

  var lastScriptID: String? {
    lastScriptIDs.first
  }

  init(
    lastRunAt: Date,
    lastStatus: ProjectWorkspaceBootstrapStatus,
    lastScriptIDs: [String],
    lastLogPath: String
  ) {
    self.lastRunAt = lastRunAt
    self.lastStatus = lastStatus
    self.lastScriptIDs = lastScriptIDs
    self.lastLogPath = lastLogPath
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    lastRunAt = try container.decode(Date.self, forKey: .lastRunAt)
    lastStatus = try container.decode(ProjectWorkspaceBootstrapStatus.self, forKey: .lastStatus)
    let scriptIDs = try container.decodeIfPresent([String].self, forKey: .lastScriptIDs) ?? []
    let scriptID = try container.decodeIfPresent(String.self, forKey: .lastScriptID)
    lastScriptIDs = normalizedScriptIDs(scriptIDs + [scriptID].compactMap(\.self))
    lastLogPath = try container.decode(String.self, forKey: .lastLogPath)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(lastRunAt, forKey: .lastRunAt)
    try container.encode(lastStatus, forKey: .lastStatus)
    try container.encode(lastScriptIDs, forKey: .lastScriptIDs)
    try container.encode(lastLogPath, forKey: .lastLogPath)
  }
}

nonisolated enum ProjectWorkspaceBootstrapStatus: String, Codable, Equatable, Sendable {
  case succeeded
  case failed
}

nonisolated struct ProjectWorkspaceBootstrapRuntimeSnapshot: Equatable, Sendable {
  var state: ProjectWorkspaceBootstrapState
  var logURLsByRepositoryID: [String: URL]

  static let empty = ProjectWorkspaceBootstrapRuntimeSnapshot(
    state: ProjectWorkspaceBootstrapState(repositories: [:]),
    logURLsByRepositoryID: [:]
  )

  static func load(
    workspaceRootURL: URL,
    fileClient: ProjectWorkspaceBootstrapFileClient = .live
  ) throws -> ProjectWorkspaceBootstrapRuntimeSnapshot {
    let stateURL = ProjectWorkspaceBootstrapState.fileURL(for: workspaceRootURL)
    guard fileClient.fileExists(stateURL) else {
      return .empty
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let state = try decoder.decode(
      ProjectWorkspaceBootstrapState.self,
      from: fileClient.readData(stateURL)
    )
    var logURLsByRepositoryID: [String: URL] = [:]
    for (repositoryID, repositoryState) in state.repositories {
      let logPath = repositoryState.lastLogPath.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !logPath.isEmpty else {
        continue
      }
      let candidateURL =
        if logPath.hasPrefix("/") {
          URL(fileURLWithPath: logPath)
        } else {
          workspaceRootURL.appending(path: logPath, directoryHint: .notDirectory)
        }
      let logURL = candidateURL.standardizedFileURL
      let resolvedLogURL = logURL.resolvingSymlinksInPath()
      let resolvedBootstrapLogsURL =
        workspaceRootURL
        .appending(path: ProjectWorkspace.metadataDirectoryName, directoryHint: .isDirectory)
        .appending(path: "bootstrap-runs", directoryHint: .isDirectory)
        .standardizedFileURL
        .resolvingSymlinksInPath()
      let resolvedLogPath = resolvedLogURL.path(percentEncoded: false)
      let bootstrapLogsPath = resolvedBootstrapLogsURL.path(percentEncoded: false)
      let bootstrapLogsPrefix = bootstrapLogsPath.hasSuffix("/") ? bootstrapLogsPath : bootstrapLogsPath + "/"
      guard resolvedLogPath.hasPrefix(bootstrapLogsPrefix) else {
        continue
      }
      if fileClient.fileExists(logURL) {
        logURLsByRepositoryID[repositoryID] = logURL
      }
    }
    return ProjectWorkspaceBootstrapRuntimeSnapshot(
      state: state,
      logURLsByRepositoryID: logURLsByRepositoryID
    )
  }
}

nonisolated struct ProjectWorkspaceBootstrapFileClient: Sendable {
  var createDirectory: @Sendable (URL) throws -> Void
  var createFile: @Sendable (URL) -> Void
  var readData: @Sendable (URL) throws -> Data
  var writeData: @Sendable (Data, URL) throws -> Void
  var setExecutable: @Sendable (URL) throws -> Void
  var fileHandleForWriting: @Sendable (URL) throws -> FileHandle
  var removeItem: @Sendable (URL) throws -> Void
  var fileExists: @Sendable (URL) -> Bool

  static let live = ProjectWorkspaceBootstrapFileClient(
    createDirectory: { url in
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    },
    createFile: { url in
      _ = FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
    },
    readData: { url in
      try Data(contentsOf: url)
    },
    writeData: { data, url in
      try data.write(to: url, options: .atomic)
    },
    setExecutable: { url in
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: url.path(percentEncoded: false)
      )
    },
    fileHandleForWriting: { url in
      try FileHandle(forWritingTo: url)
    },
    removeItem: { url in
      try FileManager.default.removeItem(at: url)
    },
    fileExists: { url in
      FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
  )
}

nonisolated struct ProjectWorkspaceBootstrapExecutor: Sendable {
  var profiles: [ScriptProfile]
  var shellClient: ShellClient
  var fileClient: ProjectWorkspaceBootstrapFileClient
  var now: @Sendable () -> Date
  var clock: any Clock<Duration>

  init<C: Clock<Duration>>(
    profiles: [ScriptProfile],
    shellClient: ShellClient,
    fileClient: ProjectWorkspaceBootstrapFileClient = .live,
    now: @escaping @Sendable () -> Date = Date.init,
    clock: C = ContinuousClock()
  ) {
    self.profiles = profiles.map(\.normalized)
    self.shellClient = shellClient
    self.fileClient = fileClient
    self.now = now
    self.clock = clock
  }

  var runner: ProjectWorkspaceBootstrapRunner {
    ProjectWorkspaceBootstrapRunner { bootstrap, context in
      try await run(bootstrap, context: context)
    }
  }

  private func run(
    _ bootstrap: ProjectWorkspaceRepositoryBootstrap,
    context: ProjectWorkspaceBootstrapContext
  ) async throws {
    guard bootstrap.scriptKind == .userProfile else {
      throw ProjectWorkspaceCreationError.bootstrapFailed(
        repository: context.repository.name,
        message: "Repo-local bootstrap scripts are not supported."
      )
    }
    let scriptIDs = normalizedScriptIDs(bootstrap.scriptIDs)
    guard !scriptIDs.isEmpty else {
      throw ProjectWorkspaceCreationError.bootstrapProfileNotFound("")
    }
    var profilesByID: [String: ScriptProfile] = [:]
    for profile in profiles where profilesByID[profile.id] == nil {
      profilesByID[profile.id] = profile
    }
    let orderedProfiles = try scriptIDs.map { scriptID in
      guard let profile = profilesByID[scriptID] else {
        throw ProjectWorkspaceCreationError.bootstrapProfileNotFound(scriptID)
      }
      return profile
    }

    let logURL = try makeLogURL(for: context.repository, workspaceRootURL: context.workspaceRootURL)
    var firstError: Error?
    for profile in orderedProfiles {
      do {
        try await runProfile(profile, context: context, logURL: logURL)
      } catch {
        if firstError == nil {
          firstError = error
        }
        guard !bootstrap.required else {
          try? await writeState(
            status: .failed,
            scriptIDs: scriptIDs,
            logURL: logURL,
            context: context
          )
          throw error
        }
      }
    }

    if let firstError {
      try await writeState(
        status: .failed,
        scriptIDs: scriptIDs,
        logURL: logURL,
        context: context
      )
      throw firstError
    } else {
      try await writeState(
        status: .succeeded,
        scriptIDs: scriptIDs,
        logURL: logURL,
        context: context
      )
    }
  }

  private func runProfile(
    _ profile: ScriptProfile,
    context: ProjectWorkspaceBootstrapContext,
    logURL: URL
  ) async throws {
    let scriptURL = try makeScriptURL(for: profile, context: context)
    try fileClient.writeData(Data(profile.script.utf8), scriptURL)
    try fileClient.setExecutable(scriptURL)
    defer {
      try? fileClient.removeItem(scriptURL)
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        let stream = shellClient.runLoginStream(
          URL(fileURLWithPath: "/bin/sh"),
          ["-c", profile.command],
          context.repositoryRootURL,
          environment: environment(for: context, profile: profile, scriptURL: scriptURL),
          log: false
        )
        try await write(stream, to: logURL, profileID: profile.id)
      }
      group.addTask {
        try await clock.sleep(for: .seconds(profile.timeoutSeconds))
        throw ProjectWorkspaceCreationError.bootstrapFailed(
          repository: context.repository.name,
          message: "Timed out after \(profile.timeoutSeconds) seconds"
        )
      }

      do {
        try await group.next()
        group.cancelAll()
      } catch {
        group.cancelAll()
        throw error
      }
    }
  }

  private func write(
    _ stream: AsyncThrowingStream<ShellStreamEvent, Error>,
    to logURL: URL,
    profileID: String
  ) async throws {
    let directoryURL = logURL.deletingLastPathComponent()
    try fileClient.createDirectory(directoryURL)
    fileClient.createFile(logURL)
    let handle = try fileClient.fileHandleForWriting(logURL)
    defer {
      try? handle.close()
    }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("[profile] \(profileID)\n".utf8))
    for try await event in stream {
      switch event {
      case .line(let line):
        let prefix =
          switch line.source {
          case .stdout:
            "stdout"
          case .stderr:
            "stderr"
          }
        try handle.write(contentsOf: Data("[\(prefix)] \(line.text)\n".utf8))
      case .finished(let output):
        try handle.write(contentsOf: Data("[exit] \(output.exitCode)\n".utf8))
      }
    }
  }

  private func environment(
    for context: ProjectWorkspaceBootstrapContext,
    profile: ScriptProfile,
    scriptURL: URL
  ) -> [String: String] {
    var environment = [
      "PROWL_WORKSPACE_ROOT": context.workspaceRootURL.path(percentEncoded: false),
      "PROWL_REPOSITORY_ROOT": context.repositoryRootURL.path(percentEncoded: false),
      "PROWL_REPOSITORY_ID": context.repository.id,
      "PROWL_REPOSITORY_NAME": context.repository.name,
      "PROWL_REPOSITORY_PATH": context.repository.path,
      "PROWL_SOURCE_KIND": context.repository.sourceKind.rawValue,
      "PROWL_SOURCE_LOCATION": context.repository.sourceLocation ?? "",
      "PROWL_BRANCH_NAME": context.repository.branchName ?? "",
      "PROWL_BASE_REF": context.repository.baseRef ?? "",
    ]
    environment.merge(profile.environment, uniquingKeysWith: { _, custom in custom })
    environment[ScriptProfile.scriptEnvironmentKey] =
      scriptURL.path(percentEncoded: false)
    return environment
  }

  private func makeScriptURL(
    for profile: ScriptProfile,
    context: ProjectWorkspaceBootstrapContext
  ) throws -> URL {
    let directoryURL =
      context.workspaceRootURL
      .appending(path: ProjectWorkspace.metadataDirectoryName, directoryHint: .isDirectory)
      .appending(path: "bootstrap-scripts", directoryHint: .isDirectory)
    try fileClient.createDirectory(directoryURL)
    let timestamp = ISO8601DateFormatter().string(from: now()).replacing(":", with: "-")
    let name = trimmedNonEmpty(sanitizedLogComponent(profile.id)) ?? "bootstrap"
    return directoryURL.appending(
      path: "\(sanitizedLogComponent(name))-\(timestamp)-\(UUID().uuidString).sh"
    )
  }

  private func makeLogURL(
    for repository: ProjectWorkspace.RepositoryEntry,
    workspaceRootURL: URL
  ) throws -> URL {
    let directoryURL =
      workspaceRootURL
      .appending(path: ProjectWorkspace.metadataDirectoryName, directoryHint: .isDirectory)
      .appending(path: "bootstrap-runs", directoryHint: .isDirectory)
    try fileClient.createDirectory(directoryURL)
    let timestamp = ISO8601DateFormatter().string(from: now()).replacing(":", with: "-")
    let name = trimmedNonEmpty(sanitizedLogComponent(repository.name)) ?? repository.id
    return directoryURL.appending(
      path: "\(sanitizedLogComponent(name))-\(timestamp)-\(UUID().uuidString).log"
    )
  }

  private func writeState(
    status: ProjectWorkspaceBootstrapStatus,
    scriptIDs: [String],
    logURL: URL,
    context: ProjectWorkspaceBootstrapContext
  ) async throws {
    let stateURL = ProjectWorkspaceBootstrapState.fileURL(for: context.workspaceRootURL)
    let repositoryState = ProjectWorkspaceBootstrapRepositoryState(
      lastRunAt: now(),
      lastStatus: status,
      lastScriptIDs: scriptIDs,
      lastLogPath: relativePath(for: logURL, workspaceRootURL: context.workspaceRootURL)
    )
    try await ProjectWorkspaceBootstrapStateWriter.shared.write(
      repositoryID: context.repository.id,
      repositoryState: repositoryState,
      stateURL: stateURL,
      fileClient: fileClient
    )
  }

  private func relativePath(for url: URL, workspaceRootURL: URL) -> String {
    let candidates = [
      (
        workspaceRootURL.path(percentEncoded: false),
        url.path(percentEncoded: false)
      ),
      (
        workspaceRootURL.standardizedFileURL.path(percentEncoded: false),
        url.standardizedFileURL.path(percentEncoded: false)
      ),
      (
        workspaceRootURL.resolvingSymlinksInPath().path(percentEncoded: false),
        url.resolvingSymlinksInPath().path(percentEncoded: false)
      ),
    ]
    for (rootPath, path) in candidates where path.hasPrefix(rootPath + "/") {
      return String(path.dropFirst(rootPath.count + 1))
    }
    return url.path(percentEncoded: false)
  }

  private func sanitizedLogComponent(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let scalars = value.unicodeScalars.map { allowed.contains($0) ? $0 : "-" }
    return String(String.UnicodeScalarView(scalars)).trimmingCharacters(
      in: CharacterSet(charactersIn: "-"))
  }

  private func trimmedNonEmpty(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

private actor ProjectWorkspaceBootstrapStateWriter {
  static let shared = ProjectWorkspaceBootstrapStateWriter()

  func write(
    repositoryID: String,
    repositoryState: ProjectWorkspaceBootstrapRepositoryState,
    stateURL: URL,
    fileClient: ProjectWorkspaceBootstrapFileClient
  ) throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let state =
      if let data = try? fileClient.readData(stateURL),
        let decoded = try? decoder.decode(ProjectWorkspaceBootstrapState.self, from: data)
      {
        decoded
      } else {
        ProjectWorkspaceBootstrapState(repositories: [:])
      }
    var repositories = state.repositories
    repositories[repositoryID] = repositoryState

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try fileClient.writeData(
      encoder.encode(ProjectWorkspaceBootstrapState(repositories: repositories)),
      stateURL
    )
  }
}

private nonisolated func normalizedScriptIDs(_ values: [String]) -> [String] {
  var seen = Set<String>()
  var result: [String] = []
  for value in values {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, seen.insert(trimmed).inserted else {
      continue
    }
    result.append(trimmed)
  }
  return result
}
