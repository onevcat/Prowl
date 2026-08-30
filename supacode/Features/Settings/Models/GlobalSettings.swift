nonisolated struct GlobalSettings: Codable, Equatable, Sendable {
  var appearanceMode: AppearanceMode
  var defaultEditorID: String
  var confirmBeforeQuit: Bool
  var updatesAutomaticallyCheckForUpdates: Bool
  var updatesAutomaticallyDownloadUpdates: Bool
  var inAppNotificationsEnabled: Bool
  var notificationSound: NotificationSound
  var systemNotificationsEnabled: Bool
  var muteNotificationsForActiveSurface: Bool
  var moveNotifiedWorktreeToTop: Bool
  var commandFinishedNotificationEnabled: Bool
  var commandFinishedNotificationThreshold: Int
  var analyticsEnabled: Bool
  var crashReportsEnabled: Bool
  var githubIntegrationEnabled: Bool
  var deleteBranchOnAutomaticCleanup: Bool
  var mergedWorktreeAction: MergedWorktreeAction?
  var promptForWorktreeCreation: Bool
  var fetchOriginBeforeWorktreeCreation: Bool
  var defaultWorktreeBaseDirectoryPath: String?
  var copyIgnoredOnWorktreeCreate: Bool
  var copyUntrackedOnWorktreeCreate: Bool
  var pullRequestMergeStrategy: PullRequestMergeStrategy
  var restoreTerminalLayoutOnLaunch: Bool
  var terminalFontSize: Float32?
  var archivedAutoDeletePeriod: AutoDeletePeriod?
  var keybindingUserOverrides: KeybindingUserOverrideStore
  var defaultViewMode: DefaultViewMode
  var canvasDefaultLayout: CanvasDefaultLayout
  var dimUnfocusedSplits: Bool
  var autoShowActiveAgentsPanel: Bool
  var showActiveAgentTabTitles: Bool
  var showActiveAgentStatusInShelf: Bool
  var windowTintMode: WindowTintMode
  var windowTintCustomColor: TintColor
  var showRunButtonInToolbar: Bool
  var showDefaultEditorInToolbar: Bool
  var dockBounceMode: DockBounceMode
  var showNotificationDotOnDock: Bool
  var shelfSpineTintFallback: ShelfSpineTintFallback
  var shelfSpineTintFollowsRepositoryColor: Bool
  var externalDiffToolID: String = ExternalDiffTool.builtIn.settingsID
  var externalDiffCustomCommand: String = ""
  var detectRepositoryIconsAutomatically: Bool = true
  var minimumTextSize: MinimumTextSize = .system
  var interfaceTextScale: InterfaceTextScale = .system

  static let `default` = GlobalSettings(
    appearanceMode: .dark,
    defaultEditorID: OpenWorktreeAction.automaticSettingsID,
    confirmBeforeQuit: true,
    updatesAutomaticallyCheckForUpdates: true,
    updatesAutomaticallyDownloadUpdates: false,
    inAppNotificationsEnabled: true,
    notificationSound: .supacodeClassic,
    systemNotificationsEnabled: false,
    muteNotificationsForActiveSurface: true,
    moveNotifiedWorktreeToTop: true,
    commandFinishedNotificationEnabled: true,
    commandFinishedNotificationThreshold: 10,
    analyticsEnabled: true,
    crashReportsEnabled: true,
    githubIntegrationEnabled: true,
    deleteBranchOnAutomaticCleanup: false,
    mergedWorktreeAction: nil,
    promptForWorktreeCreation: true,
    fetchOriginBeforeWorktreeCreation: true,
    defaultWorktreeBaseDirectoryPath: nil,
    copyIgnoredOnWorktreeCreate: false,
    copyUntrackedOnWorktreeCreate: false,
    pullRequestMergeStrategy: .merge,
    restoreTerminalLayoutOnLaunch: false,
    archivedAutoDeletePeriod: nil,
    terminalFontSize: nil,
    keybindingUserOverrides: .empty,
    defaultViewMode: .normal,
    canvasDefaultLayout: .tile,
    dimUnfocusedSplits: true,
    autoShowActiveAgentsPanel: false,
    showActiveAgentTabTitles: false,
    showActiveAgentStatusInShelf: true,
    windowTintMode: .repositoryColor,
    windowTintCustomColor: .default,
    showRunButtonInToolbar: true,
    showDefaultEditorInToolbar: true,
    dockBounceMode: .off,
    showNotificationDotOnDock: false,
    shelfSpineTintFallback: .neutral,
    shelfSpineTintFollowsRepositoryColor: true
  )

  init(
    appearanceMode: AppearanceMode,
    defaultEditorID: String,
    confirmBeforeQuit: Bool,
    updatesAutomaticallyCheckForUpdates: Bool,
    updatesAutomaticallyDownloadUpdates: Bool,
    inAppNotificationsEnabled: Bool,
    notificationSound: NotificationSound = .supacodeClassic,
    systemNotificationsEnabled: Bool = false,
    muteNotificationsForActiveSurface: Bool = true,
    moveNotifiedWorktreeToTop: Bool,
    commandFinishedNotificationEnabled: Bool = true,
    commandFinishedNotificationThreshold: Int = 10,
    analyticsEnabled: Bool,
    crashReportsEnabled: Bool,
    githubIntegrationEnabled: Bool,
    deleteBranchOnAutomaticCleanup: Bool,
    mergedWorktreeAction: MergedWorktreeAction? = nil,
    promptForWorktreeCreation: Bool,
    fetchOriginBeforeWorktreeCreation: Bool = true,
    defaultWorktreeBaseDirectoryPath: String? = nil,
    copyIgnoredOnWorktreeCreate: Bool = false,
    copyUntrackedOnWorktreeCreate: Bool = false,
    pullRequestMergeStrategy: PullRequestMergeStrategy = .merge,
    restoreTerminalLayoutOnLaunch: Bool = false,
    archivedAutoDeletePeriod: AutoDeletePeriod? = nil,
    terminalFontSize: Float32? = nil,
    keybindingUserOverrides: KeybindingUserOverrideStore = .empty,
    defaultViewMode: DefaultViewMode = .normal,
    canvasDefaultLayout: CanvasDefaultLayout = .tile,
    dimUnfocusedSplits: Bool = true,
    autoShowActiveAgentsPanel: Bool = false,
    showActiveAgentTabTitles: Bool = false,
    showActiveAgentStatusInShelf: Bool = true,
    windowTintMode: WindowTintMode = .repositoryColor,
    windowTintCustomColor: TintColor = .default,
    showRunButtonInToolbar: Bool = true,
    showDefaultEditorInToolbar: Bool = true,
    dockBounceMode: DockBounceMode = .off,
    showNotificationDotOnDock: Bool = false,
    shelfSpineTintFallback: ShelfSpineTintFallback = .neutral,
    shelfSpineTintFollowsRepositoryColor: Bool = true
  ) {
    self.appearanceMode = appearanceMode
    self.defaultEditorID = defaultEditorID
    self.confirmBeforeQuit = confirmBeforeQuit
    self.updatesAutomaticallyCheckForUpdates = updatesAutomaticallyCheckForUpdates
    self.updatesAutomaticallyDownloadUpdates = updatesAutomaticallyDownloadUpdates
    self.inAppNotificationsEnabled = inAppNotificationsEnabled
    self.notificationSound = notificationSound
    self.systemNotificationsEnabled = systemNotificationsEnabled
    self.muteNotificationsForActiveSurface = muteNotificationsForActiveSurface
    self.moveNotifiedWorktreeToTop = moveNotifiedWorktreeToTop
    self.commandFinishedNotificationEnabled = commandFinishedNotificationEnabled
    self.commandFinishedNotificationThreshold = commandFinishedNotificationThreshold
    self.analyticsEnabled = analyticsEnabled
    self.crashReportsEnabled = crashReportsEnabled
    self.githubIntegrationEnabled = githubIntegrationEnabled
    self.deleteBranchOnAutomaticCleanup = deleteBranchOnAutomaticCleanup
    self.mergedWorktreeAction = mergedWorktreeAction
    self.promptForWorktreeCreation = promptForWorktreeCreation
    self.fetchOriginBeforeWorktreeCreation = fetchOriginBeforeWorktreeCreation
    self.defaultWorktreeBaseDirectoryPath = defaultWorktreeBaseDirectoryPath
    self.copyIgnoredOnWorktreeCreate = copyIgnoredOnWorktreeCreate
    self.copyUntrackedOnWorktreeCreate = copyUntrackedOnWorktreeCreate
    self.pullRequestMergeStrategy = pullRequestMergeStrategy
    self.restoreTerminalLayoutOnLaunch = restoreTerminalLayoutOnLaunch
    self.archivedAutoDeletePeriod = archivedAutoDeletePeriod
    self.terminalFontSize = terminalFontSize
    self.keybindingUserOverrides = keybindingUserOverrides
    self.defaultViewMode = defaultViewMode
    self.canvasDefaultLayout = canvasDefaultLayout
    self.dimUnfocusedSplits = dimUnfocusedSplits
    self.autoShowActiveAgentsPanel = autoShowActiveAgentsPanel
    self.showActiveAgentTabTitles = showActiveAgentTabTitles
    self.showActiveAgentStatusInShelf = showActiveAgentStatusInShelf
    self.windowTintMode = windowTintMode
    self.windowTintCustomColor = windowTintCustomColor
    self.showRunButtonInToolbar = showRunButtonInToolbar
    self.showDefaultEditorInToolbar = showDefaultEditorInToolbar
    self.dockBounceMode = dockBounceMode
    self.showNotificationDotOnDock = showNotificationDotOnDock
    self.shelfSpineTintFallback = shelfSpineTintFallback
    self.shelfSpineTintFollowsRepositoryColor = shelfSpineTintFollowsRepositoryColor
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(appearanceMode, forKey: .appearanceMode)
    try container.encode(defaultEditorID, forKey: .defaultEditorID)
    try container.encode(confirmBeforeQuit, forKey: .confirmBeforeQuit)
    try container.encode(updatesAutomaticallyCheckForUpdates, forKey: .updatesAutomaticallyCheckForUpdates)
    try container.encode(updatesAutomaticallyDownloadUpdates, forKey: .updatesAutomaticallyDownloadUpdates)
    try container.encode(inAppNotificationsEnabled, forKey: .inAppNotificationsEnabled)
    try container.encode(notificationSound, forKey: .notificationSound)
    try container.encode(systemNotificationsEnabled, forKey: .systemNotificationsEnabled)
    try container.encode(muteNotificationsForActiveSurface, forKey: .muteNotificationsForActiveSurface)
    try container.encode(moveNotifiedWorktreeToTop, forKey: .moveNotifiedWorktreeToTop)
    try container.encode(commandFinishedNotificationEnabled, forKey: .commandFinishedNotificationEnabled)
    try container.encode(commandFinishedNotificationThreshold, forKey: .commandFinishedNotificationThreshold)
    try container.encode(analyticsEnabled, forKey: .analyticsEnabled)
    try container.encode(crashReportsEnabled, forKey: .crashReportsEnabled)
    try container.encode(githubIntegrationEnabled, forKey: .githubIntegrationEnabled)
    try container.encode(deleteBranchOnAutomaticCleanup, forKey: .deleteBranchOnAutomaticCleanup)
    try container.encodeIfPresent(mergedWorktreeAction, forKey: .mergedWorktreeAction)
    try container.encode(promptForWorktreeCreation, forKey: .promptForWorktreeCreation)
    try container.encode(fetchOriginBeforeWorktreeCreation, forKey: .fetchOriginBeforeWorktreeCreation)
    try container.encodeIfPresent(defaultWorktreeBaseDirectoryPath, forKey: .defaultWorktreeBaseDirectoryPath)
    try container.encode(copyIgnoredOnWorktreeCreate, forKey: .copyIgnoredOnWorktreeCreate)
    try container.encode(copyUntrackedOnWorktreeCreate, forKey: .copyUntrackedOnWorktreeCreate)
    try container.encode(pullRequestMergeStrategy, forKey: .pullRequestMergeStrategy)
    try container.encode(restoreTerminalLayoutOnLaunch, forKey: .restoreTerminalLayoutOnLaunch)
    try container.encodeIfPresent(archivedAutoDeletePeriod?.rawValue, forKey: .archivedAutoDeletePeriod)
    try container.encodeIfPresent(terminalFontSize, forKey: .terminalFontSize)
    try container.encode(keybindingUserOverrides, forKey: .keybindingUserOverrides)
    try container.encode(defaultViewMode, forKey: .defaultViewMode)
    try container.encode(canvasDefaultLayout, forKey: .canvasDefaultLayout)
    try container.encode(dimUnfocusedSplits, forKey: .dimUnfocusedSplits)
    try container.encode(autoShowActiveAgentsPanel, forKey: .autoShowActiveAgentsPanel)
    try container.encode(showActiveAgentTabTitles, forKey: .showActiveAgentTabTitles)
    try container.encode(showActiveAgentStatusInShelf, forKey: .showActiveAgentStatusInShelf)
    try container.encode(windowTintMode, forKey: .windowTintMode)
    try container.encode(windowTintCustomColor, forKey: .windowTintCustomColor)
    try container.encode(showRunButtonInToolbar, forKey: .showRunButtonInToolbar)
    try container.encode(showDefaultEditorInToolbar, forKey: .showDefaultEditorInToolbar)
    try container.encode(dockBounceMode, forKey: .dockBounceMode)
    try container.encode(showNotificationDotOnDock, forKey: .showNotificationDotOnDock)
    try container.encode(shelfSpineTintFallback, forKey: .shelfSpineTintFallback)
    try container.encode(shelfSpineTintFollowsRepositoryColor, forKey: .shelfSpineTintFollowsRepositoryColor)
    try container.encode(externalDiffToolID, forKey: .externalDiffToolID)
    try container.encode(externalDiffCustomCommand, forKey: .externalDiffCustomCommand)
    try container.encode(detectRepositoryIconsAutomatically, forKey: .detectRepositoryIconsAutomatically)
    try container.encode(minimumTextSize, forKey: .minimumTextSize)
    try container.encode(interfaceTextScale, forKey: .interfaceTextScale)
  }

  private enum CodingKeys: String, CodingKey {
    case appearanceMode
    case defaultEditorID
    case confirmBeforeQuit
    case updatesAutomaticallyCheckForUpdates
    case updatesAutomaticallyDownloadUpdates
    case inAppNotificationsEnabled
    case notificationSound
    case systemNotificationsEnabled
    case muteNotificationsForActiveSurface
    case moveNotifiedWorktreeToTop
    case commandFinishedNotificationEnabled
    case commandFinishedNotificationThreshold
    case analyticsEnabled
    case crashReportsEnabled
    case githubIntegrationEnabled
    case deleteBranchOnAutomaticCleanup
    case mergedWorktreeAction
    case promptForWorktreeCreation
    case fetchOriginBeforeWorktreeCreation
    case defaultWorktreeBaseDirectoryPath
    case copyIgnoredOnWorktreeCreate
    case copyUntrackedOnWorktreeCreate
    case pullRequestMergeStrategy
    case restoreTerminalLayoutOnLaunch
    case archivedAutoDeletePeriod
    case terminalFontSize
    case keybindingUserOverrides
    case defaultViewMode
    case canvasDefaultLayout
    case dimUnfocusedSplits
    case autoShowActiveAgentsPanel
    case showActiveAgentTabTitles
    case showActiveAgentStatusInShelf
    case windowTintMode
    case windowTintCustomColor
    case showRunButtonInToolbar
    case showDefaultEditorInToolbar
    case dockBounceMode
    case showNotificationDotOnDock
    case shelfSpineTintFallback
    case shelfSpineTintFollowsRepositoryColor
    case externalDiffToolID
    case externalDiffCustomCommand
    case detectRepositoryIconsAutomatically
    case minimumTextSize
    case interfaceTextScale
    // Legacy keys for migration
    case automaticallyArchiveMergedWorktrees
    case notificationSoundEnabled
    case deleteBranchOnDeleteWorktree
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    appearanceMode = try container.decode(AppearanceMode.self, forKey: .appearanceMode)
    defaultEditorID =
      try container.decodeIfPresent(String.self, forKey: .defaultEditorID)
      ?? Self.default.defaultEditorID
    confirmBeforeQuit =
      try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeQuit)
      ?? Self.default.confirmBeforeQuit
    updatesAutomaticallyCheckForUpdates = try container.decode(Bool.self, forKey: .updatesAutomaticallyCheckForUpdates)
    updatesAutomaticallyDownloadUpdates = try container.decode(Bool.self, forKey: .updatesAutomaticallyDownloadUpdates)
    inAppNotificationsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .inAppNotificationsEnabled)
      ?? Self.default.inAppNotificationsEnabled
    notificationSound = try Self.decodeNotificationSound(from: container)
    systemNotificationsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .systemNotificationsEnabled)
      ?? Self.default.systemNotificationsEnabled
    muteNotificationsForActiveSurface =
      try container.decodeIfPresent(Bool.self, forKey: .muteNotificationsForActiveSurface)
      ?? Self.default.muteNotificationsForActiveSurface
    moveNotifiedWorktreeToTop =
      try container.decodeIfPresent(Bool.self, forKey: .moveNotifiedWorktreeToTop)
      ?? Self.default.moveNotifiedWorktreeToTop
    commandFinishedNotificationEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .commandFinishedNotificationEnabled)
      ?? Self.default.commandFinishedNotificationEnabled
    commandFinishedNotificationThreshold =
      try container.decodeIfPresent(Int.self, forKey: .commandFinishedNotificationThreshold)
      ?? Self.default.commandFinishedNotificationThreshold
    analyticsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .analyticsEnabled)
      ?? Self.default.analyticsEnabled
    crashReportsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .crashReportsEnabled)
      ?? Self.default.crashReportsEnabled
    githubIntegrationEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .githubIntegrationEnabled)
      ?? Self.default.githubIntegrationEnabled
    deleteBranchOnAutomaticCleanup = try Self.decodeDeleteBranchOnAutomaticCleanup(from: container)
    mergedWorktreeAction = try Self.decodeMergedWorktreeAction(from: container)
    promptForWorktreeCreation =
      try container.decodeIfPresent(Bool.self, forKey: .promptForWorktreeCreation)
      ?? Self.default.promptForWorktreeCreation
    fetchOriginBeforeWorktreeCreation =
      try container.decodeIfPresent(Bool.self, forKey: .fetchOriginBeforeWorktreeCreation)
      ?? Self.default.fetchOriginBeforeWorktreeCreation
    defaultWorktreeBaseDirectoryPath =
      try container.decodeIfPresent(String.self, forKey: .defaultWorktreeBaseDirectoryPath)
      ?? Self.default.defaultWorktreeBaseDirectoryPath
    copyIgnoredOnWorktreeCreate =
      try container.decodeIfPresent(Bool.self, forKey: .copyIgnoredOnWorktreeCreate)
      ?? Self.default.copyIgnoredOnWorktreeCreate
    copyUntrackedOnWorktreeCreate =
      try container.decodeIfPresent(Bool.self, forKey: .copyUntrackedOnWorktreeCreate)
      ?? Self.default.copyUntrackedOnWorktreeCreate
    pullRequestMergeStrategy =
      try container.decodeIfPresent(PullRequestMergeStrategy.self, forKey: .pullRequestMergeStrategy)
      ?? Self.default.pullRequestMergeStrategy
    restoreTerminalLayoutOnLaunch =
      try container.decodeIfPresent(Bool.self, forKey: .restoreTerminalLayoutOnLaunch)
      ?? Self.default.restoreTerminalLayoutOnLaunch
    if let rawAutoDelete = try container.decodeIfPresent(Int.self, forKey: .archivedAutoDeletePeriod) {
      archivedAutoDeletePeriod = AutoDeletePeriod(rawValue: rawAutoDelete)
    } else {
      archivedAutoDeletePeriod = Self.default.archivedAutoDeletePeriod
    }
    terminalFontSize =
      try container.decodeIfPresent(Float32.self, forKey: .terminalFontSize)
      ?? Self.default.terminalFontSize
    keybindingUserOverrides =
      try container.decodeIfPresent(KeybindingUserOverrideStore.self, forKey: .keybindingUserOverrides)
      ?? Self.default.keybindingUserOverrides
    (defaultViewMode, canvasDefaultLayout) = try Self.decodeViewSettings(from: container)
    dimUnfocusedSplits =
      try container.decodeIfPresent(Bool.self, forKey: .dimUnfocusedSplits)
      ?? Self.default.dimUnfocusedSplits
    autoShowActiveAgentsPanel =
      try container.decodeIfPresent(Bool.self, forKey: .autoShowActiveAgentsPanel)
      ?? Self.default.autoShowActiveAgentsPanel
    showActiveAgentTabTitles =
      try container.decodeIfPresent(Bool.self, forKey: .showActiveAgentTabTitles)
      ?? Self.default.showActiveAgentTabTitles
    showActiveAgentStatusInShelf =
      try container.decodeIfPresent(Bool.self, forKey: .showActiveAgentStatusInShelf)
      ?? Self.default.showActiveAgentStatusInShelf
    (windowTintMode, windowTintCustomColor) = try Self.decodeWindowTint(from: container)
    (shelfSpineTintFallback, shelfSpineTintFollowsRepositoryColor) = try Self.decodeShelfSpineTint(from: container)
    (externalDiffToolID, externalDiffCustomCommand) = try Self.decodeExternalDiffSettings(from: container)
    detectRepositoryIconsAutomatically =
      try container.decodeIfPresent(Bool.self, forKey: .detectRepositoryIconsAutomatically)
      ?? true
    (minimumTextSize, interfaceTextScale) = try Self.decodeInterfaceTextSettings(from: container)
    let toolbarAndDock = try Self.decodeToolbarAndDockSettings(from: container)
    showRunButtonInToolbar = toolbarAndDock.showRunButtonInToolbar
    showDefaultEditorInToolbar = toolbarAndDock.showDefaultEditorInToolbar
    dockBounceMode = toolbarAndDock.dockBounceMode
    showNotificationDotOnDock = toolbarAndDock.showNotificationDotOnDock
  }

  private static func decodeViewSettings(
    from container: KeyedDecodingContainer<CodingKeys>
  ) throws -> (DefaultViewMode, CanvasDefaultLayout) {
    let mode =
      try container.decodeIfPresent(DefaultViewMode.self, forKey: .defaultViewMode)
      ?? Self.default.defaultViewMode
    let layout =
      try container.decodeIfPresent(CanvasDefaultLayout.self, forKey: .canvasDefaultLayout)
      ?? Self.default.canvasDefaultLayout
    return (mode, layout)
  }

  private static func decodeWindowTint(
    from container: KeyedDecodingContainer<CodingKeys>
  ) throws -> (WindowTintMode, TintColor) {
    let mode =
      try container.decodeIfPresent(WindowTintMode.self, forKey: .windowTintMode)
      ?? Self.default.windowTintMode
    let customColor =
      try container.decodeIfPresent(TintColor.self, forKey: .windowTintCustomColor)
      ?? Self.default.windowTintCustomColor
    return (mode, customColor)
  }

  private static func decodeShelfSpineTint(
    from container: KeyedDecodingContainer<CodingKeys>
  ) throws -> (ShelfSpineTintFallback, Bool) {
    let fallback =
      try container.decodeIfPresent(ShelfSpineTintFallback.self, forKey: .shelfSpineTintFallback)
      ?? Self.default.shelfSpineTintFallback
    let followsRepositoryColor =
      try container.decodeIfPresent(Bool.self, forKey: .shelfSpineTintFollowsRepositoryColor)
      ?? Self.default.shelfSpineTintFollowsRepositoryColor
    return (fallback, followsRepositoryColor)
  }

  private static func decodeExternalDiffSettings(
    from container: KeyedDecodingContainer<CodingKeys>
  ) throws -> (String, String) {
    let toolID =
      ExternalDiffTool.normalizedSettingsID(try container.decodeIfPresent(String.self, forKey: .externalDiffToolID))
    let customCommand =
      try container.decodeIfPresent(String.self, forKey: .externalDiffCustomCommand)
      ?? Self.default.externalDiffCustomCommand
    return (toolID, customCommand)
  }

  /// Folds the removed `notificationSoundEnabled` toggle: off becomes `.never`,
  /// on the default sound. `try?` keeps an unrecognized raw value (e.g. from a
  /// newer build) from failing the whole decode — it flattens both a decode
  /// throw and an absent key to `nil`, so either falls through to the legacy
  /// key and then the default.
  private static func decodeNotificationSound(
    from container: KeyedDecodingContainer<CodingKeys>
  ) throws -> NotificationSound {
    if let sound = try? container.decodeIfPresent(NotificationSound.self, forKey: .notificationSound) {
      return sound
    }
    if let legacyEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationSoundEnabled) {
      return legacyEnabled ? Self.default.notificationSound : .never
    }
    return Self.default.notificationSound
  }

  /// Falls back to the legacy `deleteBranchOnDeleteWorktree` key: users who
  /// opted into branch deletion before the setting was split keep branch
  /// deletion during automatic cleanup.
  private static func decodeDeleteBranchOnAutomaticCleanup(
    from container: KeyedDecodingContainer<CodingKeys>
  ) throws -> Bool {
    if let value = try container.decodeIfPresent(Bool.self, forKey: .deleteBranchOnAutomaticCleanup) {
      return value
    }
    if let legacy = try container.decodeIfPresent(Bool.self, forKey: .deleteBranchOnDeleteWorktree) {
      return legacy
    }
    return Self.default.deleteBranchOnAutomaticCleanup
  }

  private static func decodeMergedWorktreeAction(
    from container: KeyedDecodingContainer<CodingKeys>
  ) throws -> MergedWorktreeAction? {
    if let decoded = try container.decodeIfPresent(MergedWorktreeAction.self, forKey: .mergedWorktreeAction) {
      return decoded
    }
    if let legacyBool = try container.decodeIfPresent(Bool.self, forKey: .automaticallyArchiveMergedWorktrees) {
      return legacyBool ? .archive : nil
    }
    return Self.default.mergedWorktreeAction
  }

  /// The toolbar-visibility and Dock-notification preferences, decoded as a
  /// unit so `init(from:)` stays within the body-length limit.
  private struct ToolbarAndDockSettings {
    let showRunButtonInToolbar: Bool
    let showDefaultEditorInToolbar: Bool
    let dockBounceMode: DockBounceMode
    let showNotificationDotOnDock: Bool
  }

  /// Raw-string decode so a settings file written by a newer build with an
  /// unknown size or scale falls back to the default instead of failing
  /// wholesale.
  private static func decodeInterfaceTextSettings(
    from container: KeyedDecodingContainer<CodingKeys>
  ) throws -> (MinimumTextSize, InterfaceTextScale) {
    let minimum =
      (try container.decodeIfPresent(String.self, forKey: .minimumTextSize))
      .flatMap(MinimumTextSize.init(rawValue:))
      ?? Self.default.minimumTextSize
    let scale =
      (try container.decodeIfPresent(String.self, forKey: .interfaceTextScale))
      .flatMap(InterfaceTextScale.init(rawValue:))
      ?? Self.default.interfaceTextScale
    return (minimum, scale)
  }

  private static func decodeToolbarAndDockSettings(
    from container: KeyedDecodingContainer<CodingKeys>
  ) throws -> ToolbarAndDockSettings {
    try ToolbarAndDockSettings(
      showRunButtonInToolbar: container.decodeIfPresent(Bool.self, forKey: .showRunButtonInToolbar)
        ?? Self.default.showRunButtonInToolbar,
      showDefaultEditorInToolbar: container.decodeIfPresent(Bool.self, forKey: .showDefaultEditorInToolbar)
        ?? Self.default.showDefaultEditorInToolbar,
      dockBounceMode: container.decodeIfPresent(DockBounceMode.self, forKey: .dockBounceMode)
        ?? Self.default.dockBounceMode,
      showNotificationDotOnDock: container.decodeIfPresent(Bool.self, forKey: .showNotificationDotOnDock)
        ?? Self.default.showNotificationDotOnDock
    )
  }
}
