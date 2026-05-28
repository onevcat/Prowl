import Foundation

nonisolated struct RepositorySettings: Codable, Equatable, Sendable {
  private static let currentSchemaVersion = 2
  private static let legacyCopyIgnoredDefault = false
  private static let legacyCopyUntrackedDefault = false
  private static let legacyMergeStrategyDefault: PullRequestMergeStrategy = .merge
  static let defaultFocusedLineChangesRefreshIntervalSeconds = 30
  static let defaultUnfocusedLineChangesRefreshIntervalSeconds = 60
  static let minimumLineChangesRefreshIntervalSeconds = 5

  var setupScript: String
  var archiveScript: String
  var runScript: String
  var openActionID: String
  var worktreeBaseRef: String?
  var worktreeBaseDirectoryPath: String?
  var copyIgnoredOnWorktreeCreate: Bool?
  var copyUntrackedOnWorktreeCreate: Bool?
  var pullRequestMergeStrategy: PullRequestMergeStrategy?
  var customTitle: String?
  var focusedLineChangesRefreshIntervalSeconds: Int
  var unfocusedLineChangesRefreshIntervalSeconds: Int
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
    case customTitle
    case focusedLineChangesRefreshIntervalSeconds
    case unfocusedLineChangesRefreshIntervalSeconds
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
    customTitle: nil,
    focusedLineChangesRefreshIntervalSeconds: defaultFocusedLineChangesRefreshIntervalSeconds,
    unfocusedLineChangesRefreshIntervalSeconds: defaultUnfocusedLineChangesRefreshIntervalSeconds
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
    customTitle: String? = nil,
    focusedLineChangesRefreshIntervalSeconds: Int = defaultFocusedLineChangesRefreshIntervalSeconds,
    unfocusedLineChangesRefreshIntervalSeconds: Int = defaultUnfocusedLineChangesRefreshIntervalSeconds
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
    self.customTitle = customTitle
    self.focusedLineChangesRefreshIntervalSeconds = Self.normalizedLineChangesRefreshIntervalSeconds(
      focusedLineChangesRefreshIntervalSeconds
    )
    self.unfocusedLineChangesRefreshIntervalSeconds = Self.normalizedLineChangesRefreshIntervalSeconds(
      unfocusedLineChangesRefreshIntervalSeconds
    )
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
    focusedLineChangesRefreshIntervalSeconds = Self.normalizedLineChangesRefreshIntervalSeconds(
      try container.decodeIfPresent(Int.self, forKey: .focusedLineChangesRefreshIntervalSeconds)
        ?? Self.default.focusedLineChangesRefreshIntervalSeconds
    )
    unfocusedLineChangesRefreshIntervalSeconds = Self.normalizedLineChangesRefreshIntervalSeconds(
      try container.decodeIfPresent(Int.self, forKey: .unfocusedLineChangesRefreshIntervalSeconds)
        ?? Self.default.unfocusedLineChangesRefreshIntervalSeconds
    )
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

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(setupScript, forKey: .setupScript)
    try container.encode(archiveScript, forKey: .archiveScript)
    try container.encode(runScript, forKey: .runScript)
    try container.encode(openActionID, forKey: .openActionID)
    try container.encodeIfPresent(worktreeBaseRef, forKey: .worktreeBaseRef)
    try container.encodeIfPresent(worktreeBaseDirectoryPath, forKey: .worktreeBaseDirectoryPath)
    try container.encodeIfPresent(copyIgnoredOnWorktreeCreate, forKey: .copyIgnoredOnWorktreeCreate)
    try container.encodeIfPresent(copyUntrackedOnWorktreeCreate, forKey: .copyUntrackedOnWorktreeCreate)
    try container.encodeIfPresent(pullRequestMergeStrategy, forKey: .pullRequestMergeStrategy)
    try container.encodeIfPresent(customTitle, forKey: .customTitle)
    try container.encode(
      focusedLineChangesRefreshIntervalSeconds,
      forKey: .focusedLineChangesRefreshIntervalSeconds
    )
    try container.encode(
      unfocusedLineChangesRefreshIntervalSeconds,
      forKey: .unfocusedLineChangesRefreshIntervalSeconds
    )
  }
}

extension RepositorySettings {
  nonisolated static func normalizedLineChangesRefreshIntervalSeconds(_ value: Int) -> Int {
    max(minimumLineChangesRefreshIntervalSeconds, value)
  }

  nonisolated private static func normalizeLegacyOverride<Value: Equatable>(
    _ value: Value?,
    legacyDefault: Value
  ) -> Value? {
    guard let value else { return nil }
    return value == legacyDefault ? nil : value
  }
}
