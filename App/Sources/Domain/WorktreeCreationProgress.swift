import Foundation

nonisolated struct WorktreeCreationProgress: Hashable, Sendable {
  var stage: WorktreeCreationStage
  var worktreeName: String?
  var baseRef: String?
  var fetchRemoteName: String?
  var copyIgnored: Bool?
  var copyUntracked: Bool?
  var ignoredFilesToCopyCount: Int?
  var untrackedFilesToCopyCount: Int?
  var commandText: String?
  var latestOutputLine: String?
  var outputLines: [String]

  init(
    stage: WorktreeCreationStage,
    worktreeName: String? = nil,
    baseRef: String? = nil,
    fetchRemoteName: String? = nil,
    copyIgnored: Bool? = nil,
    copyUntracked: Bool? = nil,
    ignoredFilesToCopyCount: Int? = nil,
    untrackedFilesToCopyCount: Int? = nil,
    commandText: String? = nil,
    latestOutputLine: String? = nil,
    outputLines: [String] = []
  ) {
    self.stage = stage
    self.worktreeName = worktreeName
    self.baseRef = baseRef
    self.fetchRemoteName = fetchRemoteName
    self.copyIgnored = copyIgnored
    self.copyUntracked = copyUntracked
    self.ignoredFilesToCopyCount = ignoredFilesToCopyCount
    self.untrackedFilesToCopyCount = untrackedFilesToCopyCount
    self.commandText = commandText
    self.latestOutputLine = latestOutputLine
    self.outputLines = outputLines
  }

  var titleText: String {
    if let worktreeName, !worktreeName.isEmpty {
      return String(localized: "Creating \(worktreeName)")
    }
    return String(localized: "Creating worktree")
  }

  var detailText: String {
    switch stage {
    case .loadingLocalBranches:
      return String(localized: "Reading local branches")
    case .choosingWorktreeName:
      return String(localized: "Choosing available worktree name")
    case .checkingRepositoryMode:
      return String(localized: "Checking repository mode")
    case .resolvingBaseReference:
      return String(localized: "Resolving base reference (\(baseRefDisplay))")
    case .fetchingRemote:
      if let fetchRemoteName, !fetchRemoteName.isEmpty {
        return String(localized: "Fetching \(fetchRemoteName)")
      }
      return String(localized: "Fetching remote")
    case .creatingWorktree:
      if let outputLine = outputLines.last, !outputLine.isEmpty {
        return outputLine
      }
      if let latestOutputLine, !latestOutputLine.isEmpty {
        return latestOutputLine
      }
      let ignoredCount = ignoredFilesToCopyCount ?? 0
      let untrackedCount = untrackedFilesToCopyCount ?? 0
      let copySummary: String
      if copyIgnored == true, copyUntracked == true {
        copySummary = String(
          localized: "Copying \(ignoredCount) ignored files and copying \(untrackedCount) untracked files"
        )
      } else if copyIgnored == true {
        copySummary = String(localized: "Copying \(ignoredCount) ignored files")
      } else if copyUntracked == true {
        copySummary = String(localized: "copying \(untrackedCount) untracked files")
      } else {
        copySummary = ""
      }
      return if copySummary.isEmpty {
        String(localized: "Creating from \(baseRefBranchDisplay).")
      } else {
        String(localized: "Creating from \(baseRefBranchDisplay). \(copySummary)")
      }
    }
  }

  var liveOutputLines: [String] {
    guard stage == .creatingWorktree else {
      return []
    }
    if !outputLines.isEmpty {
      return outputLines
    }
    if let latestOutputLine, !latestOutputLine.isEmpty {
      return [latestOutputLine]
    }
    return []
  }

  mutating func appendOutputLine(_ line: String, maxLines: Int) {
    latestOutputLine = line
    outputLines.append(line)
    if outputLines.count > maxLines {
      outputLines.removeFirst(outputLines.count - maxLines)
    }
  }

  private var baseRefDisplay: String {
    guard let baseRef, !baseRef.isEmpty else {
      return "HEAD"
    }
    return baseRef
  }

  private var baseRefBranchDisplay: String {
    let normalized = baseRefDisplay.lowercased()
    if normalized == "main" || normalized == "origin/main" {
      return String(localized: "main branch")
    }
    if normalized == "head" {
      return "HEAD"
    }
    return String(localized: "\(baseRefDisplay) branch")
  }
}

nonisolated enum WorktreeCreationStage: Hashable, Sendable {
  case loadingLocalBranches
  case choosingWorktreeName
  case checkingRepositoryMode
  case resolvingBaseReference
  case fetchingRemote
  case creatingWorktree
}
