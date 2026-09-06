import Dispatch
import Foundation
import ProwlCLIShared

@MainActor
final class WorktreeInfoWatcherManager {
  typealias WorktreePhaseOffset = @Sendable (Worktree.ID, Duration) -> Duration
  typealias RepositoryPhaseOffset = @Sendable (URL, Duration) -> Duration
  typealias WorktreeFileEventMonitorFactory =
    @MainActor @Sendable (
      _ worktree: Worktree,
      _ onEvent: @escaping @MainActor @Sendable () -> Void
    ) -> WorktreeFileEventMonitoring?
  typealias PlainRepositoryFileEventMonitorFactory =
    @MainActor @Sendable (
      _ rootURL: URL,
      _ onEvent: @escaping @MainActor @Sendable () -> Void
    ) -> WorktreeFileEventMonitoring?
  typealias WorktreeHeadEventMonitorFactory =
    @MainActor @Sendable (
      _ worktreeID: Worktree.ID,
      _ headURL: URL,
      _ onEvent: @escaping @MainActor @Sendable (DispatchSource.FileSystemEvent) -> Void
    ) -> WorktreeHeadEventMonitoring?
  typealias WorktreeRegistryMonitorFactory =
    @MainActor @Sendable (
      _ repositoryRootURL: URL,
      _ onEvent: @escaping @MainActor @Sendable () -> Void
    ) -> WorktreeRegistryMonitoring?
  typealias RemoteConfigMonitorFactory =
    @MainActor @Sendable (
      _ repositoryRootURL: URL,
      _ onEvent: @escaping @MainActor @Sendable () -> Void
    ) -> RemoteConfigMonitoring?

  private struct HeadWatcher {
    let headURL: URL
    let monitor: WorktreeHeadEventMonitoring
  }

  private struct RefreshTask {
    let interval: Duration
    let task: Task<Void, Never>
  }

  private struct PullRequestSelectionCooldownTask {
    let id: UUID
    let task: Task<Void, Never>
  }

  private struct RepeatingTaskRequest {
    let worktreeID: Worktree.ID
    let interval: Duration
    let initialDelay: Duration
    let immediate: Bool
    let forceReschedule: Bool
    let makeEvent: (Worktree.ID) -> WorktreeInfoWatcherClient.Event?
  }

  private struct RefreshTiming: Equatable {
    let focused: Duration
    let unfocused: Duration
  }

  struct LineChangesTiming: Equatable, Sendable {
    let filesChangedDebounce: Duration
    let eventDebounce: Duration

    static let small = LineChangesTiming(filesChangedDebounce: .seconds(1), eventDebounce: .seconds(2))
    static let medium = LineChangesTiming(filesChangedDebounce: .seconds(2), eventDebounce: .seconds(5))
    static let large = LineChangesTiming(filesChangedDebounce: .seconds(5), eventDebounce: .seconds(15))

    static func tier(forIndexEntryCount count: Int) -> LineChangesTiming {
      switch count {
      case ..<5_000: return .small
      case ..<20_000: return .medium
      default: return .large
      }
    }
  }

  typealias IndexEntryCountProvider = @Sendable (URL) -> Int?

  private let defaultLineChangesTiming: LineChangesTiming
  private let repositoryWorktreesEventDebounceInterval: Duration
  private let remoteConfigEventDebounceInterval: Duration
  private let lineChangesSafetyRefreshInterval: Duration
  private let indexEntryCountProvider: IndexEntryCountProvider
  private var repositoryLineChangesTimings: [URL: LineChangesTiming] = [:]
  private let pullRequestSelectionRefreshCooldown: Duration
  private let refreshTiming: RefreshTiming
  private let lineChangePhaseOffset: WorktreePhaseOffset
  private let pullRequestPhaseOffset: RepositoryPhaseOffset
  private let worktreeFileEventMonitorFactory: WorktreeFileEventMonitorFactory
  private let plainRepositoryFileEventMonitorFactory: PlainRepositoryFileEventMonitorFactory
  private let worktreeHeadEventMonitorFactory: WorktreeHeadEventMonitorFactory
  private let worktreeRegistryMonitorFactory: WorktreeRegistryMonitorFactory
  private let remoteConfigMonitorFactory: RemoteConfigMonitorFactory
  private let sleep: @Sendable (Duration) async throws -> Void
  private var worktrees: [Worktree.ID: Worktree] = [:]
  private var headWatchers: [Worktree.ID: HeadWatcher] = [:]
  private var worktreeFileEventMonitors: [Worktree.ID: WorktreeFileEventMonitoring] = [:]
  private var worktreeRegistryMonitors: [URL: WorktreeRegistryMonitoring] = [:]
  private var remoteConfigMonitors: [URL: RemoteConfigMonitoring] = [:]
  private var plainRepositoryMonitors: [URL: WorktreeFileEventMonitoring] = [:]
  private var plainRepositoryRootsWithGitEvent: Set<URL> = []
  private let plainRepositoryDebouncer: KeyedDebouncer<URL>
  private let branchChangedDebouncer: KeyedDebouncer<Worktree.ID>
  private let repositoryWorktreesDebouncer: KeyedDebouncer<URL>
  private let remoteConfigDebouncer: KeyedDebouncer<URL>
  private let restartDebouncer: KeyedDebouncer<Worktree.ID>
  private let lineChangesRefreshDebouncer: KeyedDebouncer<Worktree.ID>
  private var pullRequestTasks: [URL: RefreshTask] = [:]
  private var lineChangeSafetyTasks: [Worktree.ID: RefreshTask] = [:]
  private var deferredLineChangeIDs: Set<Worktree.ID> = []
  private var openedWorktreeIDs: Set<Worktree.ID> = []
  private var hasCompletedInitialWorktreeLoad = false
  private var selectedWorktreeID: Worktree.ID?
  private var pullRequestTrackingEnabled = true
  private var pullRequestSelectionCooldownTasksByRepo: [URL: PullRequestSelectionCooldownTask] = [:]
  private var lastSelectedWorktreeIDByRepo: [URL: Worktree.ID] = [:]
  private var eventContinuation: AsyncStream<WorktreeInfoWatcherClient.Event>.Continuation?

