import Foundation

nonisolated struct ProjectWorkspaceBootstrapState: Codable, Equatable, Sendable {
  var repositories: [String: ProjectWorkspaceBootstrapRepositoryState]
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

nonisolated struct ProjectWorkspaceBootstrapFileClient: Sendable {
  var createDirectory: @Sendable (URL) throws -> Void
  var createFile: @Sendable (URL) -> Void
  var readData: @Sendable (URL) throws -> Data
  var writeData: @Sendable (Data, URL) throws -> Void
  var setExecutable: @Sendable (URL) throws -> Void
  var fileHandleForWriting: @Sendable (URL) throws -> FileHandle
  var removeItem: @Sendable (URL) throws -> Void

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
    }
  )
}

nonisolated struct ProjectWorkspaceBootstrapExecutor: Sendable {
  var profiles: [ProjectWorkspaceBootstrapProfile]
  var shellClient: ShellClient
  var fileClient: ProjectWorkspaceBootstrapFileClient
  var now: @Sendable () -> Date
  var clock: any Clock<Duration>

  init<C: Clock<Duration>>(
    profiles: [ProjectWorkspaceBootstrapProfile],
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
      return
    }
    let scriptIDs = normalizedScriptIDs(bootstrap.scriptIDs)
    guard !scriptIDs.isEmpty else {
      throw ProjectWorkspaceCreationError.bootstrapProfileNotFound("")
    }
    var profilesByID: [String: ProjectWorkspaceBootstrapProfile] = [:]
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
          try? writeState(
            status: .failed,
            scriptIDs: scriptIDs,
            logURL: logURL,
            context: context
          )
          throw error
        }
      }
    }

    if firstError != nil {
      try writeState(
        status: .failed,
        scriptIDs: scriptIDs,
        logURL: logURL,
        context: context
      )
    } else {
      try writeState(
        status: .succeeded,
        scriptIDs: scriptIDs,
        logURL: logURL,
        context: context
      )
    }
  }

  private func runProfile(
    _ profile: ProjectWorkspaceBootstrapProfile,
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
    profile: ProjectWorkspaceBootstrapProfile,
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
      "script": scriptURL.path(percentEncoded: false),
    ]
    environment.merge(profile.environment, uniquingKeysWith: { _, custom in custom })
    return environment
  }

  private func makeScriptURL(
    for profile: ProjectWorkspaceBootstrapProfile,
    context: ProjectWorkspaceBootstrapContext
  ) throws -> URL {
    let directoryURL =
      context.workspaceRootURL
      .appending(path: ProjectWorkspace.metadataDirectoryName, directoryHint: .isDirectory)
      .appending(path: "bootstrap-scripts", directoryHint: .isDirectory)
    try fileClient.createDirectory(directoryURL)
    let timestamp = ISO8601DateFormatter().string(from: now()).replacing(":", with: "-")
    let name = trimmedNonEmpty(sanitizedLogComponent(profile.id)) ?? "bootstrap"
    return directoryURL.appending(path: "\(sanitizedLogComponent(name))-\(timestamp).sh")
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
    return directoryURL.appending(path: "\(sanitizedLogComponent(name))-\(timestamp).log")
  }

  private func writeState(
    status: ProjectWorkspaceBootstrapStatus,
    scriptIDs: [String],
    logURL: URL,
    context: ProjectWorkspaceBootstrapContext
  ) throws {
    let stateURL = context.workspaceRootURL
      .appending(path: ProjectWorkspace.metadataDirectoryName, directoryHint: .isDirectory)
      .appending(path: "bootstrap-state.json", directoryHint: .notDirectory)
    let state = try loadState(from: stateURL)
    var repositories = state.repositories
    repositories[context.repository.id] = ProjectWorkspaceBootstrapRepositoryState(
      lastRunAt: now(),
      lastStatus: status,
      lastScriptIDs: scriptIDs,
      lastLogPath: relativePath(for: logURL, workspaceRootURL: context.workspaceRootURL)
    )
    let updated = ProjectWorkspaceBootstrapState(repositories: repositories)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(updated)
    try fileClient.writeData(data, stateURL)
  }

  private func loadState(from url: URL) throws -> ProjectWorkspaceBootstrapState {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let data = try? fileClient.readData(url),
      let state = try? decoder.decode(ProjectWorkspaceBootstrapState.self, from: data)
    else {
      return ProjectWorkspaceBootstrapState(repositories: [:])
    }
    return state
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
    return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }

  private func trimmedNonEmpty(_ value: String?) -> String? {
    guard let value else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
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
