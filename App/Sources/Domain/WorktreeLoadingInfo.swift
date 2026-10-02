struct WorktreeLoadingInfo: Hashable {
  let name: String
  let repositoryName: String?
  let state: WorktreeLoadingState
  let isFolder: Bool
  let statusTitle: String?
  let statusDetail: String?
  let statusCommand: String?
  let statusLines: [String]

  init(
    name: String,
    repositoryName: String?,
    state: WorktreeLoadingState,
    isFolder: Bool = false,
    statusTitle: String?,
    statusDetail: String?,
    statusCommand: String?,
    statusLines: [String]
  ) {
    self.name = name
    self.repositoryName = repositoryName
    self.state = state
    self.isFolder = isFolder
    self.statusTitle = statusTitle
    self.statusDetail = statusDetail
    self.statusCommand = statusCommand
    self.statusLines = statusLines
  }

  var actionLabel: String {
    switch state {
    case .creating:
      "Creating"
    case .archiving:
      "Archiving"
    case .removing:
      "Removing"
    }
  }

  var statusSubtitle: String {
    let tail = statusLines.suffix(5)
    guard tail.isEmpty else {
      return tail.joined(separator: "\n")
    }
    if let status = statusDetail ?? statusTitle {
      return status
    }
    let noun = isFolder ? "folder" : "worktree"
    if !isFolder, let repositoryName {
      return "\(actionLabel) \(noun) in \(repositoryName)"
    }
    return "\(actionLabel) \(noun)..."
  }
}