  init<C: Clock<Duration>>(
    focusedInterval: Duration = .seconds(30),
    unfocusedInterval: Duration = .seconds(60),
    defaultLineChangesTiming: LineChangesTiming = .small,
    repositoryWorktreesEventDebounceInterval: Duration = .seconds(2),
    remoteConfigEventDebounceInterval: Duration = .seconds(2),
    lineChangesSafetyRefreshInterval: Duration = .seconds(300),
    pullRequestSelectionRefreshCooldown: Duration = .seconds(5),
    lineChangePhaseOffset: @escaping WorktreePhaseOffset = WorktreeInfoWatcherManager.defaultLineChangePhaseOffset,
    pullRequestPhaseOffset: @escaping RepositoryPhaseOffset = WorktreeInfoWatcherManager.defaultPullRequestPhaseOffset,
    worktreeFileEventMonitorFactory: @escaping WorktreeFileEventMonitorFactory =
      WorktreeInfoWatcherManager.defaultWorktreeFileEventMonitorFactory,
    plainRepositoryFileEventMonitorFactory: @escaping PlainRepositoryFileEventMonitorFactory =
      WorktreeInfoWatcherManager.defaultPlainRepositoryFileEventMonitorFactory,
    worktreeHeadEventMonitorFactory: @escaping WorktreeHeadEventMonitorFactory =
      WorktreeInfoWatcherManager.defaultWorktreeHeadEventMonitorFactory,
    worktreeRegistryMonitorFactory: @escaping WorktreeRegistryMonitorFactory =
      WorktreeInfoWatcherManager.defaultWorktreeRegistryMonitorFactory,
    remoteConfigMonitorFactory: @escaping RemoteConfigMonitorFactory =
      WorktreeInfoWatcherManager.defaultRemoteConfigMonitorFactory,
    indexEntryCountProvider: @escaping IndexEntryCountProvider = { GitClient.indexEntryCount(at: $0) },
    clock: C = ContinuousClock()
  ) {
    refreshTiming = RefreshTiming(focused: focusedInterval, unfocused: unfocusedInterval)
    self.defaultLineChangesTiming = defaultLineChangesTiming
    self.repositoryWorktreesEventDebounceInterval = repositoryWorktreesEventDebounceInterval
    self.remoteConfigEventDebounceInterval = remoteConfigEventDebounceInterval
    self.lineChangesSafetyRefreshInterval = lineChangesSafetyRefreshInterval
    self.pullRequestSelectionRefreshCooldown = pullRequestSelectionRefreshCooldown
    self.lineChangePhaseOffset = lineChangePhaseOffset
    self.pullRequestPhaseOffset = pullRequestPhaseOffset
    self.worktreeFileEventMonitorFactory = worktreeFileEventMonitorFactory
    self.plainRepositoryFileEventMonitorFactory = plainRepositoryFileEventMonitorFactory
    self.worktreeHeadEventMonitorFactory = worktreeHeadEventMonitorFactory
    self.worktreeRegistryMonitorFactory = worktreeRegistryMonitorFactory
    self.remoteConfigMonitorFactory = remoteConfigMonitorFactory
    self.indexEntryCountProvider = indexEntryCountProvider
    self.sleep = { duration in
      try await clock.sleep(for: duration)
    }
    branchChangedDebouncer = KeyedDebouncer(interval: .milliseconds(200), clock: clock)
    repositoryWorktreesDebouncer = KeyedDebouncer(interval: repositoryWorktreesEventDebounceInterval, clock: clock)
    remoteConfigDebouncer = KeyedDebouncer(interval: remoteConfigEventDebounceInterval, clock: clock)
    restartDebouncer = KeyedDebouncer(interval: .seconds(5), clock: clock)
    plainRepositoryDebouncer = KeyedDebouncer(interval: .seconds(1), clock: clock)
    // Callers always pass an explicit per-worktree delay; the instance interval
    // is only a nominal default.
    lineChangesRefreshDebouncer = KeyedDebouncer(interval: defaultLineChangesTiming.eventDebounce, clock: clock)
  }

