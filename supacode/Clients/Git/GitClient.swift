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

  nonisolated func worktrees(for repositoryURL: URL) async throws -> [Worktree] {
    let requestedPath = repositoryURL.standardizedFileURL.path(percentEncoded: false)
    let repositoryRootURL = URL(fileURLWithPath: requestedPath, isDirectory: true).standardizedFileURL
    let resolvedRepositoryRootURL = try await repoRoot(for: repositoryRootURL)
    guard resolvedRepositoryRootURL == repositoryRootURL else {
      throw GitClientError.commandFailed(
        command: "wt root",
        message:
          "Expected repository root at \(requestedPath), but git resolved "
          + "\(resolvedRepositoryRootURL.path(percentEncoded: false))."
      )
    }
    let output = try await runWtList(repoRoot: repositoryRootURL)
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
    let path = repoRoot.path(percentEncoded: false)
    let localOutput = try await runGit(
      operation: .branchRefs,
      arguments: [
        "-C",
        path,
        "for-each-ref",
        "--format=%(refname:short)\t%(upstream:short)",
        "refs/heads",
      ]
    )
    let refs = parseLocalRefsWithUpstream(localOutput)
      .filter { !$0.hasSuffix("/HEAD") }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    return deduplicated(refs)
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

  nonisolated func lineChanges(at worktreeURL: URL) async -> (added: Int, removed: Int)? {
    if await isWorktreeIndexLocked(worktreeURL) {
      return nil
    }
    let path = worktreeURL.path(percentEncoded: false)
    do {
      let diff = try await runGit(
        operation: .lineChanges,
        arguments: ["-C", path, "diff", "HEAD", "--shortstat"]
      )
      let changes = parseShortstat(diff)
      return (added: changes.added, removed: changes.removed)
    } catch {
      return nil
    }
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
    let path = worktreeURL.path(percentEncoded: false)
    do {
      return try await runGit(
        operation: .showFile,
        arguments: ["-C", path, "show", "HEAD:\(relativePath)"]
      )
    } catch {
      return nil
    }
  }

  nonisolated func repositoryWebURL(for repositoryRoot: URL) async -> URL? {
    await remoteWebInfo(for: repositoryRoot)?.repositoryURL
  }

  nonisolated func remoteInfo(for repositoryRoot: URL) async -> GithubRemoteInfo? {
    guard let remoteWebInfo = await remoteWebInfo(for: repositoryRoot) else {
      return nil
    }
    return Self.parseGithubRemoteInfo(remoteWebInfo)
  }

  nonisolated private func remoteWebInfo(for repositoryRoot: URL) async -> GitRemoteWebInfo? {
    let path = repositoryRoot.path(percentEncoded: false)
    guard
      let remotesOutput = try? await runGit(
        operation: .remoteInfo,
        arguments: ["-C", path, "remote"]
      )
    else {
      return nil
    }
    let remotes =
      remotesOutput
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    let orderedRemotes: [String]
    if remotes.contains("origin") {
      orderedRemotes = ["origin"] + remotes.filter { $0 != "origin" }
    } else {
      orderedRemotes = remotes
    }
    for remote in orderedRemotes {
      guard
        let remoteURL = try? await runGit(
          operation: .remoteInfo,
          arguments: ["-C", path, "remote", "get-url", remote]
        )
      else {
        continue
      }
      if let info = Self.parseRepositoryWebInfo(remoteURL) {
        return info
      }
    }
    return nil
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
    let registeredWorktreePaths = try await registeredWorktreePaths(rootPath: rootPath)
    guard registeredWorktreePaths.contains(worktreePath) else {
      return worktree.workingDirectory
    }
    let relocatedURL =
      Self.worktreeDirectoryHasGitMetadata(worktreeURL)
      ? Self.relocateWorktreeDirectory(worktreeURL)
      : nil
    if let relocatedURL {
      do {
        _ = try await runGit(
          operation: .worktreePrune,
          arguments: ["-C", rootPath, "worktree", "prune", "--expire=now"]
        )
      } catch {
        await runGitWorktreeRemove(rootPath: rootPath, worktreePath: worktreePath)
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
    await runGitWorktreeRemove(rootPath: rootPath, worktreePath: worktreePath)
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

  nonisolated private func parseFileListCount(_ output: String) -> Int {
    output
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .count
  }

  nonisolated private func lastNonEmptyLine(in output: String) -> String? {
    output
      .split(whereSeparator: \.isNewline)
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .last { !$0.isEmpty }
  }

  nonisolated private func parseLocalRefsWithUpstream(_ output: String) -> [String] {
    output
      .split(whereSeparator: \.isNewline)
      .flatMap { line -> [String] in
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard let local = parts.first else {
          return []
        }
        let localRef = String(local).trimmingCharacters(in: .whitespacesAndNewlines)
        let upstreamRef =
          parts.count > 1
          ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
          : ""

        var refs: [String] = []
        if !localRef.isEmpty {
          refs.append(localRef)
        }
        if !upstreamRef.isEmpty {
          refs.append(upstreamRef)
        }
        return refs
      }
  }

  nonisolated private func deduplicated(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
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
  ) async {
    _ = try? await runGit(
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

  /// Normalizes a worktree path to the same canonical form `worktrees(for:)` stores, so paths
  /// reported by git (which keep `/private` symlink prefixes) compare equal to the standardized
  /// URLs Prowl tracks internally.
  nonisolated static func canonicalWorktreePath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path(percentEncoded: false)
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
