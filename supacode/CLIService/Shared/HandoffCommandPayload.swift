import Foundation

public struct HandoffCommandPayload: Codable, Sendable, Equatable {
  public let action: HandoffAction
  public let artifactPath: String
  /// The agent detected in the target pane when the handoff ran (the "from" side).
  public let outgoingAgent: String?
  /// The receiving agent for `to`.
  public let toAgent: String?
  /// The receiving Prowl Agent Profile, when the handoff targeted a profile.
  public let toProfileID: UUID?
  public let toProfileName: String?
  public let repos: [HandoffRepoPayload]
  public let changedFileCount: Int
  /// Archived copy of the previous artifact, relative to the handoff dir (for `to`).
  public let archivedPath: String?
  /// Auto-captured outgoing session context saved alongside `current.md`.
  public let sessionContext: HandoffSessionPayload?
  /// How the briefing was obtained: "inline", "fork", "none", or "failed".
  public let briefing: String?
  /// Whether a fresh `current.md` was written for the receiver.
  public let hasBriefing: Bool
  /// The pane the receiving agent was launched into (for `to` with launch).
  public let launchedPane: HandoffPanePayload?

  enum CodingKeys: String, CodingKey {
    case action
    case artifactPath = "artifact_path"
    case outgoingAgent = "outgoing_agent"
    case toAgent = "to_agent"
    case toProfileID = "to_profile_id"
    case toProfileName = "to_profile_name"
    case repos
    case changedFileCount = "changed_file_count"
    case archivedPath = "archived_path"
    case sessionContext = "session_context"
    case briefing
    case hasBriefing = "has_briefing"
    case launchedPane = "launched_pane"
  }

  public init(
    action: HandoffAction,
    artifactPath: String,
    outgoingAgent: String? = nil,
    toAgent: String? = nil,
    toProfileID: UUID? = nil,
    toProfileName: String? = nil,
    repos: [HandoffRepoPayload] = [],
    changedFileCount: Int = 0,
    archivedPath: String? = nil,
    sessionContext: HandoffSessionPayload? = nil,
    briefing: String? = nil,
    hasBriefing: Bool = false,
    launchedPane: HandoffPanePayload? = nil
  ) {
    self.action = action
    self.artifactPath = artifactPath
    self.outgoingAgent = outgoingAgent
    self.toAgent = toAgent
    self.toProfileID = toProfileID
    self.toProfileName = toProfileName
    self.repos = repos
    self.changedFileCount = changedFileCount
    self.archivedPath = archivedPath
    self.sessionContext = sessionContext
    self.briefing = briefing
    self.hasBriefing = hasBriefing
    self.launchedPane = launchedPane
  }
}

public struct HandoffSessionPayload: Codable, Sendable, Equatable {
  public let agent: String?
  public let sessionID: String?
  public let paneID: String
  public let paneTitle: String?
  public let source: String
  public let confidence: String
  public let excerptPath: String?
  public let transcriptPath: String?

  enum CodingKeys: String, CodingKey {
    case agent
    case sessionID = "session_id"
    case paneID = "pane_id"
    case paneTitle = "pane_title"
    case source
    case confidence
    case excerptPath = "excerpt_path"
    case transcriptPath = "transcript_path"
  }

  public nonisolated init(
    agent: String?,
    sessionID: String? = nil,
    paneID: String,
    paneTitle: String?,
    source: String,
    confidence: String,
    excerptPath: String? = nil,
    transcriptPath: String? = nil
  ) {
    self.agent = agent
    self.sessionID = sessionID
    self.paneID = paneID
    self.paneTitle = paneTitle
    self.source = source
    self.confidence = confidence
    self.excerptPath = excerptPath
    self.transcriptPath = transcriptPath
  }
}

public struct HandoffRepoPayload: Codable, Sendable, Equatable {
  public let name: String
  public let branch: String?
  public let isGit: Bool
  public let changedFileCount: Int
  public let insertions: Int
  public let deletions: Int

  enum CodingKeys: String, CodingKey {
    case name
    case branch
    case isGit = "is_git"
    case changedFileCount = "changed_file_count"
    case insertions
    case deletions
  }

  public init(
    name: String,
    branch: String?,
    isGit: Bool,
    changedFileCount: Int,
    insertions: Int,
    deletions: Int
  ) {
    self.name = name
    self.branch = branch
    self.isGit = isGit
    self.changedFileCount = changedFileCount
    self.insertions = insertions
    self.deletions = deletions
  }
}

public struct HandoffPanePayload: Codable, Sendable, Equatable {
  public let worktreeID: String
  public let worktreeName: String
  public let tabID: String
  public let paneID: String
  public let paneTitle: String

  enum CodingKeys: String, CodingKey {
    case worktreeID = "worktree_id"
    case worktreeName = "worktree_name"
    case tabID = "tab_id"
    case paneID = "pane_id"
    case paneTitle = "pane_title"
  }

  public init(worktreeID: String, worktreeName: String, tabID: String, paneID: String, paneTitle: String) {
    self.worktreeID = worktreeID
    self.worktreeName = worktreeName
    self.tabID = tabID
    self.paneID = paneID
    self.paneTitle = paneTitle
  }
}