  func handleCommand(_ command: WorktreeInfoWatcherClient.Command) {
    switch command {
    case .setWorktrees(let worktrees):
      setWorktrees(worktrees)
    case .setOpenedWorktreeIDs(let worktreeIDs):
      setOpenedWorktreeIDs(worktreeIDs)
    case .setSelectedWorktreeID(let worktreeID):
      setSelectedWorktreeID(worktreeID)
    case .refreshLineChanges:
      scheduleLineChangesRefreshForAllWorktrees()
    case .setPullRequestTrackingEnabled(let isEnabled):
      setPullRequestTrackingEnabled(isEnabled)
    case .setPlainRepositoryRoots(let roots):
      setPlainRepositoryRoots(roots)
    case .stop:
      stopAll()
    }
  }

  func eventStream() -> AsyncStream<WorktreeInfoWatcherClient.Event> {
    eventContinuation?.finish()
    let (stream, continuation) = AsyncStream.makeStream(of: WorktreeInfoWatcherClient.Event.self)
    eventContinuation = continuation
    return stream
  }

  private func setWorktrees(_ worktrees: [Worktree]) {
    let isInitialWorktreeLoad = !hasCompletedInitialWorktreeLoad && self.worktrees.isEmpty && !worktrees.isEmpty
    var worktreesByID: [Worktree.ID: Worktree] = [:]
    var uniqueWorktrees: [Worktree] = []
    for worktree in worktrees where worktreesByID[worktree.id] == nil {
      worktreesByID[worktree.id] = worktree
      uniqueWorktrees.append(worktree)
    }
    let desiredIDs = Set(worktreesByID.keys)
    let currentIDs = Set(self.worktrees.keys)
    let removedIDs = currentIDs.subtracting(desiredIDs)
    for id in removedIDs {
      stopWatcher(for: id)
    }
    if !removedIDs.isEmpty {
      deferredLineChangeIDs.subtract(removedIDs)
      openedWorktreeIDs.subtract(removedIDs)
    }
    let newIDs = desiredIDs.subtracting(currentIDs)
    if !newIDs.isEmpty && !isInitialWorktreeLoad {
      deferredLineChangeIDs.formUnion(newIDs)
    }
    self.worktrees = worktreesByID
    for worktree in uniqueWorktrees {
      configureWatcher(for: worktree)
      if isInitialWorktreeLoad || !deferredLineChangeIDs.contains(worktree.id) {
        emitLineChangesChanged(worktreeID: worktree.id)
      } else if newIDs.contains(worktree.id) {
        scheduleLineChangesRefresh(worktreeID: worktree.id, delay: deferredLineChangesRefreshDelay(for: worktree))
      }
      syncLineChangesActivity(for: worktree.id)
    }
    if isInitialWorktreeLoad {
      hasCompletedInitialWorktreeLoad = true
    }
    let repositoryRoots = Set(uniqueWorktrees.map(\.repositoryRootURL))
    let normalizedRoots = Set(repositoryRoots.map { $0.standardizedFileURL })
    refreshRepositoryTimings(for: normalizedRoots)
    syncWorktreeRegistryMonitors(repositoryRoots: repositoryRoots)
    syncRemoteConfigMonitors(repositoryRoots: repositoryRoots)
    for repositoryRootURL in repositoryRoots {
      updatePullRequestSchedule(repositoryRootURL: repositoryRootURL, immediate: true)
    }
    let obsoleteRepositories = pullRequestTasks.keys.filter { !repositoryRoots.contains($0) }
    for repositoryRootURL in obsoleteRepositories {
      pullRequestTasks.removeValue(forKey: repositoryRootURL)?.task.cancel()
    }
    let obsoleteCooldownRepositories = pullRequestSelectionCooldownTasksByRepo.keys.filter {
      !repositoryRoots.contains($0)
    }
    for repositoryRootURL in obsoleteCooldownRepositories {
      cancelPullRequestSelectionCooldown(for: repositoryRootURL)
    }
    let obsoleteSelectionRepositories = lastSelectedWorktreeIDByRepo.keys.filter {
      !repositoryRoots.contains($0)
    }
    for repositoryRootURL in obsoleteSelectionRepositories {
      lastSelectedWorktreeIDByRepo.removeValue(forKey: repositoryRootURL)
    }
  }

  private func setOpenedWorktreeIDs(_ worktreeIDs: Set<Worktree.ID>) {
    let validIDs = worktreeIDs.intersection(worktrees.keys)
    guard validIDs != openedWorktreeIDs else {
      return
    }
    let affectedIDs = openedWorktreeIDs.symmetricDifference(validIDs)
    openedWorktreeIDs = validIDs
    for worktreeID in affectedIDs {
      syncLineChangesActivity(for: worktreeID)
    }
  }

