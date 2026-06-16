import AppKit
import ComposableArchitecture
import Foundation
import IdentifiedCollections
import PostHog
import SwiftUI

nonisolated let githubIntegrationRecoveryInterval: Duration = .seconds(15)
nonisolated let worktreeCreationProgressLineLimit = 200
nonisolated let worktreeCreationProgressUpdateStride = 20
nonisolated let archiveScriptProgressLineLimit = 200
nonisolated let restoreCanvasModeOnLaunchAppStorageKey = "restoreCanvasModeOnLaunch"
nonisolated let lastCanvasFocusedWorktreeIDAppStorageKey = "lastCanvasFocusedWorktreeID"
nonisolated let lastCanvasFocusedTabIDAppStorageKey = "lastCanvasFocusedTabID"
let secondsPerDay: Double = 86_400
let repositoriesLogger = SupaLogger("RepositoriesFeature")

nonisolated struct WorktreeCreationProgressUpdateThrottle {
  private let stride: Int
  private var hasEmittedFirstLine = false
  private var unsentLineCount = 0

  init(stride: Int) {
    precondition(stride > 0)
    self.stride = stride
  }

  mutating func recordLine() -> Bool {
    unsentLineCount += 1
    if !hasEmittedFirstLine {
      hasEmittedFirstLine = true
      unsentLineCount = 0
      return true
    }
    if unsentLineCount >= stride {
      unsentLineCount = 0
      return true
    }
    return false
  }

  mutating func flush() -> Bool {
    guard unsentLineCount > 0 else {
      return false
    }
    unsentLineCount = 0
    return true
  }
}

struct PendingSidebarReveal: Equatable, Sendable {
  let id: Int
  let worktreeID: Worktree.ID
}

struct PendingRenameBranchRequest: Equatable, Sendable {
  let id: Int
  let worktreeID: Worktree.ID
}

struct DeleteWorktreeConfirmation: Equatable, Identifiable {
  let id: Int
  let title: String
  let message: String
  let targets: [RepositoriesFeature.DeleteWorktreeTarget]
  var deleteBranch: Bool
}

struct ForceDeleteBranchRequest: Equatable {
  let branchName: String
  let repositoryRootURL: URL
  let errorMessage: String
}

@Reducer
struct RepositoriesFeature {
  enum CancelID {
    static let load = "repositories.load"
    static let toastAutoDismiss = "repositories.toastAutoDismiss"
    static let githubIntegrationAvailability = "repositories.githubIntegrationAvailability"
    static let githubIntegrationRecovery = "repositories.githubIntegrationRecovery"
    static let worktreePromptLoad = "repositories.worktreePromptLoad"
    static let worktreePromptValidation = "repositories.worktreePromptValidation"
    static func archiveScript(_ worktreeID: Worktree.ID) -> String {
      "repositories.archiveScript.\(worktreeID)"
    }
    static func delayedPRRefresh(_ worktreeID: Worktree.ID) -> String {
      "repositories.delayedPRRefresh.\(worktreeID)"
    }
  }

  @CasePathable
  enum WorktreeCreationAction: Equatable {
    case promptCanceled
    case promptDismissed
    case createRandomWorktree
    case createRandomWorktreeInRepository(Repository.ID)
    case createWorktreeInRepository(
      repositoryID: Repository.ID,
      nameSource: WorktreeCreationNameSource,
      baseRefSource: WorktreeCreationBaseRefSource,
      fetchRemote: Bool,
      placement: WorktreePlacementOverride = WorktreePlacementOverride()
    )
    case promptedWorktreeCreationDataLoaded(
      repositoryID: Repository.ID,
      baseRefOptions: [String],
      automaticBaseRef: String,
      selectedBaseRef: String?
    )
    case startPromptedWorktreeCreation(
      repositoryID: Repository.ID,
      branchName: String,
      baseRef: String?,
      placement: WorktreePlacementOverride = WorktreePlacementOverride()
    )
    case promptedWorktreeCreationChecked(
      repositoryID: Repository.ID,
      branchName: String,
      baseRef: String?,
      fetchRemote: Bool,
      placement: WorktreePlacementOverride = WorktreePlacementOverride(),
      duplicateMessage: String?
    )
    case pendingWorktreeProgressUpdated(id: Worktree.ID, progress: WorktreeCreationProgress)
    case createRandomWorktreeSucceeded(
      Worktree,
      repositoryID: Repository.ID,
      pendingID: Worktree.ID
    )
    case createRandomWorktreeFailed(
      title: String,
      message: String,
      pendingID: Worktree.ID,
      previousSelection: Worktree.ID?,
      repositoryID: Repository.ID,
      name: String?,
      baseDirectory: URL
    )
    case consumeSetupScript(Worktree.ID)
    case consumeTerminalFocus(Worktree.ID)
  }

