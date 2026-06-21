import Foundation

internal nonisolated struct TmuxWindowMetadata: Equatable, Sendable {
  internal let cardID: TmuxCardID
  internal let worktreeID: Worktree.ID
  internal let worktreePath: String
  internal let repositoryRoot: String
  internal let createdAt: String
}

internal nonisolated struct TmuxRawWindowRecord: Equatable, Sendable {
  internal let sessionName: String
  internal let windowID: String
  internal let paneID: String
  internal let windowName: String
  internal let activePath: String
  internal let activeCommand: String
  internal let activeTitle: String
  internal let managed: String
  internal let cardID: String
  internal let worktreeID: String
  internal let worktreePath: String
  internal let repositoryRoot: String
  internal let createdAt: String

  internal init(
    sessionName: String,
    windowID: String,
    paneID: String = "",
    windowName: String,
    activePath: String,
    activeCommand: String,
    activeTitle: String,
    managed: String,
    cardID: String,
    worktreeID: String,
    worktreePath: String,
    repositoryRoot: String,
    createdAt: String
  ) {
    self.sessionName = sessionName
    self.windowID = windowID
    self.paneID = paneID
    self.windowName = windowName
    self.activePath = activePath
    self.activeCommand = activeCommand
    self.activeTitle = activeTitle
    self.managed = managed
    self.cardID = cardID
    self.worktreeID = worktreeID
    self.worktreePath = worktreePath
    self.repositoryRoot = repositoryRoot
    self.createdAt = createdAt
  }
}

internal nonisolated struct TmuxDetachedCardCandidate: Equatable, Identifiable, Sendable {
  internal nonisolated struct ID: RawRepresentable, Equatable, Hashable, Sendable {
    internal let rawValue: String

    internal init(rawValue: String) {
      self.rawValue = rawValue
    }
  }

  internal let id: ID
  internal let sessionName: String
  internal let windowID: TmuxWindowID
  internal let paneID: TmuxPaneID?
  internal let cardID: TmuxCardID
  internal let worktreeID: Worktree.ID
  internal let worktreePath: String
  internal let repositoryRoot: String
  internal let activePath: String?
  internal let activeCommand: String?
  internal let activeTitle: String?
  internal let windowName: String?
  internal let createdAt: String?

  internal init?(record: TmuxRawWindowRecord, socketName: String = "prowl.sock") {
    guard record.sessionName == TmuxTerminalTarget.cardContainerSession else { return nil }
    guard record.managed == "1" else { return nil }
    guard record.windowName != "__prowl_bootstrap" else { return nil }
    guard let windowID = TmuxWindowID(rawValue: record.windowID) else { return nil }
    let paneID = record.paneID.trimmedNonEmpty.flatMap { TmuxPaneID(rawValue: $0) }
    let cardID = record.cardID.trimmedNonEmpty.map(TmuxCardID.init(rawValue:))
      ?? TmuxCardID(rawValue: windowID.rawValue)
    guard let worktreeID = record.worktreeID.trimmedNonEmpty else { return nil }
    guard let worktreePath = record.worktreePath.trimmedNonEmpty else { return nil }
    guard let repositoryRoot = record.repositoryRoot.trimmedNonEmpty else { return nil }

    self.id = ID(rawValue: "\(socketName):\(windowID.rawValue)")
    self.sessionName = record.sessionName
    self.windowID = windowID
    self.paneID = paneID
    self.cardID = cardID
    self.worktreeID = worktreeID
    self.worktreePath = worktreePath
    self.repositoryRoot = repositoryRoot
    self.activePath = record.activePath.trimmedNonEmpty
    self.activeCommand = record.activeCommand.trimmedNonEmpty
    self.activeTitle = record.activeTitle.trimmedNonEmpty
    self.windowName = record.windowName.trimmedNonEmpty
    self.createdAt = record.createdAt.trimmedNonEmpty
  }

  internal var runtimeTitle: String? {
    activeTitle ?? windowName ?? activeCommand
  }
}

internal nonisolated struct TmuxDetachedCardPresentation: Equatable, Sendable {
  internal let id: TmuxDetachedCardCandidate.ID
  internal let title: String
  internal let subtitleLines: [String]

  internal init(
    candidate: TmuxDetachedCardCandidate,
    repositoryName: String,
    homePath: String = NSHomeDirectory()
  ) {
    id = candidate.id
    let worktreeLabel = URL(fileURLWithPath: candidate.worktreePath, isDirectory: true).lastPathComponent
    title = "\(repositoryName) / \(worktreeLabel.isEmpty ? candidate.worktreePath : worktreeLabel)"

    var lines: [String] = []
    if let displayPath = CanvasCurrentDirectoryFormatter.displayPath(for: candidate.activePath, homePath: homePath) {
      lines.append("cwd: \(displayPath)")
    }
    if let runtimeTitle = candidate.runtimeTitle {
      lines.append("title: \(runtimeTitle)")
    }
    lines.append("window: \(candidate.windowID.rawValue)  card: \(candidate.cardID.rawValue)")
    if let createdAt = candidate.createdAt {
      lines.append("created: \(createdAt)")
    }
    subtitleLines = lines
  }
}

internal nonisolated struct TmuxCardStructureDiagnostic: Equatable, Sendable {
  internal let message: String
  internal let socketPath: String
  internal let sessionNames: [String]
  internal let windowCountsBySession: [String: Int]
}

internal nonisolated struct TmuxCardRecoverySnapshot: Equatable, Sendable {
  internal let candidates: [TmuxDetachedCardCandidate]
  internal let diagnostics: [TmuxCardStructureDiagnostic]
}

private extension String {
  nonisolated var trimmedNonEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