  private func setSelectedWorktreeID(_ worktreeID: Worktree.ID?) {
    guard selectedWorktreeID != worktreeID else {
      return
    }
    let previousWorktreeID = selectedWorktreeID
    let previousRepository = previousWorktreeID.flatMap { worktrees[$0]?.repositoryRootURL }
    selectedWorktreeID = worktreeID
    let nextRepository = worktreeID.flatMap { worktrees[$0]?.repositoryRootURL }
    if let previousWorktreeID {
      syncLineChangesActivity(for: previousWorktreeID)
    }
    if let worktreeID {
      emitLineChangesChanged(worktreeID: worktreeID)
      syncLineChangesActivity(for: worktreeID)
    }
    // When switching to a different worktree, cancel any active cooldown so the PR refresh
    // fires immediately. Re-selecting the same worktree still respects the cooldown.
    if let previousRepository, previousRepository == nextRepository {
      handlePullRequestRefreshOnSelection(repositoryRootURL: previousRepository, worktreeID: worktreeID)
      return
    }
    if let previousRepository {
      updatePullRequestSchedule(repositoryRootURL: previousRepository, immediate: false)
    }
    if let nextRepository {
      handlePullRequestRefreshOnSelection(repositoryRootURL: nextRepository, worktreeID: worktreeID)
    }
  }

  private func configureWatcher(for worktree: Worktree) {
    guard
      let headURL = GitWorktreeHeadResolver.headURL(
        for: worktree.workingDirectory,
        fileManager: .default
      )
    else {
      stopWatcher(for: worktree.id)
      return
    }
    if let existing = headWatchers[worktree.id], existing.headURL == headURL {
      return
    }
    stopWatcher(for: worktree.id)
    startWatcher(worktreeID: worktree.id, headURL: headURL)
  }

  private func startWatcher(worktreeID: Worktree.ID, headURL: URL) {
    guard
      let monitor = worktreeHeadEventMonitorFactory(
        worktreeID, headURL,
        { [weak self] event in
          self?.handleEvent(worktreeID: worktreeID, event: event)
        })
    else {
      return
    }
    headWatchers[worktreeID] = HeadWatcher(headURL: headURL, monitor: monitor)
  }

  private func handleEvent(
    worktreeID: Worktree.ID,
    event: DispatchSource.FileSystemEvent
  ) {
    if event.contains(.delete) || event.contains(.rename) {
      stopHeadWatcher(for: worktreeID)
      scheduleRestart(worktreeID: worktreeID)
      scheduleBranchChanged(worktreeID: worktreeID)
      return
    }
    scheduleBranchChanged(worktreeID: worktreeID)
    scheduleFilesChanged(worktreeID: worktreeID)
  }

  private func scheduleBranchChanged(worktreeID: Worktree.ID) {
    branchChangedDebouncer.schedule(worktreeID) { [weak self] in
      self?.emit(.branchChanged(worktreeID: worktreeID))
    }
  }

  private func scheduleFilesChanged(worktreeID: Worktree.ID) {
    // Route through scheduleLineChangesRefresh so the scheduled task calls
    // emitLineChangesChanged (which clears deferredLineChangeIDs) instead of
    // emitting directly. Keep filesChangedDebounce for fast HEAD-change refresh.
    let delay = lineChangesTiming(for: worktreeID).filesChangedDebounce
    scheduleLineChangesRefresh(worktreeID: worktreeID, delay: delay)
  }

  private func scheduleRestart(worktreeID: Worktree.ID) {
    restartDebouncer.schedule(worktreeID) { [weak self] in
      self?.restartWatcher(worktreeID: worktreeID)
    }
  }

  private func restartWatcher(worktreeID: Worktree.ID) {
    guard headWatchers[worktreeID] == nil else {
      return
    }
    guard let worktree = worktrees[worktreeID] else {
      return
    }
    configureWatcher(for: worktree)
    scheduleBranchChanged(worktreeID: worktreeID)
  }

  private func stopHeadWatcher(for worktreeID: Worktree.ID) {
    if let watcher = headWatchers.removeValue(forKey: worktreeID) {
      watcher.monitor.cancel()
    }
  }

  private func stopWatcher(for worktreeID: Worktree.ID) {
    stopHeadWatcher(for: worktreeID)
    stopWorktreeFileEventMonitor(for: worktreeID)
    branchChangedDebouncer.cancel(worktreeID)
    restartDebouncer.cancel(worktreeID)
    lineChangeSafetyTasks.removeValue(forKey: worktreeID)?.task.cancel()
    lineChangesRefreshDebouncer.cancel(worktreeID)
  }