  @CasePathable
  enum WorktreeLifecycleAction: Equatable {
    case requestArchiveWorktree(Worktree.ID, Repository.ID)
    case requestArchiveWorktrees([ArchiveWorktreeTarget])
    case archiveWorktreeConfirmed(Worktree.ID, Repository.ID)
    case archiveScriptProgressUpdated(worktreeID: Worktree.ID, progress: ArchiveScriptProgress)
    case archiveScriptSucceeded(worktreeID: Worktree.ID, repositoryID: Repository.ID)
    case archiveScriptFailed(worktreeID: Worktree.ID, message: String)
    case archiveWorktreeApply(Worktree.ID, Repository.ID)
    case unarchiveWorktree(Worktree.ID)
    case requestDeleteWorktree(Worktree.ID, Repository.ID)
    case requestDeleteWorktrees([DeleteWorktreeTarget])
    case deleteWorktreePromptDeleteBranchChanged(Bool)
    case deleteWorktreePromptConfirmed
    case deleteWorktreePromptDismissed
    case deleteWorktreeConfirmed(Worktree.ID, Repository.ID, deleteBranch: Bool)
    case worktreeDeleted(
      Worktree.ID,
      repositoryID: Repository.ID,
      selectionWasRemoved: Bool,
      nextSelection: Worktree.ID?,
      forceDeleteBranchRequest: ForceDeleteBranchRequest?
    )
    case deleteWorktreeFailed(String, worktreeID: Worktree.ID)
    case forceDeleteBranchConfirmed(ForceDeleteBranchRequest)
    case forceDeleteBranchFailed(String)
  }

  @CasePathable
  enum WorktreeOrderingAction: Equatable {
    case repositoriesMoved(IndexSet, Int)
    case pinnedWorktreesMoved(repositoryID: Repository.ID, IndexSet, Int)
    case unpinnedWorktreesMoved(repositoryID: Repository.ID, IndexSet, Int)
    case pinWorktree(Worktree.ID)
    case unpinWorktree(Worktree.ID)
    case worktreeNotificationReceived(Worktree.ID)
    case setSidebarDragActive(Bool)
    case setMoveNotifiedWorktreeToTop(Bool)
  }

  @CasePathable
  enum GithubIntegrationAction: Equatable {
    case delayedPullRequestRefresh(Worktree.ID)
    case repositoryPullRequestRefreshRequested(repositoryRootURL: URL, worktreeIDs: [Worktree.ID])
    case refreshGithubIntegrationAvailability
    case githubIntegrationAvailabilityUpdated(Bool)
    case repositoryPullRequestRefreshCompleted(Repository.ID)
    case repositoryPullRequestsLoaded(
      repositoryID: Repository.ID,
      pullRequestsByWorktreeID: [Worktree.ID: GithubPullRequest?]
    )
    case setGithubIntegrationEnabled(Bool)
    case setMergedWorktreeAction(MergedWorktreeAction?)
    case pullRequestAction(Worktree.ID, PullRequestAction)
    case cacheRemoteInfo(repositoryID: Repository.ID, remoteInfo: GithubRemoteInfo)
    case pullRequestRefreshBatchOutcome(PullRequestRefreshCoordinator.Outcome)
  }

  @CasePathable
  enum RepositoryManagementAction: Equatable {
    case openRepositories([URL])
    case openRepositoriesFinished(
      [Repository],
      failures: [LoadFailure],
      invalidRoots: [String],
      openFailures: [String],
      roots: [URL]
    )
    case requestRemoveRepository(Repository.ID)
    case removeFailedRepository(Repository.ID)
    case repositoryRemoved(Repository.ID, selectionWasRemoved: Bool)
    case openRepositorySettings(Repository.ID)
  }

