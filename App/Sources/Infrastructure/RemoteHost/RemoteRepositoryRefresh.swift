import Foundation

nonisolated enum RemoteRepositoryRefreshError: Error, Equatable, Sendable {
  /// `ssh` could not reach the host, or the command exited with an error.
  case connection(RemoteProbeFailure)
  case timedOut
  /// The repository folder does not exist on the host.
  case missingFolder
  /// The folder exists, but the host user cannot enter it, or it is not a folder.
  case inaccessibleFolder
  /// The folder is not in a git repository.
  case notGitRepository
  /// The folder is in a repository, but it is not the root of the main worktree (or of a
  /// bare repository).
  case notRepositoryRoot
  /// `git` is not on the host's login `PATH`.
  case gitMissing
  /// Git refused the repository, for example because of `safe.directory`; the last line
  /// of its error output.
  case gitFailed(String)
  /// The reply has no header or no end line: the output was cut off or is not this format.
  case incompleteOutput
}

nonisolated enum RemoteWorktreeState: String, Equatable, Sendable {
  case present = "ok"
  /// Git still lists the worktree, but its folder is gone.
  case missing
  case bare
}

/// The batched refresh of one remote repository (docs-ai 084 D4): one command per poll
/// reads every worktree's HEAD, branch, creation time, tracked line counts and untracked
/// file count, the repository's bare flag, and a fingerprint of its remote URLs.
///
/// The reply is one tab-separated record per line, so the parser needs no quoting:
///
/// ```
/// PROWL_REFRESH  1
/// ROOT           <physical root path>
/// BARE           true|false
/// REMOTES        <cksum of the remote URL config>
/// WORKTREE       ok|missing|bare  <HEAD>  <branch>  <birth>  <added>  <removed>  <untracked>  <path>
/// END
/// ```
///
/// A path is always the last field, so a path that contains a tab still parses; git does
/// not allow tabs in branch names. The remote URLs themselves are not in the reply, so a
/// token in a URL does not travel on every poll; the host reads them when the
/// fingerprint changes.
nonisolated struct RemoteRepositoryRefresh: Equatable, Sendable {
  nonisolated struct WorktreeRecord: Equatable, Sendable {
    let path: String
    let state: RemoteWorktreeState
    let head: String?
    /// Nil for a detached HEAD.
    let branch: String?
    let createdAt: Date?
    /// Tracked line counts, or nil when git cannot diff the worktree (no commit yet).
    /// Untracked files are counted, not their lines.
    let lineChanges: GitLineChanges?
  }

  /// The repository root as the host resolves it (`pwd -P`). Git lists the main worktree
  /// by this path, which differs from the stored path when the stored path has a link.
  let physicalRootPath: String
  let isBare: Bool
  let remotesFingerprint: String
  let worktrees: [WorktreeRecord]

  static let formatVersion = "1"

  /// The refresh of the repository at `path` on its host.
  static func script(repositoryPath path: String) -> RemoteScript {
    RemoteScript(text: scriptText, arguments: [path])
  }

  /// The result of running `script(repositoryPath:)` on the command lane.
  static func parse(_ outcome: RemoteCommandOutcome) throws(RemoteRepositoryRefreshError) -> Self {
    switch outcome {
    case .timedOut:
      throw .timedOut
    case .launchFailed(let reason):
      throw .connection(.launch(reason))
    case .exited(let result):
      guard result.exitCode == 0 else { throw .connection(RemoteConnectionOwner.failure(result)) }
      guard !result.outputTruncated else { throw .incompleteOutput }
      return try parse(result.output)
    }
  }

  /// Decodes each line on its own: a line that is not UTF-8 (a path in another encoding)
  /// is read as Latin-1, and the other lines keep their UTF-8 paths.
  static func parse(_ output: Data) throws(RemoteRepositoryRefreshError) -> Self {
    let lines = output.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { line in
      String(bytes: line, encoding: .utf8) ?? String(bytes: line, encoding: .isoLatin1) ?? ""
    }
    return try parse(lines: lines)
  }

  static func parse(_ output: String) throws(RemoteRepositoryRefreshError) -> Self {
    try parse(lines: output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
  }

  private static func parse(lines: [String]) throws(RemoteRepositoryRefreshError) -> Self {
    // A shell startup file can print before the script runs.
    guard let header = lines.firstIndex(of: "PROWL_REFRESH\t\(formatVersion)") else {
      throw .incompleteOutput
    }
    var root: String?
    var isBare = false
    var remotes = ""
    var worktrees: [WorktreeRecord] = []
    for line in lines[lines.index(after: header)...] {
      let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
      let value = parts.count > 1 ? String(parts[1]) : ""
      switch parts.first {
      case "END":
        guard let root else { throw .incompleteOutput }
        // Git lists the main worktree (or the bare repository) first.
        if let first = worktrees.first, first.path != root { throw .notRepositoryRoot }
        return Self(physicalRootPath: root, isBare: isBare, remotesFingerprint: remotes, worktrees: worktrees)
      case "ERROR":
        throw error(value)
      case "ROOT":
        root = value
      case "BARE":
        isBare = value == "true"
      case "REMOTES":
        remotes = value
      case "WORKTREE":
        if let record = worktreeRecord(value) { worktrees.append(record) }
      default:
        // Records that a later format adds.
        continue
      }
    }
    throw .incompleteOutput
  }

  private static func error(_ value: String) -> RemoteRepositoryRefreshError {
    let parts = value.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
    switch parts.first {
    case "missing": return .missingFolder
    case "inaccessible": return .inaccessibleFolder
    case "not-git": return .notGitRepository
    case "no-git": return .gitMissing
    default: return .gitFailed(parts.count > 1 ? String(parts[1]) : "")
    }
  }

  /// `value` is the record after its type: seven fields, then the path.
  private static func worktreeRecord(_ value: String) -> WorktreeRecord? {
    let fields = value.split(separator: "\t", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
    guard fields.count == 8, let state = RemoteWorktreeState(rawValue: fields[0]), !fields[7].isEmpty else {
      return nil
    }
    let lineChanges: GitLineChanges? =
      if state == .present, let added = Int(fields[4]), let removed = Int(fields[5]) {
        GitLineChanges(added: added, removed: removed, skippedUntrackedFileCount: Int(fields[6]) ?? 0)
      } else {
        nil
      }
    return WorktreeRecord(
      path: fields[7],
      state: state,
      head: fields[1].isEmpty ? nil : fields[1],
      branch: fields[2].isEmpty ? nil : fields[2],
      createdAt: TimeInterval(fields[3]).map(Date.init(timeIntervalSince1970:)),
      lineChanges: lineChanges
    )
  }

  // MARK: - App models

  /// The worktrees of `repository`, built and sorted as the local host builds them: the
  /// branch or the folder name, the path relative to the root, the newest first. Bare
  /// entries are left out. The main worktree takes the repository's own location.
  func worktrees(in repository: RepositoryLocation) -> [Worktree] {
    resolvedRecords(in: repository).map(\.worktree)
  }

  /// The line changes of each worktree that has its folder, by worktree ID.
  func lineChanges(in repository: RepositoryLocation) -> [Worktree.ID: GitLineChanges] {
    var changes: [Worktree.ID: GitLineChanges] = [:]
    for resolved in resolvedRecords(in: repository) {
      changes[resolved.worktree.id] = resolved.record.lineChanges
    }
    return changes
  }

  private struct ResolvedRecord {
    let worktree: Worktree
    let record: WorktreeRecord
    let index: Int
  }

  private func resolvedRecords(in repository: RepositoryLocation) -> [ResolvedRecord] {
    guard case .remote(let hostProfileID, _) = repository else { return [] }
    let rootURL = URL(filePath: physicalRootPath, directoryHint: .isDirectory)
    var seen = Set<Worktree.ID>()
    let entries = worktrees.enumerated().compactMap { index, record -> ResolvedRecord? in
      guard record.state != .bare else { return nil }
      let location: RepositoryLocation =
        record.path == physicalRootPath ? repository : .remote(hostProfileID: hostProfileID, path: record.path)
      guard seen.insert(location.id).inserted else { return nil }
      let url = URL(filePath: record.path, directoryHint: .isDirectory)
      let worktree = Worktree(
        name: record.branch ?? url.lastPathComponent,
        detail: GitClient.relativePath(from: rootURL, to: url),
        location: location,
        repositoryLocation: repository,
        createdAt: record.createdAt
      )
      return ResolvedRecord(worktree: worktree, record: record, index: index)
    }
    return entries.sorted { lhs, rhs in
      let lhsDate = lhs.worktree.createdAt ?? .distantPast
      let rhsDate = rhs.worktree.createdAt ?? .distantPast
      return lhsDate != rhsDate ? lhsDate > rhsDate : lhs.index < rhs.index
    }
  }

  // MARK: - Script

  /// Runs in bash 3.2 or later (macOS `/bin/bash`) and with BSD or GNU tools. `$1` is the
  /// repository path. A folder that is missing, cannot be entered or is not in a repository
  /// is reported in the reply, so the command itself only fails for connection errors.
  ///
  /// `GIT_OPTIONAL_LOCKS=0` keeps a poll from writing the index, so it never takes
  /// `index.lock` from a git command that an agent runs on the host at the same time.
  static let scriptText = #"""
    GIT_OPTIONAL_LOCKS=0
    export GIT_OPTIONAL_LOCKS
    prowl_fail() { printf 'PROWL_REFRESH\t\#(formatVersion)\nERROR\t%s\nEND\n' "$1"; exit 0; }
    [ -e "$1" ] || prowl_fail missing
    cd -- "$1" 2>/dev/null || prowl_fail inaccessible
    command -v git >/dev/null 2>&1 || prowl_fail no-git
    if ! prowl_error=$(LC_ALL=C git rev-parse --git-dir 2>&1 >/dev/null); then
      case $prowl_error in *'not a git repository'*) prowl_fail not-git ;; esac
      printf 'PROWL_REFRESH\t\#(formatVersion)\nERROR\tgit\t%s\nEND\n' "$(printf '%s\n' "$prowl_error" | tail -n 1)"
      exit 0
    fi
    printf 'PROWL_REFRESH\t\#(formatVersion)\n'
    printf 'ROOT\t%s\n' "$(pwd -P)"
    printf 'BARE\t%s\n' "$(git rev-parse --is-bare-repository 2>/dev/null)"
    printf 'REMOTES\t%s\n' "$(git config --get-regexp '^remote\..*\.url$' 2>/dev/null | cksum | tr ' ' '-')"
    if stat -c %Y . >/dev/null 2>&1; then
      prowl_birth() {
        b=$(stat -c %W "$1" 2>/dev/null)
        case $b in '' | 0 | -) stat -c %Y "$1" 2>/dev/null ;; *) echo "$b" ;; esac
      }
    else
      prowl_birth() {
        b=$(stat -f %B "$1" 2>/dev/null)
        case $b in '' | 0) stat -f %m "$1" 2>/dev/null ;; *) echo "$b" ;; esac
      }
    fi
    prowl_emit() {
      [ -n "$wt" ] || return 0
      if [ "$bare" = 1 ]; then
        printf 'WORKTREE\tbare\t\t\t\t\t\t\t%s\n' "$wt"
      elif [ -d "$wt" ]; then
        # No counts when git cannot diff, as for a worktree without a commit.
        if numstat=$(git -C "$wt" diff --numstat HEAD -- 2>/dev/null); then
          counts=$(printf '%s\n' "$numstat" |
            awk -F '\t' '$1 != "-" { a += $1 } $2 != "-" { d += $2 } END { printf "%d\t%d", a, d }')
        else
          counts=$(printf '\t')
        fi
        untracked=$(git -C "$wt" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
        printf 'WORKTREE\tok\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$head" "$branch" "$(prowl_birth "$wt")" "$counts" "$untracked" "$wt"
      else
        printf 'WORKTREE\tmissing\t%s\t%s\t\t\t\t\t%s\n' "$head" "$branch" "$wt"
      fi
    }
    git worktree list --porcelain 2>/dev/null | {
      wt=; head=; branch=; bare=0
      while IFS= read -r line; do
        case $line in
          'worktree '*) prowl_emit; wt=${line#worktree }; head=; branch=; bare=0 ;;
          'HEAD '*) head=${line#HEAD } ;;
          'branch refs/heads/'*) branch=${line#branch refs/heads/} ;;
          bare) bare=1 ;;
        esac
      done
      prowl_emit
    }
    printf 'END\n'
    """#
}