  private func setPlainRepositoryRoots(_ roots: [URL]) {
    let desiredRoots = Set(roots.map { $0.standardizedFileURL })
    let currentRoots = Set(plainRepositoryMonitors.keys)
    for root in currentRoots.subtracting(desiredRoots) {
      plainRepositoryMonitors[root]?.cancel()
      plainRepositoryMonitors.removeValue(forKey: root)
      plainRepositoryRootsWithGitEvent.remove(root)
      plainRepositoryDebouncer.cancel(root)
    }
    for root in desiredRoots.subtracting(currentRoots) {
      guard
        let monitor = plainRepositoryFileEventMonitorFactory(
          root,
          { [weak self] in
            self?.handlePlainRepositoryFileEvent(root)
          }
        )
      else {
        continue
      }
      plainRepositoryMonitors[root] = monitor
    }
  }

  private func handlePlainRepositoryFileEvent(_ root: URL) {
    plainRepositoryDebouncer.schedule(root) { [weak self] in
      guard let self else { return }
      let dotGitURL = root.appending(path: ".git")
      guard FileManager.default.fileExists(atPath: dotGitURL.path(percentEncoded: false)) else {
        plainRepositoryRootsWithGitEvent.remove(root)
        return
      }
      guard plainRepositoryRootsWithGitEvent.insert(root).inserted else { return }
      emit(.plainRepositoryBecameGitRepository(root))
    }
  }

  private func stopAll() {
    for watcher in headWatchers.values {
      watcher.monitor.cancel()
    }
    branchChangedDebouncer.cancelAll()
    restartDebouncer.cancelAll()
    lineChangesRefreshDebouncer.cancelAll()
    repositoryWorktreesDebouncer.cancelAll()
    remoteConfigDebouncer.cancelAll()
    for task in pullRequestTasks.values {
      task.task.cancel()
    }
    for task in lineChangeSafetyTasks.values {
      task.task.cancel()
    }
    for monitor in worktreeFileEventMonitors.values {
      monitor.cancel()
    }
    for monitor in worktreeRegistryMonitors.values {
      monitor.cancel()
    }
    for monitor in remoteConfigMonitors.values {
      monitor.cancel()
    }
    for monitor in plainRepositoryMonitors.values {
      monitor.cancel()
    }
    plainRepositoryDebouncer.cancelAll()
    headWatchers.removeAll()
    worktreeFileEventMonitors.removeAll()
    worktreeRegistryMonitors.removeAll()
    remoteConfigMonitors.removeAll()
    plainRepositoryMonitors.removeAll()
    plainRepositoryRootsWithGitEvent.removeAll()
    pullRequestTasks.removeAll()
    lineChangeSafetyTasks.removeAll()
    deferredLineChangeIDs.removeAll()
    openedWorktreeIDs.removeAll()
    hasCompletedInitialWorktreeLoad = false
    cancelAllPullRequestSelectionCooldownTasks()
    lastSelectedWorktreeIDByRepo.removeAll()
    worktrees.removeAll()
    selectedWorktreeID = nil
    pullRequestTrackingEnabled = true
    eventContinuation?.finish()
  }

  private func setPullRequestTrackingEnabled(_ enabled: Bool) {
    guard pullRequestTrackingEnabled != enabled else {
      return
    }
    pullRequestTrackingEnabled = enabled
    if enabled {
      let repositoryRoots = Set(worktrees.values.map(\.repositoryRootURL))
      for repositoryRootURL in repositoryRoots {
        updatePullRequestSchedule(repositoryRootURL: repositoryRootURL, immediate: true)
      }
      return
    }
    for task in pullRequestTasks.values {
      task.task.cancel()
    }
    pullRequestTasks.removeAll()
    cancelAllPullRequestSelectionCooldownTasks()
  }

  private func updatePullRequestSchedule(repositoryRootURL: URL, immediate: Bool) {
    guard pullRequestTrackingEnabled else {
      pullRequestTasks.removeValue(forKey: repositoryRootURL)?.task.cancel()
      return
    }
    let worktreeIDs = repositoryWorktreeIDs(for: repositoryRootURL)
    guard !worktreeIDs.isEmpty else {
      pullRequestTasks.removeValue(forKey: repositoryRootURL)?.task.cancel()
      return
    }
    let isFocused = selectedWorktreeID.map { worktreeIDs.contains($0) } ?? false
    let interval = isFocused ? refreshTiming.focused : refreshTiming.unfocused
    if let existing = pullRequestTasks[repositoryRootURL], existing.interval == interval, !immediate {
      return
    }
    pullRequestTasks[repositoryRootURL]?.task.cancel()
    if immediate {
      emitPullRequestRefresh(repositoryRootURL: repositoryRootURL)
    }
    let initialDelay = interval + pullRequestPhaseOffset(repositoryRootURL, interval)
    let sleep = self.sleep
    let task = Task { [weak self, sleep] in
      do {
        try await sleep(initialDelay)
      } catch {
        return
      }
      while !Task.isCancelled {
        await MainActor.run {
          self?.emitPullRequestRefresh(repositoryRootURL: repositoryRootURL)
        }
        do {
          try await sleep(interval)
        } catch {
          return
        }
      }
    }
    pullRequestTasks[repositoryRootURL] = RefreshTask(interval: interval, task: task)
  }