  @ObservableState
  struct State: Equatable {
    var repositories: IdentifiedArrayOf<Repository> = []
    var repositoryRoots: [URL] = []
    var repositoryOrderIDs: [Repository.ID] = []
    var loadFailuresByID: [Repository.ID: String] = [:]
    /// User-defined display titles indexed by `Repository.ID`. Resolved
    /// once on repo discovery (and refreshed when settings change) so
    /// hot-path display sites — sidebar, shelf spine, canvas card,
    /// toolbar notifications, settings list — read a plain dictionary
    /// instead of subscribing to `@Shared(.repositorySettings(...))`
    /// per row per frame. Absent entries fall back to `repository.name`.
    var repositoryCustomTitles: [Repository.ID: String] = [:]
    var selection: SidebarSelection?
    var worktreeInfoByID: [Worktree.ID: WorktreeInfoEntry] = [:]
    var worktreeOrderByRepository: [Repository.ID: [Worktree.ID]] = [:]
    var isOpenPanelPresented = false
    var isInitialLoadComplete = false
    var pendingWorktrees: [PendingWorktree] = []
    var pendingSetupScriptWorktreeIDs: Set<Worktree.ID> = []
    var pendingTerminalFocusWorktreeIDs: Set<Worktree.ID> = []
    var archivingWorktreeIDs: Set<Worktree.ID> = []
    var archiveScriptProgressByWorktreeID: [Worktree.ID: ArchiveScriptProgress] = [:]
    var deletingWorktreeIDs: Set<Worktree.ID> = []
    var removingRepositoryIDs: Set<Repository.ID> = []
    var pinnedWorktreeIDs: [Worktree.ID] = []
    var archivedWorktrees: [ArchivedWorktree] = []
    var archivedAutoDeletePeriod: AutoDeletePeriod?
    var mergedWorktreeAction: MergedWorktreeAction?
    var moveNotifiedWorktreeToTop = true
    var lastFocusedWorktreeID: Worktree.ID?
    var preCanvasWorktreeID: Worktree.ID?
    var preCanvasTerminalTargetID: Worktree.ID?
    var canvasReturnWorktreeID: Worktree.ID?
    var shouldCenterRestoredCanvasSoloTab = false
    var shouldFocusRestoredCanvasAtScaleOne = false
    var isShelfActive: Bool = false
    var worktreeHistoryBackStack: [Worktree.ID] = []
    var worktreeHistoryForwardStack: [Worktree.ID] = []
    /// IDs of worktrees (and plain-folder repositories) that have been
    /// "opened" at least once in this session — i.e., had their
    /// terminal state created by a user selection or CLI activation.
    /// The Shelf's book list is derived from this set so a sidebar
    /// worktree that's never been touched does not appear as a spine.
    var openedWorktreeIDs: Set<Worktree.ID> = []
    var launchRestoreMode: LaunchRestoreMode = .lastFocusedWorktree
    var shouldRestoreLastFocusedWorktree = false
    var shouldSelectFirstAfterReload = false
    var isRefreshingWorktrees = false
    var statusToast: StatusToast?
    var snapshotPersistencePhase: SnapshotPersistencePhase = .idle
    var githubIntegrationAvailability: GithubIntegrationAvailability = .unknown
    var pendingPullRequestRefreshByRepositoryID: [Repository.ID: PendingPullRequestRefresh] = [:]
    var inFlightPullRequestRefreshRepositoryIDs: Set<Repository.ID> = []
    var queuedPullRequestRefreshByRepositoryID: [Repository.ID: PendingPullRequestRefresh] = [:]
    var remoteInfoByRepositoryID: [Repository.ID: GithubRemoteInfo] = [:]
    var codeHostByRepositoryID: [Repository.ID: CodeHost] = [:]
    var sidebarSelectedWorktreeIDs: Set<Worktree.ID> = []
    @Shared(.appStorage("prowlCreatedWorktreeIDs")) var prowlCreatedWorktreeIDs: [Worktree.ID] = []
    var nextDeleteWorktreeConfirmationID = 0
    var deleteWorktreeConfirmation: DeleteWorktreeConfirmation?
    var pendingForceDeleteBranchRequests: [ForceDeleteBranchRequest] = []
    var nextPendingSidebarRevealID = 0
    var pendingSidebarReveal: PendingSidebarReveal?
    var nextPendingRenameBranchRequestID = 0
    var pendingRenameBranchRequest: PendingRenameBranchRequest?
    var isSidebarDragActive = false
    var pendingSidebarNotifyReorderIDs: [Worktree.ID] = []
    var autoShowActiveAgentsPanel = false
    var showActiveAgentTabTitles = false
    var nextCanvasFocusRequestID = 0
    var pendingCanvasFocusRequest: CanvasFocusRequest?
    var nextCanvasCommandRequestID = 0
    var pendingCanvasCommandRequest: CanvasCommandRequest?
    var activeAgents = ActiveAgentsFeature.State()
    @Shared(.appStorage("sidebarCollapsedRepositoryIDs")) var collapsedRepositoryIDs:
      [Repository.ID] = []
    @Presents var worktreeCreationPrompt: WorktreeCreationPromptFeature.State?
    @Presents var alert: AlertState<Alert>?
  }

