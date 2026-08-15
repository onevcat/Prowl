import ComposableArchitecture
import Observation

@MainActor
@Observable
internal final class StandardRuntime {
  internal let terminalManager: WorktreeTerminalManager
  internal let worktreeInfoWatcher: WorktreeInfoWatcherManager
  internal let pullRequestRefreshCoordinator: PullRequestRefreshCoordinator
  internal let cliSocketServer: CLISocketServer
  internal let store: StoreOf<AppFeature>
  internal let memoryWatchdog: MemoryWatchdog

  internal init(
    terminalManager: WorktreeTerminalManager,
    worktreeInfoWatcher: WorktreeInfoWatcherManager,
    pullRequestRefreshCoordinator: PullRequestRefreshCoordinator,
    cliSocketServer: CLISocketServer,
    store: StoreOf<AppFeature>,
    memoryWatchdog: MemoryWatchdog
  ) {
    self.terminalManager = terminalManager
    self.worktreeInfoWatcher = worktreeInfoWatcher
    self.pullRequestRefreshCoordinator = pullRequestRefreshCoordinator
    self.cliSocketServer = cliSocketServer
    self.store = store
    self.memoryWatchdog = memoryWatchdog
  }
}

@MainActor
@Observable
internal final class CleanRuntime {
  internal let terminalHost: CleanTerminalHost
  internal let store: StoreOf<CleanAppFeature>

  internal init(terminalHost: CleanTerminalHost, store: StoreOf<CleanAppFeature>) {
    self.terminalHost = terminalHost
    self.store = store
  }
}