  private func repositoryWorktreeIDs(for repositoryRootURL: URL) -> [Worktree.ID] {
    worktrees
      .values
      .filter { $0.repositoryRootURL == repositoryRootURL }
      .map(\.id)
      .sorted()
  }

  private func emitPullRequestRefresh(repositoryRootURL: URL) {
    guard pullRequestTrackingEnabled else {
      return
    }
    let worktreeIDs = repositoryWorktreeIDs(for: repositoryRootURL)
    guard !worktreeIDs.isEmpty else {
      return
    }
    emit(.repositoryPullRequestRefresh(repositoryRootURL: repositoryRootURL, worktreeIDs: worktreeIDs))
  }

  private func scheduleLineChangesRefreshForAllWorktrees() {
    for worktree in worktrees.values {
      scheduleLineChangesRefresh(worktreeID: worktree.id, delay: lineChangesRefreshDelay(for: worktree))
    }
  }

  private func scheduleLineChangesRefresh(
    worktreeID: Worktree.ID,
    delay: Duration
  ) {
    guard worktrees[worktreeID] != nil else {
      return
    }
    lineChangesRefreshDebouncer.schedule(worktreeID, after: delay) { [weak self] in
      self?.emitLineChangesChanged(worktreeID: worktreeID)
    }
  }

  private func scheduleLineChangesDebouncedRefresh(worktreeID: Worktree.ID) {
    scheduleLineChangesRefresh(worktreeID: worktreeID, delay: lineChangesTiming(for: worktreeID).eventDebounce)
  }

  private func updateLineChangesSafetySchedule(worktreeID: Worktree.ID) {
    guard isLineChangesActive(worktreeID), worktrees[worktreeID] != nil else {
      lineChangeSafetyTasks.removeValue(forKey: worktreeID)?.task.cancel()
      return
    }
    let request = RepeatingTaskRequest(
      worktreeID: worktreeID,
      interval: lineChangesSafetyRefreshInterval,
      initialDelay: lineChangesSafetyRefreshInterval,
      immediate: false,
      forceReschedule: false,
      makeEvent: { [weak self] worktreeID in
        self?.makeLineChangesChangedEvent(worktreeID: worktreeID)
      }
    )
    updateRepeatingTask(request, tasks: &lineChangeSafetyTasks)
  }

  private func lineChangesRefreshDelay(for worktree: Worktree) -> Duration {
    let interval = worktree.id == selectedWorktreeID ? refreshTiming.focused : refreshTiming.unfocused
    return lineChangePhaseOffset(worktree.id, interval)
  }

  private func deferredLineChangesRefreshDelay(for worktree: Worktree) -> Duration {
    let interval = worktree.id == selectedWorktreeID ? refreshTiming.focused : refreshTiming.unfocused
    return interval + lineChangePhaseOffset(worktree.id, interval)
  }

  private func emitLineChangesChanged(worktreeID: Worktree.ID) {
    guard let event = makeLineChangesChangedEvent(worktreeID: worktreeID) else {
      return
    }
    emit(event)
  }

  private func makeLineChangesChangedEvent(worktreeID: Worktree.ID) -> WorktreeInfoWatcherClient.Event? {
    guard worktrees[worktreeID] != nil else {
      return nil
    }
    deferredLineChangeIDs.remove(worktreeID)
    return .filesChanged(worktreeID: worktreeID)
  }

  private func syncLineChangesActivity(for worktreeID: Worktree.ID) {
    guard let worktree = worktrees[worktreeID], isLineChangesActive(worktreeID) else {
      stopWorktreeFileEventMonitor(for: worktreeID)
      lineChangeSafetyTasks.removeValue(forKey: worktreeID)?.task.cancel()
      return
    }
    startWorktreeFileEventMonitorIfNeeded(for: worktree)
    updateLineChangesSafetySchedule(worktreeID: worktreeID)
  }

  private func isLineChangesActive(_ worktreeID: Worktree.ID) -> Bool {
    selectedWorktreeID == worktreeID || openedWorktreeIDs.contains(worktreeID)
  }

  private func lineChangesTiming(for worktreeID: Worktree.ID) -> LineChangesTiming {
    guard let worktree = worktrees[worktreeID] else { return defaultLineChangesTiming }
    let repoRoot = worktree.repositoryRootURL.standardizedFileURL
    return repositoryLineChangesTimings[repoRoot] ?? defaultLineChangesTiming
  }

  private func refreshRepositoryTimings(for repositoryRoots: Set<URL>) {
    let obsoleteRoots = repositoryLineChangesTimings.keys.filter { !repositoryRoots.contains($0) }
    for root in obsoleteRoots {
      repositoryLineChangesTimings.removeValue(forKey: root)
    }
    for root in repositoryRoots where repositoryLineChangesTimings[root] == nil {
      if let count = indexEntryCountProvider(root) {
        repositoryLineChangesTimings[root] = LineChangesTiming.tier(forIndexEntryCount: count)
      }
    }
  }