  enum GithubIntegrationAvailability: Equatable {
    case unknown
    case checking
    case available
    case unavailable
    case disabled
  }

  struct PendingPullRequestRefresh: Equatable {
    var repositoryRootURL: URL
    var worktreeIDs: [Worktree.ID]
  }

  enum WorktreeCreationNameSource: Equatable {
    case random
    case explicit(String)
  }

  enum WorktreeCreationBaseRefSource: Equatable {
    case repositorySetting
    case explicit(String?)
  }

  enum Action {
    case worktreeCreation(WorktreeCreationAction)
    case worktreeLifecycle(WorktreeLifecycleAction)
    case worktreeOrdering(WorktreeOrderingAction)
    case githubIntegration(GithubIntegrationAction)
    case repositoryManagement(RepositoryManagementAction)
    case activeAgents(ActiveAgentsFeature.Action)
    case task
    case repositorySnapshotLoaded([Repository]?)
    case setOpenPanelPresented(Bool)
    case loadPersistedRepositories
    case pinnedWorktreeIDsLoaded([Worktree.ID])
    case archivedWorktreesLoaded([ArchivedWorktree])
    case setArchivedAutoDeletePeriod(AutoDeletePeriod?)
    case autoDeleteExpiredArchivedWorktrees
    case repositoryOrderIDsLoaded([Repository.ID])
    case worktreeOrderByRepositoryLoaded([Repository.ID: [Worktree.ID]])
    case lastFocusedWorktreeIDLoaded(Worktree.ID?)
    case refreshWorktrees
    case reloadRepositories(animated: Bool)
    case repositoriesLoaded([Repository], failures: [LoadFailure], roots: [URL], animated: Bool)
    case refreshAllCustomTitles
    case refreshCustomTitle(URL)
    case customTitlesLoaded([Repository.ID: String])
    case customTitleUpdated(Repository.ID, String?)
    case codeHostsDetected([Repository.ID: CodeHost])
    case selectArchivedWorktrees
    case selectCanvas
    case restoreCanvasOnLaunch(Worktree.ID?)
    case selectShelf
    case selectTabbed
    case selectFreestyle
    case setTopSegment(TopSegment)
    case toggleCanvas
    case toggleShelf
    case selectNextShelfBook
    case selectPreviousShelfBook
    case selectShelfBook(Int)
    case markWorktreeOpened(Worktree.ID)
    case markWorktreeClosed(Worktree.ID)
    case setSidebarSelectedWorktreeIDs(Set<Worktree.ID>)
    case selectRepository(Repository.ID?)
    case selectWorktree(Worktree.ID?, focusTerminal: Bool = false, recordHistory: Bool = true)
    case focusCanvasRepository(Repository.ID)
    case focusCanvasWorktree(Worktree.ID)
    case focusCanvasTab(worktreeID: Worktree.ID, tabID: TerminalTabID, shouldCenterInViewport: Bool = false)
    case consumeRestoredCanvasSoloTabCentering
    case consumeRestoredCanvasScaleOneFocus
    case selectNextWorktree
    case selectPreviousWorktree
    case consumeCanvasFocusRequest(Int)
    case requestCanvasCommand(CanvasCommandRequest.Command)
    case consumeCanvasCommandRequest(Int)
    case worktreeHistoryBack
    case worktreeHistoryForward
    case revealSelectedWorktreeInSidebar
    case consumePendingSidebarReveal(Int)
    case requestRenameBranchPrompt(Worktree.ID)
    case consumePendingRenameBranchRequest(Int)
    case requestRenameBranch(Worktree.ID, String)
    case presentAlert(title: String, message: String)
    case worktreeInfoEvent(WorktreeInfoWatcherClient.Event)
    case worktreeBranchNameLoaded(worktreeID: Worktree.ID, name: String)
    case worktreeLineChangesLoaded(worktreeID: Worktree.ID, added: Int, removed: Int)
    case showToast(StatusToast)
    case dismissToast
    case worktreeCreationPrompt(PresentationAction<WorktreeCreationPromptFeature.Action>)
    case alert(PresentationAction<Alert>)
    case delegate(Delegate)
  }

