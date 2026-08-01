import Foundation

struct GitClient {
  private struct WorktreeSortEntry {
    let worktree: Worktree
    let createdAt: Date
    let index: Int
  }

  private let shell: ShellClient

  nonisolated init(shell: ShellClient = .live) {
    self.shell = shell
  }

  nonisolated func repoRoot(for path: URL) async throws -> URL {
    let normalizedPath = Self.directoryURL(for: path)
    let wtURL = try wtScriptURL()
    let output = try await runBundledWtProcess(
      operation: .repoRoot,
      executableURL: wtURL,
      arguments: ["root"],
      currentDirectoryURL: normalizedPath
    )
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      let command = "\(wtURL.lastPathComponent) root"
      throw GitClientError.commandFailed(command: command, message: "Empty output")
    }
    return URL(fileURLWithPath: trimmed).standardizedFileURL
  }

  nonisolated func worktrees(for repoRoot: URL) async throws -> [Worktree] {
    let repositoryRootURL = repoRoot.standardizedFileURL
    let output = try await runWtList(repoRoot: repoRoot)
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return []
    }
    let data = Data(trimmed.utf8)
    let entries = try JSONDecoder().decode([GitWtWorktreeEntry].self, from: data)
      .filter { !$0.isBare }
    var seenWorktreeIDs = Set<Worktree.ID>()
    let worktreeEntries: [WorktreeSortEntry] = entries.enumerated().compactMap { index, entry -> WorktreeSortEntry? in
      let worktreeURL = URL(fileURLWithPath: entry.path).standardizedFileURL
      let name = entry.branch.isEmpty ? worktreeURL.lastPathComponent : entry.branch
      let detail = Self.relativePath(from: repositoryRootURL, to: worktreeURL)
      let id = worktreeURL.path(percentEncoded: false)
      guard seenWorktreeIDs.insert(id).inserted else {
        return nil
      }
      let resourceValues = try? worktreeURL.resourceValues(forKeys: [
        .creationDateKey, .contentModificationDateKey,
      ])
      let createdAt = resourceValues?.creationDate ?? resourceValues?.contentModificationDate
      let sortDate = createdAt ?? .distantPast
      return WorktreeSortEntry(
        worktree: Worktree(
          id: id,
          name: name,
          detail: detail,
          workingDirectory: worktreeURL,
          repositoryRootURL: repositoryRootURL,
          createdAt: createdAt
        ),
        createdAt: sortDate,
        index: index
      )
    }
    return
      worktreeEntries
      .sorted { lhs, rhs in
        if lhs.createdAt != rhs.createdAt {
          return lhs.createdAt > rhs.createdAt
        }
        return lhs.index < rhs.index
      }
      .map(\.worktree)
  }

  nonisolated func pruneWorktrees(for repoRoot: URL) async throws {
    let path = repoRoot.path(percentEncoded: false)
    _ = try await runGit(
      operation: .worktreePrune,
      arguments: ["-C", path, "worktree", "prune"]
    )
  }

  nonisolated func localBranchNames(for repoRoot: URL) async throws -> Set<String> {
    let path = repoRoot.path(percentEncoded: false)
    let output = try await runGit(
      operation: .branchNames,
      arguments: [
        "-C",
        path,
        "for-each-ref",
        "--format=%(refname:short)",
        "refs/heads",
      ]
    )
    let names =
      output
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }
    return Set(names)
  }

  nonisolated func isValidBranchName(_ branchName: String, for repoRoot: URL) async -> Bool {
    let path = repoRoot.path(percentEncoded: false)
    do {
      _ = try await runGit(
        operation: .branchNameValidation,
        arguments: ["-C", path, "check-ref-format", "--branch", branchName]
      )
      return true
    } catch {
      return false
    }
  }

  nonisolated func isBareRepository(for repoRoot: URL) async throws -> Bool {
    let path = repoRoot.path(percentEncoded: false)
    let output = try await runGit(
      operation: .repoIsBare,
      arguments: ["-C", path, "rev-parse", "--is-bare-repository"]
    )
    return output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
  }

  nonisolated func branchRefs(for repoRoot: URL) async throws -> [String] {
    try await branchRefOptions(for: repoRoot).map(\.ref)
  }

  nonisolated func branchRefOptions(for repoRoot: URL) async throws -> [GitBranchRefOption] {
    let path = repoRoot.path(percentEncoded: false)
    let localOutput = try await runGit(
      operation: .branchRefs,
      arguments: [
        "-C",
        path,
        "for-each-ref",
        "--format=%(refname)",
        "refs/heads",
      ]
    )
    let remoteOutput = try await runGit(
      operation: .branchRefs,
      arguments: [
        "-C",
        path,
        "for-each-ref",
        "--format=%(refname)",
        "refs/remotes",
      ]
    )
    let localRefs = parseRefLines(localOutput, prefix: "refs/heads/")
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    let remoteRefs = parseRefLines(remoteOutput, prefix: "refs/remotes/")
      // Drop `<remote>/HEAD` symbolic pointers: they resolve to a branch that is
      // already listed, and selecting one would derive an invalid `HEAD` branch
      // name in the remote-tracking checkout path.
      .filter { !$0.hasSuffix("/HEAD") }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    return deduplicatedOptions(
      localRefs.map { GitBranchRefOption(ref: $0, kind: .local) }
        + remoteRefs.map { GitBranchRefOption(ref: $0, kind: .remoteTracking) }
    )
  }

  nonisolated func remoteBranchRefs(for remoteURL: String) async throws -> GitRemoteBranchRefs {
    let output = try await runGit(
      operation: .remoteBranchRefs,
      arguments: ["ls-remote", "--symref", "--end-of-options", remoteURL, "HEAD", "refs/heads/*"]
    )
    let parsed = parseRemoteBranchRefs(output)
    let options = parsed.refs
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
      .map { GitBranchRefOption(ref: "origin/\($0)", kind: .fetchedRemote) }
    let defaultBaseRef =
      parsed.defaultBranch.map { "origin/\($0)" }
      ?? options.first?.ref
    return GitRemoteBranchRefs(options: deduplicatedOptions(options), defaultBaseRef: defaultBaseRef)
  }

  nonisolated func defaultRemoteBranchRef(for repoRoot: URL) async throws -> String? {
    let path = repoRoot.path(percentEncoded: false)
    do {
      let output = try await runGit(
        operation: .defaultRemoteBranchRef,
        arguments: ["-C", path, "symbolic-ref", "-q", "refs/remotes/origin/HEAD"]
      )
      let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
      if let resolved = normalizeRemoteRef(trimmed),
        await refExists(resolved, repoRoot: repoRoot)
      {
        return resolved
      }
    } catch {
      let rootPath = repoRoot.path(percentEncoded: false)
      gitLogger.warning(
        "Default remote branch ref failed for \(rootPath): \(error.localizedDescription)"
      )
    }
    let fallback = "origin/main"
    if await refExists(fallback, repoRoot: repoRoot) {
      return fallback
    }
    return nil
  }

  nonisolated func automaticWorktreeBaseRef(for repoRoot: URL) async -> String? {
    let resolved = try? await defaultRemoteBranchRef(for: repoRoot)
    if let resolved {
      return Self.preferredBaseRef(remote: resolved, localHead: nil)
    }
    let localHead = try? await localHeadBranchRef(for: repoRoot)
    let resolvedLocalHead = await resolveLocalHead(localHead, repoRoot: repoRoot)
    return Self.preferredBaseRef(remote: nil, localHead: resolvedLocalHead)
  }

  nonisolated func ignoredFileCount(for repoRoot: URL) async throws -> Int {
    let path = repoRoot.path(percentEncoded: false)
    let output = try await runGit(
      operation: .ignoredFileCount,
      arguments: ["-C", path, "ls-files", "--others", "-i", "--exclude-standard"]
    )
    return parseFileListCount(output)
  }

  nonisolated func untrackedFileCount(for repoRoot: URL) async throws -> Int {
    let path = repoRoot.path(percentEncoded: false)
    let output = try await runGit(
      operation: .untrackedFileCount,
      arguments: ["-C", path, "ls-files", "--others", "--exclude-standard"]
    )
    return parseFileListCount(output)
  }

  nonisolated func createWorktree(
    named name: String,
    in repoRoot: URL,
    baseDirectory: URL,
    copyFiles: (ignored: Bool, untracked: Bool),
    baseRef: String
  ) async throws -> Worktree {
    var createdWorktree: Worktree?
    for try await event in createWorktreeStream(
      GitWorktreeCreateRequest(
        name: name,
        repoRoot: repoRoot,
        baseDirectory: baseDirectory,
        copyFiles: GitWorktreeCreateRequest.CopyFiles(ignored: copyFiles.ignored, untracked: copyFiles.untracked),
        baseRef: baseRef
      )
    ) {
      if case .finished(let worktree) = event {
        createdWorktree = worktree
      }
    }
    guard let createdWorktree else {
      let wtURL = try wtScriptURL()
      let command =
        ([wtURL.lastPathComponent]
        + createWorktreeArguments(
          baseDirectory: baseDirectory,
          name: name,
          copyIgnored: copyFiles.ignored,
          copyUntracked: copyFiles.untracked,
          baseRef: baseRef
        )).joined(separator: " ")
      throw GitClientError.commandFailed(command: command, message: "Empty output")
    }
    return createdWorktree
  }

  nonisolated func createWorktreeStream(
    _ request: GitWorktreeCreateRequest
  ) -> AsyncThrowingStream<GitWorktreeCreateEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        let repositoryRootURL = request.repoRoot.standardizedFileURL
        do {
          let wtURL = try wtScriptURL()
          let arguments = createWorktreeArguments(
            baseDirectory: request.baseDirectory,
            name: request.name,
            copyIgnored: request.copyFiles.ignored,
            copyUntracked: request.copyFiles.untracked,
            baseRef: request.baseRef,
            directoryOverride: request.directoryOverride
          )
          let envURL = URL(fileURLWithPath: "/usr/bin/env")
          let localeArguments = ["LANG=C", "LC_ALL=C", "LC_MESSAGES=C"]
          let invocationArguments = localeArguments + [wtURL.path(percentEncoded: false)] + arguments
          let command = ([envURL.path(percentEncoded: false)] + invocationArguments).joined(separator: " ")
          var pathLine: String?
          do {
            for try await streamEvent in shell.runLoginStream(
              envURL,
              invocationArguments,
              request.repoRoot
            ) {
              switch streamEvent {
              case .line(let line):
                continuation.yield(.outputLine(line))
                if line.source == .stdout {
                  let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                  if !trimmed.isEmpty {
                    pathLine = trimmed
                  }
                }
              case .finished(let output):
                if pathLine == nil {
                  pathLine = lastNonEmptyLine(in: output.stdout)
                }
                guard let pathLine else {
                  throw GitClientError.commandFailed(command: command, message: "Empty output")
                }
                let worktreeURL = URL(fileURLWithPath: pathLine).standardizedFileURL
                let detail = Self.relativePath(from: repositoryRootURL, to: worktreeURL)
                let id = worktreeURL.path(percentEncoded: false)
                let resourceValues = try? worktreeURL.resourceValues(forKeys: [
                  .creationDateKey, .contentModificationDateKey,
                ])
                let createdAt = resourceValues?.creationDate ?? resourceValues?.contentModificationDate
                let worktree = Worktree(
                  id: id,
                  name: request.name,
                  detail: detail,
                  workingDirectory: worktreeURL,
                  repositoryRootURL: repositoryRootURL,
                  createdAt: createdAt
                )
                continuation.yield(.finished(worktree))
                continuation.finish()
                return
              }
            }
            continuation.finish(throwing: GitClientError.commandFailed(command: command, message: "Empty output"))
          } catch {
            if let gitError = error as? GitClientError {
              continuation.finish(throwing: gitError)
            } else {
              continuation.finish(
                throwing: wrapShellError(error, operation: .worktreeCreate, command: command)
              )
            }
          }
        } catch {
          continuation.finish(throwing: error)
        }
      }
    }
  }

  nonisolated private func createWorktreeArguments(
    baseDirectory: URL,
    name: String,
    copyIgnored: Bool,
    copyUntracked: Bool,
    baseRef: String,
    directoryOverride: URL? = nil
  ) -> [String] {
    var arguments = ["--base-dir", baseDirectory.path(percentEncoded: false), "sw"]
    if copyIgnored {
      arguments.append("--copy-ignored")
    }
    if copyUntracked {
      arguments.append("--copy-untracked")
    }
    if !baseRef.isEmpty {
      arguments.append("--from")
      arguments.append(baseRef)
    }
    if let directoryOverride {
      arguments.append("--path")
      arguments.append(directoryOverride.path(percentEncoded: false))
    }
    if copyIgnored || copyUntracked {
      arguments.append("--verbose")
    }
    arguments.append(name)
    return arguments
  }

  nonisolated func renameBranch(in worktreeURL: URL, to branchName: String) async throws {
    let path = worktreeURL.path(percentEncoded: false)
    _ = try await runGit(
      operation: .branchRename,
      arguments: ["-C", path, "branch", "-m", branchName]
    )
  }

  nonisolated func branchName(for worktreeURL: URL) async -> String? {
    let headURL = await MainActor.run {
      GitWorktreeHeadResolver.headURL(
        for: worktreeURL,
        fileManager: .default
      )
    }
    guard let headURL else {
      return nil
    }
    guard
      let line = try? String(contentsOf: headURL, encoding: .utf8)
        .split(whereSeparator: \.isNewline)
        .first
    else {
      return nil
    }
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    let refPrefix = "ref:"
    if trimmed.hasPrefix(refPrefix) {
      let ref = trimmed.dropFirst(refPrefix.count).trimmingCharacters(in: .whitespaces)
      let headsPrefix = "refs/heads/"
      if ref.hasPrefix(headsPrefix) {
        return String(ref.dropFirst(headsPrefix.count))
      }
      return String(ref)
    }
    return "HEAD"
  }

  nonisolated func lineChanges(at worktreeURL: URL) async -> GitLineChanges? {
    if await isWorktreeIndexLocked(worktreeURL) {
      return nil
    }
    let path = worktreeURL.path(percentEncoded: false)
    do {
      async let diffOutput = runGit(
        operation: .lineChanges,
        arguments: ["-C", path, "diff", "HEAD", "--shortstat"]
      )
      async let untrackedOutput = runGit(
        operation: .untrackedFilePaths,
        arguments: ["-C", path, "-c", "core.quotePath=false", "ls-files", "--others", "--exclude-standard", "-z"]
      )
      let tracked = parseShortstat(try await diffOutput)
      let untrackedPaths = parseNULFileList(try await untrackedOutput)
      let untracked = Self.countLinesInFiles(untrackedPaths, relativeTo: worktreeURL)
      return GitLineChanges(
        added: tracked.added + untracked.lines,
        removed: tracked.removed,
        skippedUntrackedFileCount: untracked.skippedFileCount
      )
    } catch {
      return nil
    }
  }

  nonisolated static func indexEntryCount(at worktreeURL: URL) -> Int? {
    let gitDir = resolveGitDirectory(for: worktreeURL)
    guard let gitDir else { return nil }
    let indexURL = gitDir.appending(path: "index")
    guard let handle = try? FileHandle(forReadingFrom: indexURL) else { return nil }
    defer { try? handle.close() }
    guard let header = try? handle.read(upToCount: 12), header.count == 12 else { return nil }
    guard header.prefix(4).elementsEqual("DIRC".utf8) else { return nil }
    let version = Self.bigEndianUInt32(from: header, offset: 4)
    guard (2...4).contains(version) else { return nil }
    return Int(Self.bigEndianUInt32(from: header, offset: 8))
  }

  nonisolated static let untrackedLineCountByteBudget = 32 * 1_024 * 1_024
  nonisolated static let untrackedLineCountCacheUpdateBatchSize = 256

  nonisolated static func countLinesInFiles(
    _ relativePaths: [String],
    relativeTo base: URL,
    cache: UntrackedLineCountCache = .shared,
    byteBudget: Int = untrackedLineCountByteBudget
  ) -> UntrackedLineCountResult {
    struct FileToCount {
      let relativePath: String
      let url: URL
      let fingerprint: UntrackedLineFileFingerprint
    }

    let resourceKeys: Set<URLResourceKey> = [
      .contentModificationDateKey,
      .fileResourceIdentifierKey,
      .fileSizeKey,
    ]
    var skippedFileCount = 0
    let files = relativePaths.compactMap { relativePath -> FileToCount? in
      let fileURL = base.appending(path: relativePath)
      guard let values = try? fileURL.resourceValues(forKeys: resourceKeys),
        let byteCount = values.fileSize,
        let modificationDate = values.contentModificationDate
      else {
        if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
          skippedFileCount += 1
        }
        return nil
      }
      return FileToCount(
        relativePath: relativePath,
        url: fileURL,
        fingerprint: UntrackedLineFileFingerprint(
          byteCount: byteCount,
          modificationDate: modificationDate,
          resourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) }
        )
      )
    }
    let worktreeKey = base.standardizedFileURL.path(percentEncoded: false)
    let cacheFiles = files.map {
      UntrackedLineCacheFile(relativePath: $0.relativePath, fingerprint: $0.fingerprint)
    }
    let cachedValues = cache.cachedValues(for: cacheFiles, worktreeKey: worktreeKey)

    var total = 0
    var misses: [FileToCount] = []
    for file in files {
      switch cachedValues[file.relativePath] {
      case .text(let lines):
        total += lines
      case .binary:
        break
      case nil:
        misses.append(file)
      }
    }

    var remainingByteBudget = max(0, byteBudget)
    var cacheUpdates: [UntrackedLineCacheUpdate] = []
    cacheUpdates.reserveCapacity(untrackedLineCountCacheUpdateBatchSize)
    for file in misses.sorted(by: { lhs, rhs in
      if lhs.fingerprint.byteCount == rhs.fingerprint.byteCount {
        return lhs.relativePath < rhs.relativePath
      }
      return lhs.fingerprint.byteCount < rhs.fingerprint.byteCount
    }) {
      guard file.fingerprint.byteCount <= remainingByteBudget else {
        skippedFileCount += 1
        continue
      }
      let cacheUpdate: UntrackedLineCacheUpdate?
      switch Self.countLines(in: file.url, maximumByteCount: remainingByteBudget) {
      case .text(let lines, let bytesRead):
        total += lines
        remainingByteBudget -= bytesRead
        cacheUpdate = UntrackedLineCacheUpdate(
          relativePath: file.relativePath,
          fingerprint: file.fingerprint,
          value: .text(lines)
        )
      case .binary(let bytesRead):
        remainingByteBudget -= bytesRead
        cacheUpdate = UntrackedLineCacheUpdate(
          relativePath: file.relativePath,
          fingerprint: file.fingerprint,
          value: .binary
        )
      case .budgetExceeded:
        remainingByteBudget = 0
        skippedFileCount += 1
        cacheUpdate = nil
      case .unavailable(let bytesRead):
        remainingByteBudget -= bytesRead
        skippedFileCount += 1
        cacheUpdate = nil
      }
      if let cacheUpdate {
        cacheUpdates.append(cacheUpdate)
        if cacheUpdates.count == untrackedLineCountCacheUpdateBatchSize {
          cache.store(cacheUpdates, worktreeKey: worktreeKey)
          cacheUpdates.removeAll(keepingCapacity: true)
        }
      }
    }
    cache.store(cacheUpdates, worktreeKey: worktreeKey)
    return UntrackedLineCountResult(lines: total, skippedFileCount: skippedFileCount)
  }

  nonisolated private static func bigEndianUInt32(from data: Data, offset: Int) -> UInt32 {
    data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
  }

  nonisolated private enum FileLineCountResult {
    case text(lines: Int, bytesRead: Int)
    case binary(bytesRead: Int)
    case budgetExceeded
    case unavailable(bytesRead: Int)
  }

  nonisolated private static func countLines(
    in fileURL: URL,
    maximumByteCount: Int
  ) -> FileLineCountResult {
    guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
      return .unavailable(bytesRead: 0)
    }
    defer { try? handle.close() }

    let binaryProbeByteCount = 8_192
    let chunkByteCount = 64 * 1_024
    var bytesRead = 0
    var probedByteCount = 0
    var lineCount = 0
    var isEmpty = true
    var lastByte: UInt8?

    while true {
      let chunk: Data
      do {
        // The extra byte distinguishes a file exactly at the budget from one
        // that grew after its metadata fingerprint was collected.
        let allowedReadCount = min(chunkByteCount, maximumByteCount - bytesRead + 1)
        guard allowedReadCount > 0 else { return .budgetExceeded }
        guard let readChunk = try handle.read(upToCount: allowedReadCount) else { break }
        chunk = readChunk
      } catch {
        return .unavailable(bytesRead: bytesRead)
      }
      guard !chunk.isEmpty else { break }
      bytesRead += chunk.count
      guard bytesRead <= maximumByteCount else { return .budgetExceeded }

      isEmpty = false
      if probedByteCount < binaryProbeByteCount {
        let remainingProbeCount = binaryProbeByteCount - probedByteCount
        let probe = chunk.prefix(remainingProbeCount)
        if probe.containsByte(0x00) { return .binary(bytesRead: bytesRead) }
        probedByteCount += probe.count
      }
      lineCount += chunk.countOccurrences(of: 0x0A)
      lastByte = chunk.last
    }

    if !isEmpty, lastByte != 0x0A {
      lineCount += 1
    }
    return .text(lines: lineCount, bytesRead: bytesRead)
  }

  nonisolated private static func resolveGitDirectory(for worktreeURL: URL) -> URL? {
    let gitURL = worktreeURL.appending(path: ".git")
    var isDirectory = ObjCBool(false)
    guard
      FileManager.default.fileExists(
        atPath: gitURL.path(percentEncoded: false),
        isDirectory: &isDirectory
      )
    else {
      return nil
    }
    if isDirectory.boolValue {
      return gitURL
    }
    guard
      let contents = try? String(contentsOf: gitURL, encoding: .utf8),
      let line = contents.split(whereSeparator: \.isNewline).first
    else {
      return nil
    }
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("gitdir:") else { return nil }
    let pathPart = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pathPart.isEmpty else { return nil }
    return URL(fileURLWithPath: String(pathPart), relativeTo: worktreeURL).standardizedFileURL
  }

  nonisolated private func isWorktreeIndexLocked(_ worktreeURL: URL) async -> Bool {
    let headURL = await MainActor.run {
      GitWorktreeHeadResolver.headURL(
        for: worktreeURL,
        fileManager: .default
      )
    }
    guard let headURL else {
      return false
    }
    let gitDirectory = headURL.deletingLastPathComponent()
    let lockURL = gitDirectory.appending(path: "index.lock")
    return FileManager.default.fileExists(atPath: lockURL.path(percentEncoded: false))
  }

  nonisolated func diffNameStatus(at worktreeURL: URL) async -> String {
    let path = worktreeURL.path(percentEncoded: false)
    do {
      return try await runGit(
        operation: .diffNameStatus,
        arguments: ["-C", path, "-c", "core.quotePath=false", "diff", "HEAD", "--name-status"]
      )
    } catch {
      return ""
    }
  }

  /// Resolves the base an outgoing comparison should diff against. The ladder
  /// advances only when a source is absent; a source that is present but fails
  /// to resolve throws its own `OutgoingBaseResolutionError` instead of
  /// cascading, so explicit intent (a pull request, a configured base) is
  /// never silently replaced by a guess.
  nonisolated func outgoingBaseResolution(
    pullRequest: GitPullRequestBase?,
    configuredBaseRef: String?,
    in worktreeURL: URL
  ) async throws -> OutgoingBaseResolution {
    if let pullRequest {
      return try await pullRequestBaseResolution(pullRequest, in: worktreeURL)
    }
    let configured = configuredBaseRef?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !configured.isEmpty {
      guard let qualified = await qualifiedBaseRef(named: configured, repoRoot: worktreeURL) else {
        throw OutgoingBaseResolutionError.unresolvedRepositorySettingBase(configured)
      }
      return OutgoingBaseResolution(
        ref: qualified.ref,
        displayName: qualified.displayName,
        source: .repositorySetting
      )
    }
    if let automatic = await automaticWorktreeBaseRef(for: worktreeURL),
      let qualified = await qualifiedBaseRef(named: automatic, repoRoot: worktreeURL)
    {
      return OutgoingBaseResolution(
        ref: qualified.ref,
        displayName: qualified.displayName,
        source: .automatic
      )
    }
    throw OutgoingBaseResolutionError.noResolvableBase
  }

  nonisolated private func pullRequestBaseResolution(
    _ pullRequest: GitPullRequestBase,
    in worktreeURL: URL
  ) async throws -> OutgoingBaseResolution {
    let branch = pullRequest.baseRefName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !branch.isEmpty else {
      throw OutgoingBaseResolutionError.incompletePullRequest
    }
    guard let pullRequestRepository = Self.pullRequestRepositoryWebInfo(pullRequest.url) else {
      throw OutgoingBaseResolutionError.invalidPullRequestURL(pullRequest.url)
    }
    let matchingRemotes = await remoteWebCandidates(for: worktreeURL)
      .filter { Self.matches($0.info, pullRequestRepository) }
      .map(\.name)
    guard !matchingRemotes.isEmpty else {
      throw OutgoingBaseResolutionError.noMatchingRemote(
        host: pullRequestRepository.host,
        repositoryPath: pullRequestRepository.repositoryPath
      )
    }
    guard matchingRemotes.count == 1, let remote = matchingRemotes.first else {
      throw OutgoingBaseResolutionError.multipleMatchingRemotes(matchingRemotes.sorted())
    }
    let qualifiedRef = "refs/remotes/\(remote)/\(branch)"
    guard await refExists(qualifiedRef, repoRoot: worktreeURL) else {
      throw OutgoingBaseResolutionError.unresolvedPullRequestBase(remote: remote, branch: branch)
    }
    return OutgoingBaseResolution(
      ref: qualifiedRef,
      displayName: "\(remote)/\(branch)",
      source: .pullRequest
    )
  }

  /// Qualifies a user- or heuristic-provided base name (`origin/main`, `main`)
  /// into a full ref, preferring the remote-tracking namespace. Names that are
  /// already fully qualified are verified as-is.
  nonisolated private func qualifiedBaseRef(
    named name: String,
    repoRoot: URL
  ) async -> (ref: String, displayName: String)? {
    if name.hasPrefix("refs/") {
      guard await refExists(name, repoRoot: repoRoot) else { return nil }
      let displayName =
        name
        .replacing(/^refs\/(remotes|heads)\//, with: "", maxReplacements: 1)
      return (name, displayName)
    }
    let remoteRef = "refs/remotes/\(name)"
    if await refExists(remoteRef, repoRoot: repoRoot) {
      return (remoteRef, name)
    }
    let headRef = "refs/heads/\(name)"
    if await refExists(headRef, repoRoot: repoRoot) {
      return (headRef, name)
    }
    return nil
  }

  /// Captures the immutable Git revisions used by a three-dot pull request
  /// comparison. The merge base is the left side; the current HEAD is the
  /// right side. Capturing both keeps the file list and all file documents
  /// internally consistent even if refs move while the window is loading.
  nonisolated func outgoingChangesComparison(
    base: OutgoingBaseResolution,
    at worktreeURL: URL
  ) async throws -> GitOutgoingChangesComparison {
    let path = worktreeURL.path(percentEncoded: false)
    let head = try await runGit(
      operation: .outgoingChangesComparison,
      arguments: ["-C", path, "rev-parse", "--verify", "HEAD"]
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !head.isEmpty else {
      throw GitClientError.commandFailed(command: "git rev-parse --verify HEAD", message: "Empty output")
    }
    let mergeBase = try await runGit(
      operation: .outgoingChangesComparison,
      arguments: ["-C", path, "merge-base", base.ref, head]
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !mergeBase.isEmpty else {
      throw GitClientError.commandFailed(command: "git merge-base \(base.ref) \(head)", message: "Empty output")
    }
    return GitOutgoingChangesComparison(base: base, mergeBase: mergeBase, head: head)
  }

  /// Lists committed files in a captured pull-request comparison. Unlike
  /// `diffNameStatus(at:)`, errors deliberately propagate so callers never
  /// mistake a missing base for an empty outgoing diff.
  nonisolated func outgoingDiffNameStatus(
    for comparison: GitOutgoingChangesComparison,
    at worktreeURL: URL
  ) async throws -> String {
    let path = worktreeURL.path(percentEncoded: false)
    return try await runGit(
      operation: .outgoingDiffNameStatus,
      arguments: [
        "-C",
        path,
        "-c",
        "core.quotePath=false",
        "diff",
        "--name-status",
        comparison.mergeBase,
        comparison.head,
      ]
    )
  }

  nonisolated func untrackedFilePaths(at worktreeURL: URL) async -> [String] {
    let path = worktreeURL.path(percentEncoded: false)
    do {
      let output = try await runGit(
        operation: .untrackedFilePaths,
        arguments: ["-C", path, "-c", "core.quotePath=false", "ls-files", "--others", "--exclude-standard"]
      )
      return
        output
        .split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    } catch {
      return []
    }
  }

  nonisolated func showFileAtHEAD(_ relativePath: String, in worktreeURL: URL) async -> String? {
    await showFile(relativePath, at: "HEAD", in: worktreeURL)
  }

  nonisolated func showFile(_ relativePath: String, at revision: String, in worktreeURL: URL) async -> String? {
    let path = worktreeURL.path(percentEncoded: false)
    do {
      return try await runGit(
        operation: .showFile,
        arguments: ["-C", path, "show", "\(revision):\(relativePath)"]
      )
    } catch {
      return nil
    }
  }

  nonisolated func repositoryWebURL(for repositoryRoot: URL) async -> URL? {
    await remoteWebInfo(for: repositoryRoot)?.repositoryURL
  }

  nonisolated func githubRemoteInfos(for repositoryRoot: URL) async -> [GithubRemoteInfo] {
    let candidates = await remoteWebCandidates(for: repositoryRoot).compactMap {
      candidate -> (
        name: String,
        info: GithubRemoteInfo
      )? in
      guard let info = Self.parseGithubRemoteInfo(candidate.info) else {
        return nil
      }
      return (name: candidate.name, info: info)
    }
    return Self.prioritizedGithubRemoteInfos(candidates)
  }

  nonisolated func remoteInfo(for repositoryRoot: URL) async -> GithubRemoteInfo? {
    guard let remoteWebInfo = await remoteWebInfo(for: repositoryRoot) else {
      return nil
    }
    return Self.parseGithubRemoteInfo(remoteWebInfo)
  }

  nonisolated private func remoteWebInfo(for repositoryRoot: URL) async -> GitRemoteWebInfo? {
    let candidates = await remoteWebCandidates(for: repositoryRoot)
    return Self.originFirstRemoteWebCandidates(candidates).first?.info
  }

  nonisolated private func remoteWebCandidates(
    for repositoryRoot: URL
  ) async -> [(name: String, info: GitRemoteWebInfo)] {
    let path = repositoryRoot.path(percentEncoded: false)
    guard
      let remotesOutput = try? await runGit(
        operation: .remoteInfo,
        arguments: ["-C", path, "remote"]
      )
    else {
      return []
    }
    let remotes =
      remotesOutput
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    var candidates: [(name: String, info: GitRemoteWebInfo)] = []
    for remote in remotes {
      guard
        let remoteURL = try? await runGit(
          operation: .remoteInfo,
          arguments: ["-C", path, "remote", "get-url", remote]
        )
      else {
        continue
      }
      if let info = Self.parseRepositoryWebInfo(remoteURL) {
        candidates.append((name: remote, info: info))
      }
    }
    return candidates
  }

  nonisolated private static func originFirstRemoteWebCandidates(
    _ candidates: [(name: String, info: GitRemoteWebInfo)]
  ) -> [(name: String, info: GitRemoteWebInfo)] {
    guard candidates.contains(where: { $0.name == "origin" }) else {
      return candidates
    }
    return candidates.filter { $0.name == "origin" } + candidates.filter { $0.name != "origin" }
  }

  nonisolated private static func pullRequestRepositoryWebInfo(_ pullRequestURL: String) -> GitRemoteWebInfo? {
    guard let pullRequestInfo = parseRepositoryWebInfo(pullRequestURL) else {
      return nil
    }
    let components = pullRequestInfo.repositoryPath.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count >= 4,
      components[2].caseInsensitiveCompare("pull") == .orderedSame
    else {
      return nil
    }
    return GitRemoteWebInfo(
      host: pullRequestInfo.host,
      repositoryPath: "\(components[0])/\(components[1])",
      port: pullRequestInfo.port
    )
  }

  nonisolated private static func matches(_ lhs: GitRemoteWebInfo, _ rhs: GitRemoteWebInfo) -> Bool {
    // Pull request URLs use the web transport while remotes commonly use SSH;
    // their ports do not identify different repositories.
    lhs.host.caseInsensitiveCompare(rhs.host) == .orderedSame
      && lhs.repositoryPath.caseInsensitiveCompare(rhs.repositoryPath) == .orderedSame
  }

  nonisolated static func prioritizedGithubRemoteInfos(
    _ candidates: [(name: String, info: GithubRemoteInfo)]
  ) -> [GithubRemoteInfo] {
    var seen = Set<String>()
    return
      candidates
      .enumerated()
      .sorted { lhs, rhs in
        let lhsPriority = githubPullRequestRemotePriority(lhs.element.name)
        let rhsPriority = githubPullRequestRemotePriority(rhs.element.name)
        if lhsPriority != rhsPriority {
          return lhsPriority < rhsPriority
        }
        let nameComparison = lhs.element.name.localizedStandardCompare(rhs.element.name)
        if nameComparison != .orderedSame {
          return nameComparison == .orderedAscending
        }
        return lhs.offset < rhs.offset
      }
      .compactMap { entry in
        let info = entry.element.info
        let key = [
          info.host.lowercased(),
          info.owner.lowercased(),
          info.repo.lowercased(),
        ].joined(separator: "/")
        guard seen.insert(key).inserted else {
          return nil
        }
        return info
      }
  }

  nonisolated private static func githubPullRequestRemotePriority(_ name: String) -> Int {
    switch name.lowercased() {
    case "origin":
      0
    case "upstream":
      1
    default:
      2
    }
  }

  nonisolated func remoteNames(for repoRoot: URL) async throws -> [String] {
    let path = repoRoot.path(percentEncoded: false)
    let output = try await runGit(
      operation: .remoteList,
      arguments: ["-C", path, "remote"]
    )
    return
      output
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  nonisolated func fetchRemote(_ remote: String, for repoRoot: URL) async throws {
    let path = repoRoot.path(percentEncoded: false)
    _ = try await runGit(
      operation: .fetchRemote,
      arguments: ["-C", path, "fetch", remote]
    )
  }

  nonisolated func removeWorktree(_ worktree: Worktree, deleteBranch: Bool) async throws -> URL {
    let rootPath = worktree.repositoryRootURL.path(percentEncoded: false)
    let worktreeURL = worktree.workingDirectory.standardizedFileURL
    let worktreePath = Self.canonicalWorktreePath(worktreeURL.path(percentEncoded: false))
    let initialWorktreePaths = try await registeredWorktreePaths(rootPath: rootPath)
    guard initialWorktreePaths.contains(worktreePath) else {
      throw GitClientError.worktreeNotRegistered(
        path: worktree.workingDirectory.path(percentEncoded: false)
      )
    }
    let relocatedURL =
      Self.worktreeDirectoryHasGitMetadata(worktreeURL)
      ? Self.relocateWorktreeDirectory(worktreeURL)
      : nil
    if let relocatedURL {
      do {
        _ = try? await runGit(
          operation: .worktreePrune,
          arguments: ["-C", rootPath, "worktree", "prune", "--expire=now"]
        )
        let remainingWorktreePaths = try await registeredWorktreePaths(rootPath: rootPath)
        if remainingWorktreePaths.contains(worktreePath) {
          try await runGitWorktreeRemove(rootPath: rootPath, worktreePath: worktreePath)
        }
      } catch {
        let removalError = error
        do {
          try FileManager.default.moveItem(at: relocatedURL, to: worktreeURL)
        } catch {
          throw GitClientError.worktreeRecoveryFailed(
            path: worktreeURL.path(percentEncoded: false),
            removalError: removalError.localizedDescription,
            recoveryError: error.localizedDescription
          )
        }
        throw removalError
      }
      if deleteBranch {
        _ = try? await deleteLocalBranch(
          named: worktree.name,
          for: worktree.repositoryRootURL,
          force: false
        )
      }
      Task.detached {
        try? FileManager.default.removeItem(at: relocatedURL)
      }
      return worktree.workingDirectory
    }
    try await runGitWorktreeRemove(rootPath: rootPath, worktreePath: worktreePath)
    if deleteBranch {
      _ = try? await deleteLocalBranch(
        named: worktree.name,
        for: worktree.repositoryRootURL,
        force: false
      )
    }
    return worktree.workingDirectory
  }

  nonisolated private func registeredWorktreePaths(rootPath: String) async throws -> Set<String> {
    let output = try await runGit(
      operation: .worktreeList,
      arguments: ["-C", rootPath, "worktree", "list", "--porcelain"]
    )
    // `git worktree list --porcelain` reports the raw on-disk path (e.g. `/private/tmp/foo`),
    // while `worktrees(for:)` stores `standardizedFileURL` paths (which resolve `/private`
    // symlinks to `/tmp`). Canonicalize both sides identically so the removal guard matches
    // externally-created worktrees living under symlinked roots like /tmp or /var.
    return Set(Self.parseGitWorktreePorcelainPaths(output).map(Self.canonicalWorktreePath))
  }

  nonisolated func deleteLocalBranch(
    named branchName: String,
    for repoRoot: URL,
    force: Bool
  ) async throws -> LocalBranchDeletionOutcome {
    guard !branchName.isEmpty else { return .notRequested }
    let rootPath = repoRoot.path(percentEncoded: false)
    let normalizedName = branchName.lowercased()
    let names = try await localBranchNames(for: repoRoot)
    guard names.contains(normalizedName) else { return .notFound }
    let protectedNames = await protectedLocalBranchNames(for: repoRoot)
    guard !protectedNames.contains(normalizedName) else { return .protected }
    _ = try await runGit(
      operation: .branchDelete,
      arguments: ["-C", rootPath, "branch", force ? "-D" : "-d", branchName]
    )
    return .deleted
  }

  nonisolated private func protectedLocalBranchNames(for repoRoot: URL) async -> Set<String> {
    var names: Set<String> = ["main", "master"]
    if let defaultRef = try? await defaultRemoteBranchRef(for: repoRoot),
      let defaultBranchName = Self.localBranchName(fromRef: defaultRef)
    {
      names.insert(defaultBranchName.lowercased())
    }
    return names
  }

  nonisolated private static func localBranchName(fromRef ref: String) -> String? {
    let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let slashIndex = trimmed.firstIndex(of: "/") else {
      return trimmed
    }
    let name = trimmed[trimmed.index(after: slashIndex)...]
    return name.isEmpty ? nil : String(name)
  }

  nonisolated private func parseShortstat(_ output: String) -> (added: Int, removed: Int) {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return (0, 0)
    }
    var added = 0
    var removed = 0
    if let match = trimmed.firstMatch(of: /(\d+)\s+insertions?\(\+\)/) {
      added = Int(match.1) ?? 0
    }
    if let match = trimmed.firstMatch(of: /(\d+)\s+deletions?\(-\)/) {
      removed = Int(match.1) ?? 0
    }
    return (added, removed)
  }

  nonisolated private func parseFileList(_ output: String) -> [String] {
    output
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  nonisolated private func parseNULFileList(_ output: String) -> [String] {
    output
      .split(separator: "\0", omittingEmptySubsequences: true)
      .map(String.init)
  }

  nonisolated private func parseFileListCount(_ output: String) -> Int {
    parseFileList(output).count
  }

  nonisolated private func lastNonEmptyLine(in output: String) -> String? {
    output
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .last { !$0.isEmpty }
  }

  nonisolated private func parseRefLines(_ output: String, prefix: String) -> [String] {
    output
      .split(whereSeparator: \.isNewline)
      .compactMap { line -> String? in
        let ref = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else {
          return nil
        }
        return ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ref
      }
  }

  nonisolated private func parseRemoteBranchRefs(_ output: String) -> (refs: [String], defaultBranch: String?) {
    var refs: [String] = []
    var defaultBranch: String?
    for rawLine in output.split(whereSeparator: \.isNewline) {
      let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
      if line.hasPrefix("ref:") {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[1] == "HEAD" else {
          continue
        }
        let target = parts[0]
          .dropFirst("ref:".count)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if let branch = normalizeHeadRef(target) {
          defaultBranch = branch
        }
        continue
      }
      let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard parts.count >= 2,
        let branch = normalizeHeadRef(String(parts[1]))
      else {
        continue
      }
      refs.append(branch)
    }
    return (deduplicated(refs), defaultBranch)
  }

  nonisolated private func normalizeHeadRef(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "refs/heads/"
    guard trimmed.hasPrefix(prefix) else {
      return nil
    }
    let branch = String(trimmed.dropFirst(prefix.count))
    return branch.isEmpty ? nil : branch
  }

  nonisolated private func deduplicated(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
  }

  nonisolated private func deduplicatedOptions(_ options: [GitBranchRefOption]) -> [GitBranchRefOption] {
    var seen = Set<String>()
    return options.filter { seen.insert($0.id).inserted }
  }

  nonisolated private func normalizeRemoteRef(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    let prefix = "refs/remotes/"
    if trimmed.hasPrefix(prefix) {
      return String(trimmed.dropFirst(prefix.count))
    }
    return trimmed
  }

  nonisolated private func localHeadBranchRef(for repoRoot: URL) async throws -> String? {
    let path = repoRoot.path(percentEncoded: false)
    let output = try await runGit(
      operation: .localHeadRef,
      arguments: ["-C", path, "symbolic-ref", "--short", "HEAD"]
    )
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  nonisolated private func resolveLocalHead(_ localHead: String?, repoRoot: URL) async -> String? {
    guard let localHead else { return nil }
    if await refExists(localHead, repoRoot: repoRoot) {
      return localHead
    }
    return nil
  }

  nonisolated static func preferredBaseRef(remote: String?, localHead: String?) -> String? {
    remote ?? localHead
  }

  nonisolated private func refExists(_ ref: String, repoRoot: URL) async -> Bool {
    let path = repoRoot.path(percentEncoded: false)
    do {
      _ = try await runGit(
        operation: .defaultRemoteBranchRef,
        arguments: ["-C", path, "rev-parse", "--verify", "--quiet", ref]
      )
      return true
    } catch {
      return false
    }
  }

  nonisolated private func runGit(
    operation: GitOperation,
    arguments: [String]
  ) async throws -> String {
    let env = URL(fileURLWithPath: "/usr/bin/env")
    let command = ([env.path(percentEncoded: false)] + ["git"] + arguments).joined(separator: " ")
    do {
      return try await shell.run(env, ["git"] + arguments, nil).stdout
    } catch {
      throw wrapShellError(error, operation: operation, command: command)
    }
  }

  nonisolated private func runWtList(repoRoot: URL) async throws -> String {
    let wtURL = try wtScriptURL()
    let arguments = ["ls", "--json"]
    return try await runBundledWtProcess(
      operation: .worktreeList,
      executableURL: wtURL,
      arguments: arguments,
      currentDirectoryURL: repoRoot
    )
  }

  nonisolated private func wtScriptURL() throws -> URL {
    guard let url = Bundle.main.url(forResource: "wt", withExtension: nil, subdirectory: "git-wt") else {
      fatalError("Bundled wt script not found")
    }
    return url
  }

  nonisolated private func runBundledWtProcess(
    operation: GitOperation,
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL?
  ) async throws -> String {
    let command = ([executableURL.path(percentEncoded: false)] + arguments).joined(separator: " ")
    do {
      return try await shell.run(executableURL, arguments, currentDirectoryURL).stdout
    } catch {
      guard shouldFallbackToLoginShell(error) else {
        throw wrapShellError(error, operation: operation, command: command)
      }
      gitLogger.info("Falling back to login shell for \(operation.rawValue)")
      do {
        return try await shell.runLogin(executableURL, arguments, currentDirectoryURL).stdout
      } catch {
        throw wrapShellError(error, operation: operation, command: command)
      }
    }
  }

  nonisolated private func runLoginShellProcess(
    operation: GitOperation,
    executableURL: URL,
    arguments: [String],
    currentDirectoryURL: URL?
  ) async throws -> String {
    let command = ([executableURL.path(percentEncoded: false)] + arguments).joined(separator: " ")
    do {
      return try await shell.runLogin(executableURL, arguments, currentDirectoryURL).stdout
    } catch {
      throw wrapShellError(error, operation: operation, command: command)
    }
  }

  nonisolated private static func relativePath(from base: URL, to target: URL) -> String {
    let baseComponents = base.standardizedFileURL.pathComponents
    let targetComponents = target.standardizedFileURL.pathComponents
    var index = 0
    while index < min(baseComponents.count, targetComponents.count),
      baseComponents[index] == targetComponents[index]
    {
      index += 1
    }
    var result: [String] = []
    if index < baseComponents.count {
      result.append(contentsOf: Array(repeating: "..", count: baseComponents.count - index))
    }
    if index < targetComponents.count {
      result.append(contentsOf: targetComponents[index...])
    }
    if result.isEmpty {
      return "."
    }
    return result.joined(separator: "/")
  }

  nonisolated private static func directoryURL(for path: URL) -> URL {
    if path.hasDirectoryPath {
      return path
    }
    return path.deletingLastPathComponent()
  }

  nonisolated private func runGitWorktreeRemove(
    rootPath: String,
    worktreePath: String
  ) async throws {
    _ = try await runGit(
      operation: .worktreeRemove,
      arguments: [
        "-C",
        rootPath,
        "worktree",
        "remove",
        "--force",
        worktreePath,
      ]
    )
  }

  nonisolated private static func relocateWorktreeDirectory(_ worktreeURL: URL) -> URL? {
    let fileManager = FileManager.default
    let worktreePath = worktreeURL.path(percentEncoded: false)
    guard fileManager.fileExists(atPath: worktreePath) else {
      return nil
    }
    let candidates = [
      URL(filePath: "/tmp", directoryHint: .isDirectory),
      fileManager.temporaryDirectory,
    ]
    for baseURL in candidates {
      let trashBaseURL = baseURL.appending(
        path: "supacode-worktree-trash",
        directoryHint: URL.DirectoryHint.isDirectory
      )
      do {
        try fileManager.createDirectory(at: trashBaseURL, withIntermediateDirectories: true)
      } catch {
        continue
      }
      let destinationURL = trashBaseURL.appending(
        path: "\(worktreeURL.lastPathComponent)-\(UUID().uuidString)",
        directoryHint: URL.DirectoryHint.isDirectory
      )
      do {
        try fileManager.moveItem(at: worktreeURL, to: destinationURL)
        return destinationURL
      } catch {
        continue
      }
    }
    return nil
  }

  nonisolated private static func worktreeDirectoryHasGitMetadata(_ worktreeURL: URL) -> Bool {
    let gitMetadataURL = worktreeURL.appending(path: ".git")
    return FileManager.default.fileExists(atPath: gitMetadataURL.path(percentEncoded: false))
  }

  /// Resolves filesystem symlinks and normalizes a worktree path so Git's raw on-disk paths
  /// compare equal to the URLs Prowl tracks internally.
  nonisolated static func canonicalWorktreePath(_ path: String) -> String {
    URL(fileURLWithPath: path)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .path(percentEncoded: false)
  }

  nonisolated static func parseGitWorktreePorcelainPaths(_ output: String) -> Set<String> {
    Set(
      output
        .split(whereSeparator: \.isNewline)
        .compactMap { line -> String? in
          let prefix = "worktree "
          guard line.hasPrefix(prefix) else {
            return nil
          }
          return String(line.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        .filter { !$0.isEmpty }
    )
  }

  nonisolated static func parseRepositoryWebInfo(_ remoteURL: String) -> GitRemoteWebInfo? {
    let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    if trimmed.hasPrefix("git@") {
      let parts = trimmed.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: true)
      guard parts.count == 2 else {
        return nil
      }
      let hostAndPath = parts[1]
      let hostParts = hostAndPath.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
      guard hostParts.count == 2 else {
        return nil
      }
      return parseRepositoryWebInfo(host: String(hostParts[0]), port: nil, path: String(hostParts[1]))
    }
    guard let url = URL(string: trimmed), let host = url.host else {
      return nil
    }
    let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return parseRepositoryWebInfo(host: host, port: url.port, path: path)
  }

  nonisolated static func parseGithubRemoteInfo(_ remoteURL: String) -> GithubRemoteInfo? {
    guard let remoteWebInfo = parseRepositoryWebInfo(remoteURL) else {
      return nil
    }
    return parseGithubRemoteInfo(remoteWebInfo)
  }

  nonisolated private static func parseRepositoryWebInfo(
    host: String,
    port: Int?,
    path: String
  ) -> GitRemoteWebInfo? {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count >= 2 else {
      return nil
    }
    var repositoryPath = components.map(String.init).joined(separator: "/")
    if repositoryPath.hasSuffix(".git") {
      repositoryPath = String(repositoryPath.dropLast(4))
    }
    guard !repositoryPath.isEmpty else {
      return nil
    }
    return GitRemoteWebInfo(host: host, repositoryPath: repositoryPath, port: port)
  }

  nonisolated private static func parseGithubRemoteInfo(_ remoteWebInfo: GitRemoteWebInfo) -> GithubRemoteInfo? {
    let normalizedHost = remoteWebInfo.host.lowercased()
    guard normalizedHost.contains("github") else {
      return nil
    }
    let components = remoteWebInfo.repositoryPath.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count >= 2 else {
      return nil
    }
    let owner = String(components[0])
    let repo = String(components[1])
    guard !owner.isEmpty, !repo.isEmpty else {
      return nil
    }
    return GithubRemoteInfo(host: remoteWebInfo.host, owner: owner, repo: repo)
  }

}

/// Byte scans over `Data`'s contiguous storage.
///
/// `Data` conforms to `Sequence`, so `reduce` and `contains` walk it through
/// `Data.Iterator` with a value-witness call per byte. Sampling a running instance
/// for 300 s attributed roughly one whole core to exactly that path inside
/// `countLines` — 31% in `Sequence.reduce`, 30% in `Data.Iterator.next`, 22% in
/// value witnesses — about 72% of everything the process was burning, while
/// counting lines in untracked files. `memchr` scans sparse matches in vectorized
/// segments; a raw-pointer fallback bounds the cost when matches are dense.
extension Data {
  /// Occurrences of `byte` in the whole buffer.
  fileprivate nonisolated func countOccurrences(of byte: UInt8) -> Int {
    withUnsafeBytes { raw -> Int in
      guard let base = raw.baseAddress, !raw.isEmpty else { return 0 }
      var count = 0
      var scanned = 0
      let denseMatchLimit = 2_048
      while scanned < raw.count,
        let hit = memchr(base + scanned, Int32(byte), raw.count - scanned)
      {
        // memchr returns the hit itself, so resume one byte past it.
        scanned = base.distance(to: UnsafeRawPointer(hit)) + 1
        count += 1
        if count == denseMatchLimit {
          let remaining = raw.count - scanned
          let bytes = (base + scanned).assumingMemoryBound(to: UInt8.self)
          for index in 0..<remaining {
            count += bytes[index] == byte ? 1 : 0
          }
          break
        }
      }
      return count
    }
  }

  /// Whether `byte` occurs anywhere in the buffer. Stops at the first hit.
  fileprivate nonisolated func containsByte(_ byte: UInt8) -> Bool {
    withUnsafeBytes { raw -> Bool in
      guard let base = raw.baseAddress, !raw.isEmpty else { return false }
      return memchr(base, Int32(byte), raw.count) != nil
    }
  }
}