  private func startWorktreeFileEventMonitorIfNeeded(for worktree: Worktree) {
    guard worktreeFileEventMonitors[worktree.id] == nil else {
      return
    }
    worktreeFileEventMonitors[worktree.id] = worktreeFileEventMonitorFactory(worktree) { [weak self] in
      self?.scheduleLineChangesDebouncedRefresh(worktreeID: worktree.id)
    }
  }

  private func stopWorktreeFileEventMonitor(for worktreeID: Worktree.ID) {
    worktreeFileEventMonitors.removeValue(forKey: worktreeID)?.cancel()
  }

  private func syncWorktreeRegistryMonitors(repositoryRoots: Set<URL>) {
    let normalizedRoots = Set(repositoryRoots.map { $0.standardizedFileURL })
    let obsoleteRoots = worktreeRegistryMonitors.keys.filter { !normalizedRoots.contains($0) }
    for repositoryRootURL in obsoleteRoots {
      worktreeRegistryMonitors.removeValue(forKey: repositoryRootURL)?.cancel()
      repositoryWorktreesDebouncer.cancel(repositoryRootURL)
    }
    for repositoryRootURL in normalizedRoots where worktreeRegistryMonitors[repositoryRootURL] == nil {
      worktreeRegistryMonitors[repositoryRootURL] = worktreeRegistryMonitorFactory(repositoryRootURL) { [weak self] in
        self?.scheduleRepositoryWorktreesChanged(repositoryRootURL: repositoryRootURL)
      }
    }
  }

  private func syncRemoteConfigMonitors(repositoryRoots: Set<URL>) {
    let normalizedRoots = Set(repositoryRoots.map { $0.standardizedFileURL })
    let obsoleteRoots = remoteConfigMonitors.keys.filter { !normalizedRoots.contains($0) }
    for repositoryRootURL in obsoleteRoots {
      remoteConfigMonitors.removeValue(forKey: repositoryRootURL)?.cancel()
      remoteConfigDebouncer.cancel(repositoryRootURL)
    }
    for repositoryRootURL in normalizedRoots where remoteConfigMonitors[repositoryRootURL] == nil {
      remoteConfigMonitors[repositoryRootURL] = remoteConfigMonitorFactory(repositoryRootURL) { [weak self] in
        self?.scheduleRepositoryRemoteConfigurationChanged(repositoryRootURL: repositoryRootURL)
      }
    }
  }

  private func scheduleRepositoryWorktreesChanged(repositoryRootURL: URL) {
    let normalizedRootURL = repositoryRootURL.standardizedFileURL
    repositoryWorktreesDebouncer.schedule(normalizedRootURL) { [weak self] in
      self?.emit(.repositoryWorktreesChanged(repositoryRootURL: normalizedRootURL))
    }
  }

  private func scheduleRepositoryRemoteConfigurationChanged(repositoryRootURL: URL) {
    let normalizedRootURL = repositoryRootURL.standardizedFileURL
    remoteConfigDebouncer.schedule(normalizedRootURL) { [weak self] in
      self?.emit(.repositoryRemoteConfigurationChanged(repositoryRootURL: normalizedRootURL))
    }
  }

  private func updateRepeatingTask(
    _ request: RepeatingTaskRequest,
    tasks: inout [Worktree.ID: RefreshTask]
  ) {
    let worktreeID = request.worktreeID
    if let existing = tasks[worktreeID], existing.interval == request.interval, !request.forceReschedule {
      if request.immediate {
        if let event = request.makeEvent(worktreeID) {
          emit(event)
        }
      }
      return
    }
    tasks[worktreeID]?.task.cancel()
    if request.immediate {
      if let event = request.makeEvent(worktreeID) {
        emit(event)
      }
    }
    let sleep = self.sleep
    let task = Task { [weak self, sleep] in
      do {
        try await sleep(request.initialDelay)
      } catch {
        return
      }
      while !Task.isCancelled {
        await MainActor.run {
          guard let event = request.makeEvent(worktreeID) else {
            return
          }
          self?.emit(event)
        }
        do {
          try await sleep(request.interval)
        } catch {
          return
        }
      }
    }
    tasks[worktreeID] = RefreshTask(interval: request.interval, task: task)
  }

  nonisolated private static func defaultLineChangePhaseOffset(
    worktreeID: Worktree.ID,
    interval: Duration
  ) -> Duration {
    stablePhaseOffset(seed: worktreeID, interval: interval)
  }

  nonisolated private static func defaultPullRequestPhaseOffset(
    repositoryRootURL: URL,
    interval: Duration
  ) -> Duration {
    // PR refresh is now coalesced by PullRequestRefreshCoordinator, so emitting
    // every repo on the same tick maximises the chance of folding into a single
    // batched GraphQL query. The injectable parameter is kept so tests can still
    // stagger emits when they need to assert ordering.
    .zero
  }