  struct LoadFailure: Equatable {
    let rootID: Repository.ID
    let message: String
  }

  struct DeleteWorktreeTarget: Equatable {
    let worktreeID: Worktree.ID
    let repositoryID: Repository.ID
  }

  struct ArchiveWorktreeTarget: Equatable {
    let worktreeID: Worktree.ID
    let repositoryID: Repository.ID
  }

  struct ApplyRepositoriesResult {
    let didPrunePinned: Bool
    let didPruneRepositoryOrder: Bool
    let didPruneWorktreeOrder: Bool
    let didPruneArchivedWorktrees: Bool
    let didRestoreCanvasModeOnLaunch: Bool
    let restoredCanvasTerminalTarget: Worktree?
  }

  enum StatusToast: Equatable {
    case inProgress(String)
    case success(String)
    case warning(String)
  }

  enum SnapshotPersistencePhase: Equatable {
    case idle
    case restoring
    case active
  }

  enum Alert: Equatable {
    case confirmArchiveWorktree(Worktree.ID, Repository.ID)
    case confirmArchiveWorktrees([ArchiveWorktreeTarget])
    case confirmForceDeleteBranch(ForceDeleteBranchRequest)
    case confirmRemoveRepository(Repository.ID)
  }

  enum PullRequestAction: Equatable {
    case openOnCodeHost
    case markReadyForReview
    case merge
    case close
    case copyFailingJobURL
    case copyCiFailureLogs
    case rerunFailedJobs
    case openFailingCheckDetails
  }

  @CasePathable
  enum Delegate: Equatable {
    case selectedWorktreeChanged(Worktree?)
    case repositoriesChanged(IdentifiedArrayOf<Repository>)
    case openRepositorySettings(Repository.ID)
    case worktreeCreated(Worktree)
  }

  @Dependency(TerminalClient.self) var terminalClient
  @Dependency(AnalyticsClient.self) var analyticsClient
  @Dependency(GitClientDependency.self) var gitClient
  @Dependency(GithubCLIClient.self) var githubCLI
  @Dependency(PullRequestRefreshCoordinatorClient.self) var pullRequestRefreshCoordinator
  @Dependency(GithubIntegrationClient.self) var githubIntegration
  @Dependency(OpenURLClient.self) var openURLClient
  @Dependency(RepositoryPersistenceClient.self) var repositoryPersistence
  @Dependency(ShellClient.self) var shellClient
  @Dependency(\.date.now) var now
  @Dependency(\.uuid) var uuid

  var body: some Reducer<State, Action> {
    CombineReducers {
      Reduce { state, action in
        reduceCore(state: &state, action: action)
      }

      worktreeCreationReducer
      worktreeLifecycleReducer
      worktreeOrderingReducer
      githubIntegrationReducer
      repositoryManagementReducer
      Scope(state: \.activeAgents, action: \.activeAgents) {
        ActiveAgentsFeature()
      }
    }
    .ifLet(\.$worktreeCreationPrompt, action: \.worktreeCreationPrompt) {
      WorktreeCreationPromptFeature()
    }
  }

}

// Sub-reducers are in separate files:
// - RepositoriesFeature+WorktreeCreation.swift
// - RepositoriesFeature+WorktreeLifecycle.swift
// - RepositoriesFeature+WorktreeOrdering.swift
// - RepositoriesFeature+GithubIntegration.swift
// - RepositoriesFeature+RepositoryManagement.swift
