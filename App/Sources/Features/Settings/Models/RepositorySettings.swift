import Foundation

nonisolated struct RepositorySettings: Codable, Equatable, Sendable {
  private static let currentSchemaVersion = 2
  private static let legacyCopyIgnoredDefault = false
  private static let legacyCopyUntrackedDefault = false
  private static let legacyMergeStrategyDefault: PullRequestMergeStrategy = .merge

  var setupScript: String
  var archiveScript: String
  var runScript: String
  var openActionID: String
  var worktreeBaseRef: String?
  var worktreeBaseDirectoryPath: String?
  var copyIgnoredOnWorktreeCreate: Bool?
  var copyUntrackedOnWorktreeCreate: Bool?
  var pullRequestMergeStrategy: PullRequestMergeStrategy?
  var githubAccountOverride: GithubAccountOverride?
  var customTitle: String?
  /// When `nil` (unset) or `true`, Prowl keeps the worktree line-change badges
  /// up to date in the background. Set to `false` to skip the periodic `git diff`
  /// work for large repositories.
  var observeLineDiffsAutomatically: Bool?
  /// When `nil` (unset) or `true`, Prowl periodically fetches pull request state
  /// for this repository's branches. Set to `false` to skip background GitHub
  /// queries (saving API rate-limit budget).
  var fetchPullRequestState: Bool?
  private var schemaVersion: Int

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case setupScript
    case archiveScript
    case runScript
    case openActionID
    case worktreeBaseRef
    case worktreeBaseDirectoryPath
    case copyIgnoredOnWorktreeCreate
    case copyUntrackedOnWorktreeCreate
    case pullRequestMergeStrategy
    case githubAccountOverride
    case customTitle
    case observeLineDiffsAutomatically
    case fetchPullRequestState
  }

  static let `default` = RepositorySettings(
    setupScript: "",
    archiveScript: "",
    runScript: "",
    openActionID: OpenWorktreeAction.automaticSettingsID,
    worktreeBaseRef: nil,
    worktreeBaseDirectoryPath: nil,
    copyIgnoredOnWorktreeCreate: nil,
    copyUntrackedOnWorktreeCreate: nil,
    pullRequestMergeStrategy: nil,
    githubAccountOverride: nil,
    customTitle: nil,
    observeLineDiffsAutomatically: nil,
    fetchPullRequestState: nil
  )

  init(
    setupScript: String,
    archiveScript: String,
    runScript: String,
    openActionID: String,
    worktreeBaseRef: String?,
    worktreeBaseDirectoryPath: String? = nil,
    copyIgnoredOnWorktreeCreate: Bool? = nil,
    copyUntrackedOnWorktreeCreate: Bool? = nil,
    pullRequestMergeStrategy: PullRequestMergeStrategy? = nil,
    githubAccountOverride: GithubAccountOverride? = nil,
    customTitle: String? = nil,
    observeLineDiffsAutomatically: Bool? = nil,
    fetchPullRequestState: Bool? = nil
  ) {
    self.setupScript = setupScript
    self.archiveScript = archiveScript
    self.runScript = runScript
    self.openActionID = openActionID
    self.worktreeBaseRef = worktreeBaseRef
    self.worktreeBaseDirectoryPath = worktreeBaseDirectoryPath
    self.copyIgnoredOnWorktreeCreate = copyIgnoredOnWorktreeCreate
    self.copyUntrackedOnWorktreeCreate = copyUntrackedOnWorktreeCreate
    self.pullRequestMergeStrategy = pullRequestMergeStrategy
    self.githubAccountOverride = githubAccountOverride?.normalized
    self.customTitle = customTitle
    self.observeLineDiffsAutomatically = observeLineDiffsAutomatically
    self.fetchPullRequestState = fetchPullRequestState
    schemaVersion = Self.currentSchemaVersion
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedSchemaVersion =
      try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
      ?? 1
    setupScript =
      try container.decodeIfPresent(String.self, forKey: .setupScript)
      ?? Self.default.setupScript
    archiveScript =
      try container.decodeIfPresent(String.self, forKey: .archiveScript)
      ?? Self.default.archiveScript
    runScript =
      try container.decodeIfPresent(String.self, forKey: .runScript)
      ?? Self.default.runScript
    openActionID =
      try container.decodeIfPresent(String.self, forKey: .openActionID)
      ?? Self.default.openActionID
    worktreeBaseRef =
      try container.decodeIfPresent(String.self, forKey: .worktreeBaseRef)
    worktreeBaseDirectoryPath =
      try container.decodeIfPresent(String.self, forKey: .worktreeBaseDirectoryPath)
    customTitle =
      try container.decodeIfPresent(String.self, forKey: .customTitle)
    observeLineDiffsAutomatically =
      try container.decodeIfPresent(Bool.self, forKey: .observeLineDiffsAutomatically)
    fetchPullRequestState =
      try container.decodeIfPresent(Bool.self, forKey: .fetchPullRequestState)
    githubAccountOverride =
      try container.decodeIfPresent(GithubAccountOverride.self, forKey: .githubAccountOverride)?.normalized
    if decodedSchemaVersion >= Self.currentSchemaVersion {
      copyIgnoredOnWorktreeCreate =
        try container.decodeIfPresent(
          Bool.self,
          forKey: .copyIgnoredOnWorktreeCreate
        )
      copyUntrackedOnWorktreeCreate =
        try container.decodeIfPresent(
          Bool.self,
          forKey: .copyUntrackedOnWorktreeCreate
        )
      pullRequestMergeStrategy =
        try container.decodeIfPresent(
          PullRequestMergeStrategy.self,
          forKey: .pullRequestMergeStrategy
        )
    } else {
      copyIgnoredOnWorktreeCreate = Self.normalizeLegacyOverride(
        try container.decodeIfPresent(
          Bool.self,
          forKey: .copyIgnoredOnWorktreeCreate
        ),
        legacyDefault: Self.legacyCopyIgnoredDefault
      )
      copyUntrackedOnWorktreeCreate = Self.normalizeLegacyOverride(
        try container.decodeIfPresent(
          Bool.self,
          forKey: .copyUntrackedOnWorktreeCreate
        ),
        legacyDefault: Self.legacyCopyUntrackedDefault
      )
      pullRequestMergeStrategy = Self.normalizeLegacyOverride(
        try container.decodeIfPresent(
          PullRequestMergeStrategy.self,
          forKey: .pullRequestMergeStrategy
        ),
        legacyDefault: Self.legacyMergeStrategyDefault
      )
    }
    schemaVersion = Self.currentSchemaVersion
  }
}

extension RepositorySettings {
  /// Resolved value for background line-change observation. Defaults to `true`
  /// when the override is unset.
  var observesLineDiffsAutomatically: Bool {
    observeLineDiffsAutomatically ?? true
  }

  /// Resolved value for background pull request state fetching. Defaults to
  /// `true` when the override is unset.
  var fetchesPullRequestState: Bool {
    fetchPullRequestState ?? true
  }

  nonisolated private static func normalizeLegacyOverride<Value: Equatable>(
    _ value: Value?,
    legacyDefault: Value
  ) -> Value? {
    guard let value else { return nil }
    return value == legacyDefault ? nil : value
  }
}