  private static func defaultWorktreeFileEventMonitorFactory(
    worktree: Worktree,
    onEvent: @escaping @MainActor @Sendable () -> Void
  ) -> WorktreeFileEventMonitoring? {
    FSEventsWorktreeFileEventMonitor(rootURL: worktree.workingDirectory, onEvent: onEvent)
  }

  private static func defaultPlainRepositoryFileEventMonitorFactory(
    rootURL: URL,
    onEvent: @escaping @MainActor @Sendable () -> Void
  ) -> WorktreeFileEventMonitoring? {
    FSEventsWorktreeFileEventMonitor(rootURL: rootURL, onEvent: onEvent)
  }

  private static func defaultWorktreeHeadEventMonitorFactory(
    worktreeID _: Worktree.ID,
    headURL: URL,
    onEvent: @escaping @MainActor @Sendable (DispatchSource.FileSystemEvent) -> Void
  ) -> WorktreeHeadEventMonitoring? {
    DispatchSourceWorktreeHeadEventMonitor(headURL: headURL, onEvent: onEvent)
  }

  private static func defaultWorktreeRegistryMonitorFactory(
    repositoryRootURL: URL,
    onEvent: @escaping @MainActor @Sendable () -> Void
  ) -> WorktreeRegistryMonitoring? {
    GitWorktreeRegistryMonitor(repositoryRootURL: repositoryRootURL, onEvent: onEvent)
  }

  private static func defaultRemoteConfigMonitorFactory(
    repositoryRootURL: URL,
    onEvent: @escaping @MainActor @Sendable () -> Void
  ) -> RemoteConfigMonitoring? {
    GitRemoteConfigMonitor(repositoryRootURL: repositoryRootURL, onEvent: onEvent)
  }

  nonisolated private static func stablePhaseOffset(seed: String, interval: Duration) -> Duration {
    let intervalMilliseconds = durationMilliseconds(interval)
    guard intervalMilliseconds > 0 else {
      return .zero
    }
    let hash = stableHash(seed)
    return .milliseconds(Int64(hash % UInt64(intervalMilliseconds)))
  }

  nonisolated private static func durationMilliseconds(_ duration: Duration) -> Int64 {
    let components = duration.components
    let millisecondsFromSeconds = components.seconds * 1_000
    let millisecondsFromAttoseconds = Int64(components.attoseconds / 1_000_000_000_000_000)
    return millisecondsFromSeconds + millisecondsFromAttoseconds
  }

  nonisolated private static func stableHash(_ string: String) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in string.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return hash
  }

  private func emit(_ event: WorktreeInfoWatcherClient.Event) {
    if case .filesChanged(let worktreeID) = event,
      deferredLineChangeIDs.contains(worktreeID)
    {
      return
    }
    eventContinuation?.yield(event)
  }

  private func handlePullRequestRefreshOnSelection(
    repositoryRootURL: URL,
    worktreeID: Worktree.ID?
  ) {
    let lastWorktreeForRepo = lastSelectedWorktreeIDByRepo[repositoryRootURL]
    if lastWorktreeForRepo != worktreeID {
      cancelPullRequestSelectionCooldown(for: repositoryRootURL)
    }
    updatePullRequestSchedule(
      repositoryRootURL: repositoryRootURL,
      immediate: shouldImmediatelyRefreshPullRequests(repositoryRootURL: repositoryRootURL)
    )
    if let worktreeID {
      lastSelectedWorktreeIDByRepo[repositoryRootURL] = worktreeID
    }
  }

  private func cancelPullRequestSelectionCooldown(for repositoryRootURL: URL) {
    pullRequestSelectionCooldownTasksByRepo.removeValue(forKey: repositoryRootURL)?.task.cancel()
  }

  private func cancelAllPullRequestSelectionCooldownTasks() {
    for task in pullRequestSelectionCooldownTasksByRepo.values {
      task.task.cancel()
    }
    pullRequestSelectionCooldownTasksByRepo.removeAll()
  }

  private func shouldImmediatelyRefreshPullRequests(repositoryRootURL: URL) -> Bool {
    guard pullRequestSelectionCooldownTasksByRepo[repositoryRootURL] == nil else {
      return false
    }
    let cooldown = pullRequestSelectionRefreshCooldown
    let sleep = self.sleep
    let taskID = UUID()
    let task = Task { [weak self, sleep, taskID] in
      do {
        try await sleep(cooldown)
      } catch {
        return
      }
      await MainActor.run {
        guard
          let self,
          self.pullRequestSelectionCooldownTasksByRepo[repositoryRootURL]?.id == taskID
        else {
          return
        }
        self.pullRequestSelectionCooldownTasksByRepo.removeValue(forKey: repositoryRootURL)
      }
    }
    pullRequestSelectionCooldownTasksByRepo[repositoryRootURL] = PullRequestSelectionCooldownTask(
      id: taskID,
      task: task
    )
    return true
  }
}
