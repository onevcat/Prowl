import Clocks
import Foundation
import Testing

@testable import supacode

@MainActor
struct WorktreeInfoWatcherManagerTests {
  @Test func emitsLineChangesImmediatelyOnInitialWorktreeLoad() async throws {
    let tempWorktree = try makeTempWorktree()
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600)
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([tempWorktree.worktree]))

    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: tempWorktree.worktree.id) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempWorktree.tempRoot)
  }

  @Test func worktreesAddedAfterInitialLoadRefreshLineChangesOnce() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift"])
    let firstWorktree = try #require(tempRepository.worktrees.first)
    let secondWorktree = try #require(tempRepository.worktrees.dropFirst().first)
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .milliseconds(80),
      unfocusedInterval: .milliseconds(80),
      lineChangePhaseOffset: { _, _ in .zero },
      pullRequestPhaseOffset: { _, _ in .zero },
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([firstWorktree]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: firstWorktree.id) == 1)

    manager.handleCommand(.setWorktrees([firstWorktree, secondWorktree]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 0)

    await clock.advance(by: .milliseconds(79))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 0)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 1)

    await clock.advance(by: .milliseconds(80))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func buildsWorktreeLookupWithoutTrappingOnDuplicateID() async throws {
    let tempWorktree = try makeTempWorktree()
    let duplicate = Worktree(
      id: tempWorktree.worktree.id,
      name: "eagle-duplicate",
      detail: "duplicate",
      workingDirectory: tempWorktree.worktree.workingDirectory,
      repositoryRootURL: tempWorktree.worktree.repositoryRootURL
    )
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600)
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([tempWorktree.worktree, duplicate]))

    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: tempWorktree.worktree.id) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempWorktree.tempRoot)
  }

  @Test func staggersDeferredLineChangesAcrossWorktrees() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift", "eagle"])
    let firstWorktree = try #require(tempRepository.worktrees.first)
    let secondWorktree = try #require(tempRepository.worktrees.dropFirst().first)
    let thirdWorktree = try #require(tempRepository.worktrees.dropFirst(2).first)
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .milliseconds(80),
      unfocusedInterval: .milliseconds(80),
      lineChangePhaseOffset: { worktreeID, _ in
        switch worktreeID {
        case secondWorktree.id:
          return .milliseconds(10)
        case thirdWorktree.id:
          return .milliseconds(40)
        default:
          return .zero
        }
      },
      pullRequestPhaseOffset: { _, _ in .zero },
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([firstWorktree]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: firstWorktree.id) == 1)

    manager.handleCommand(.setWorktrees([firstWorktree, secondWorktree, thirdWorktree]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 0)
    #expect(await collector.filesChangedCount(worktreeID: thirdWorktree.id) == 0)

    await clock.advance(by: .milliseconds(89))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 0)
    #expect(await collector.filesChangedCount(worktreeID: thirdWorktree.id) == 0)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 1)
    #expect(await collector.filesChangedCount(worktreeID: thirdWorktree.id) == 0)

    await clock.advance(by: .milliseconds(29))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: thirdWorktree.id) == 0)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: thirdWorktree.id) == 1)

    await clock.advance(by: .milliseconds(120))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 1)
    #expect(await collector.filesChangedCount(worktreeID: thirdWorktree.id) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func activeWorktreeRefreshesLineChangesAfterFileEventDebounce() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift"])
    let activeWorktree = try #require(tempRepository.worktrees.first)
    let inactiveWorktree = try #require(tempRepository.worktrees.dropFirst().first)
    let monitorStore = TestWorktreeFileEventMonitorStore()
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      defaultLineChangesTiming: .init(filesChangedDebounce: .seconds(3_600), eventDebounce: .milliseconds(80)),
      lineChangesSafetyRefreshInterval: .seconds(3_600),
      lineChangePhaseOffset: { _, _ in .zero },
      pullRequestPhaseOffset: { _, _ in .zero },
      worktreeFileEventMonitorFactory: monitorStore.makeMonitor,
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([activeWorktree, inactiveWorktree]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: activeWorktree.id) == 1)
    #expect(await collector.filesChangedCount(worktreeID: inactiveWorktree.id) == 1)
    #expect(monitorStore.monitor(for: activeWorktree.id) == nil)
    #expect(monitorStore.monitor(for: inactiveWorktree.id) == nil)

    manager.handleCommand(.setOpenedWorktreeIDs([activeWorktree.id]))
    let monitor = try #require(monitorStore.monitor(for: activeWorktree.id))
    #expect(monitorStore.monitor(for: inactiveWorktree.id) == nil)

    monitor.emit()
    await clock.advance(by: .milliseconds(79))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: activeWorktree.id) == 1)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: activeWorktree.id) == 2)
    #expect(await collector.filesChangedCount(worktreeID: inactiveWorktree.id) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func activeWorktreeUsesSlowSafetyLineChangesRefresh() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow"])
    let worktree = try #require(tempRepository.worktrees.first)
    let monitorStore = TestWorktreeFileEventMonitorStore()
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      lineChangesSafetyRefreshInterval: .milliseconds(80),
      lineChangePhaseOffset: { _, _ in .zero },
      pullRequestPhaseOffset: { _, _ in .zero },
      worktreeFileEventMonitorFactory: monitorStore.makeMonitor,
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([worktree]))
    manager.handleCommand(.setOpenedWorktreeIDs([worktree.id]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: worktree.id) == 1)

    await clock.advance(by: .milliseconds(79))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: worktree.id) == 1)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: worktree.id) == 2)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func repositoryRegistryEventRefreshesWorktreesAfterDebounce() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow"])
    let registryMonitorStore = TestWorktreeRegistryMonitorStore()
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      repositoryWorktreesEventDebounceInterval: .milliseconds(80),
      lineChangePhaseOffset: { _, _ in .zero },
      pullRequestPhaseOffset: { _, _ in .zero },
      worktreeRegistryMonitorFactory: registryMonitorStore.makeMonitor,
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees(tempRepository.worktrees))
    await drainAsyncEvents(120)
    #expect(await collector.repositoryWorktreesChangedCount(repositoryRootURL: tempRepository.tempRoot) == 0)

    let monitor = try #require(registryMonitorStore.monitor(for: tempRepository.tempRoot))
    monitor.emit()
    await clock.advance(by: .milliseconds(79))
    await drainAsyncEvents(120)
    #expect(await collector.repositoryWorktreesChangedCount(repositoryRootURL: tempRepository.tempRoot) == 0)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.repositoryWorktreesChangedCount(repositoryRootURL: tempRepository.tempRoot) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func repositoryRemoteConfigEventEmitsChangedEventAfterDebounce() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow"])
    let remoteConfigMonitorStore = TestRemoteConfigMonitorStore()
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      remoteConfigEventDebounceInterval: .milliseconds(80),
      lineChangePhaseOffset: { _, _ in .zero },
      pullRequestPhaseOffset: { _, _ in .zero },
      remoteConfigMonitorFactory: remoteConfigMonitorStore.makeMonitor,
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setWorktrees(tempRepository.worktrees))
    await drainAsyncEvents(120)
    #expect(await collector.repositoryRemoteConfigurationChangedCount(repositoryRootURL: tempRepository.tempRoot) == 0)

    let monitor = try #require(remoteConfigMonitorStore.monitor(for: tempRepository.tempRoot))
    monitor.emit()
    await clock.advance(by: .milliseconds(79))
    await drainAsyncEvents(120)
    #expect(await collector.repositoryRemoteConfigurationChangedCount(repositoryRootURL: tempRepository.tempRoot) == 0)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.repositoryRemoteConfigurationChangedCount(repositoryRootURL: tempRepository.tempRoot) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func removedRepositoryCancelsRegistryMonitor() async throws {
    let firstRepository = try makeTempRepository(worktreeNames: ["sparrow"])
    let secondRepository = try makeTempRepository(worktreeNames: ["swift"])
    let registryMonitorStore = TestWorktreeRegistryMonitorStore()
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      worktreeRegistryMonitorFactory: registryMonitorStore.makeMonitor
    )
    let (_, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees(firstRepository.worktrees + secondRepository.worktrees))
    await drainAsyncEvents(120)
    let removedMonitor = try #require(registryMonitorStore.monitor(for: firstRepository.tempRoot))
    #expect(!removedMonitor.isCanceled)

    manager.handleCommand(.setWorktrees(secondRepository.worktrees))
    await drainAsyncEvents(120)
    #expect(removedMonitor.isCanceled)
    #expect(registryMonitorStore.monitor(for: secondRepository.tempRoot)?.isCanceled == false)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: firstRepository.tempRoot)
    try FileManager.default.removeItem(at: secondRepository.tempRoot)
  }

  @Test func staggersPeriodicPullRequestRefreshAcrossRepositories() async throws {
    let clock = TestClock()
    let firstRepository = try makeTempRepository(worktreeNames: ["sparrow"])
    let secondRepository = try makeTempRepository(worktreeNames: ["swift"])
    let firstWorktree = try #require(firstRepository.worktrees.first)
    let secondWorktree = try #require(secondRepository.worktrees.first)
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .milliseconds(80),
      unfocusedInterval: .milliseconds(80),
      lineChangePhaseOffset: { _, _ in .zero },
      pullRequestPhaseOffset: { repositoryRootURL, _ in
        switch repositoryRootURL {
        case firstRepository.tempRoot:
          return .milliseconds(10)
        case secondRepository.tempRoot:
          return .milliseconds(40)
        default:
          return .zero
        }
      },
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setWorktrees([firstWorktree, secondWorktree]))
    await drainAsyncEvents(120)
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: firstRepository.tempRoot) == 1)
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: secondRepository.tempRoot) == 1)

    await clock.advance(by: .milliseconds(89))
    await drainAsyncEvents(120)
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: firstRepository.tempRoot) == 1)
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: secondRepository.tempRoot) == 1)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: firstRepository.tempRoot) == 2)
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: secondRepository.tempRoot) == 1)

    await clock.advance(by: .milliseconds(29))
    await drainAsyncEvents(120)
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: secondRepository.tempRoot) == 1)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: secondRepository.tempRoot) == 2)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: firstRepository.tempRoot)
    try FileManager.default.removeItem(at: secondRepository.tempRoot)
  }

  @Test func selectionRefreshUsesCooldownWithinRepository() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift"])
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      pullRequestSelectionRefreshCooldown: .milliseconds(500),
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setWorktrees(tempRepository.worktrees))
    await drainAsyncEvents()
    let baselineCount = await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot)
    #expect(baselineCount == 1)
    let firstWorktree = try #require(tempRepository.worktrees.first)
    let secondWorktree = try #require(tempRepository.worktrees.dropFirst().first)

    await clock.advance(by: .milliseconds(500))
    await drainAsyncEvents()

    // Selecting first worktree triggers immediate refresh.
    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot) == baselineCount + 1)

    // Switching to a different worktree cancels cooldown and triggers immediate refresh.
    manager.handleCommand(.setSelectedWorktreeID(secondWorktree.id))
    await drainAsyncEvents()
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot) == baselineCount + 2)

    // Switching back to first worktree also triggers immediate refresh (different worktree).
    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot) == baselineCount + 3)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func reselectingSameWorktreeRespectsCooldown() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift"])
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      pullRequestSelectionRefreshCooldown: .milliseconds(500),
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setWorktrees(tempRepository.worktrees))
    await drainAsyncEvents()
    let baselineCount = await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot)
    #expect(baselineCount == 1)
    let firstWorktree = try #require(tempRepository.worktrees.first)

    await clock.advance(by: .milliseconds(500))
    await drainAsyncEvents()

    // Selecting worktree triggers immediate refresh and starts cooldown.
    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot) == baselineCount + 1)

    // Deselect then re-select the same worktree within cooldown — should NOT refresh.
    manager.handleCommand(.setSelectedWorktreeID(nil))
    await drainAsyncEvents()
    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot) == baselineCount + 1)

    // After cooldown expires, re-selecting the same worktree should refresh.
    await clock.advance(by: .milliseconds(500))
    await drainAsyncEvents()
    manager.handleCommand(.setSelectedWorktreeID(nil))
    await drainAsyncEvents()
    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    #expect(await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot) == baselineCount + 2)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func lineChangesTimingTierSelectsCorrectTier() {
    let small = WorktreeInfoWatcherManager.LineChangesTiming.tier(forIndexEntryCount: 500)
    #expect(small == .small)

    let smallBoundary = WorktreeInfoWatcherManager.LineChangesTiming.tier(forIndexEntryCount: 4_999)
    #expect(smallBoundary == .small)

    let medium = WorktreeInfoWatcherManager.LineChangesTiming.tier(forIndexEntryCount: 5_000)
    #expect(medium == .medium)

    let mediumBoundary = WorktreeInfoWatcherManager.LineChangesTiming.tier(forIndexEntryCount: 19_999)
    #expect(mediumBoundary == .medium)

    let large = WorktreeInfoWatcherManager.LineChangesTiming.tier(forIndexEntryCount: 20_000)
    #expect(large == .large)

    let veryLarge = WorktreeInfoWatcherManager.LineChangesTiming.tier(forIndexEntryCount: 100_000)
    #expect(veryLarge == .large)
  }

  @Test func largeRepoUsesLongerEventDebounce() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow"])
    let worktree = try #require(tempRepository.worktrees.first)
    let monitorStore = TestWorktreeFileEventMonitorStore()
    let largeTiming = WorktreeInfoWatcherManager.LineChangesTiming.large
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      defaultLineChangesTiming: largeTiming,
      lineChangesSafetyRefreshInterval: .seconds(3_600),
      lineChangePhaseOffset: { _, _ in .zero },
      pullRequestPhaseOffset: { _, _ in .zero },
      worktreeFileEventMonitorFactory: monitorStore.makeMonitor,
      indexEntryCountProvider: { _ in nil },
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([worktree]))
    manager.handleCommand(.setOpenedWorktreeIDs([worktree.id]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: worktree.id) == 1)

    let monitor = try #require(monitorStore.monitor(for: worktree.id))
    monitor.emit()

    await clock.advance(by: largeTiming.eventDebounce - .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: worktree.id) == 1)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: worktree.id) == 2)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func plainRepositoryMonitorFailuresDoNotSkipRemainingRoots() {
    let roots = (0..<3).map { index in
      URL(fileURLWithPath: "/tmp/plain-repository-\(index)", isDirectory: true)
    }
    let monitorStore = TestPlainRepositoryFileEventMonitorStore(failedRoots: Set(roots))
    let manager = WorktreeInfoWatcherManager(
      plainRepositoryFileEventMonitorFactory: monitorStore.makeMonitor
    )

    manager.handleCommand(.setPlainRepositoryRoots(roots))

    #expect(Set(monitorStore.attemptedRoots) == Set(roots.map(\.standardizedFileURL)))
    manager.handleCommand(.stop)
  }

  @Test func plainRepositoryMonitorsTrackRootChangesAndStop() throws {
    let firstRoot = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let secondRoot = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let monitorStore = TestPlainRepositoryFileEventMonitorStore()
    let manager = WorktreeInfoWatcherManager(
      plainRepositoryFileEventMonitorFactory: monitorStore.makeMonitor
    )

    manager.handleCommand(.setPlainRepositoryRoots([firstRoot, secondRoot]))
    let firstMonitor = try #require(monitorStore.monitor(for: firstRoot))
    let secondMonitor = try #require(monitorStore.monitor(for: secondRoot))

    manager.handleCommand(.setPlainRepositoryRoots([secondRoot]))
    #expect(firstMonitor.isCanceled)
    #expect(!secondMonitor.isCanceled)

    manager.handleCommand(.stop)
    #expect(secondMonitor.isCanceled)
  }

  @Test func plainRepositoryGitEventEmitsOnceUntilDotGitDisappears() async throws {
    let clock = TestClock()
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let dotGitURL = root.appending(path: ".git", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: dotGitURL, withIntermediateDirectories: true)
    let monitorStore = TestPlainRepositoryFileEventMonitorStore()
    let manager = WorktreeInfoWatcherManager(
      plainRepositoryFileEventMonitorFactory: monitorStore.makeMonitor,
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPlainRepositoryRoots([root]))
    let monitor = try #require(monitorStore.monitor(for: root))

    monitor.emit()
    await drainAsyncEvents()
    await clock.advance(by: .seconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.plainRepositoryGitEventCount(rootURL: root) == 1)

    monitor.emit()
    await drainAsyncEvents()
    await clock.advance(by: .seconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.plainRepositoryGitEventCount(rootURL: root) == 1)

    try FileManager.default.removeItem(at: dotGitURL)
    monitor.emit()
    await drainAsyncEvents()
    await clock.advance(by: .seconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.plainRepositoryGitEventCount(rootURL: root) == 1)

    try FileManager.default.createDirectory(at: dotGitURL, withIntermediateDirectories: true)
    monitor.emit()
    await drainAsyncEvents()
    await clock.advance(by: .seconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.plainRepositoryGitEventCount(rootURL: root) == 2)

    manager.handleCommand(.stop)
    await task.value
  }

  @Test func adaptiveTimingResolvesFromIndexEntryCount() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow"])
    let worktree = try #require(tempRepository.worktrees.first)
    let monitorStore = TestWorktreeFileEventMonitorStore()
    let mediumTiming = WorktreeInfoWatcherManager.LineChangesTiming.medium
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      lineChangesSafetyRefreshInterval: .seconds(3_600),
      lineChangePhaseOffset: { _, _ in .zero },
      pullRequestPhaseOffset: { _, _ in .zero },
      worktreeFileEventMonitorFactory: monitorStore.makeMonitor,
      indexEntryCountProvider: { _ in 10_000 },
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([worktree]))
    manager.handleCommand(.setOpenedWorktreeIDs([worktree.id]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: worktree.id) == 1)

    let monitor = try #require(monitorStore.monitor(for: worktree.id))
    monitor.emit()

    await clock.advance(by: mediumTiming.eventDebounce - .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: worktree.id) == 1)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: worktree.id) == 2)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func canceledSelectionCooldownDoesNotClearReplacementCooldown() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift"])
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      pullRequestSelectionRefreshCooldown: .milliseconds(500),
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setWorktrees(tempRepository.worktrees))
    await drainAsyncEvents()
    let baselineCount = await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot)
    #expect(baselineCount == 1)

    let firstWorktree = try #require(tempRepository.worktrees.first)
    let secondWorktree = try #require(tempRepository.worktrees.dropFirst().first)

    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    let afterFirstSelectionCount = await collector.pullRequestRefreshCount(
      repositoryRootURL: tempRepository.tempRoot
    )
    #expect(afterFirstSelectionCount == baselineCount + 1)

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setPullRequestTrackingEnabled(true))
    manager.handleCommand(.setSelectedWorktreeID(secondWorktree.id))
    await drainAsyncEvents()
    let afterReplacementCooldownCount = await collector.pullRequestRefreshCount(
      repositoryRootURL: tempRepository.tempRoot
    )
    #expect(afterReplacementCooldownCount == afterFirstSelectionCount + 2)

    // Switching back to first worktree triggers refresh (different worktree).
    manager.handleCommand(.setSelectedWorktreeID(firstWorktree.id))
    await drainAsyncEvents()
    #expect(
      await collector.pullRequestRefreshCount(repositoryRootURL: tempRepository.tempRoot)
        == afterReplacementCooldownCount + 1
    )

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }
  @Test func deferredWorktreeEmitsFilesChangedOnSelection() async throws {
    // Regression test: worktrees added after initial load go into deferredLineChangeIDs,
    // which previously blocked all .filesChanged events until the 5-minute safety refresh.
    // After the fix, selecting a deferred worktree calls emitLineChangesChanged which
    // clears the deferred flag and immediately emits .filesChanged.
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift"])
    let firstWorktree = try #require(tempRepository.worktrees.first)
    let secondWorktree = try #require(tempRepository.worktrees.dropFirst().first)
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      lineChangePhaseOffset: { _, _ in .zero },
      pullRequestPhaseOffset: { _, _ in .zero },
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    // Load only the first worktree initially — second will be deferred when added.
    manager.handleCommand(.setWorktrees([firstWorktree]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: firstWorktree.id) == 1)

    // Add second worktree — it goes into deferredLineChangeIDs, no filesChanged yet.
    manager.handleCommand(.setWorktrees([firstWorktree, secondWorktree]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 0)

    // Selecting the deferred worktree clears the deferred flag and emits immediately.
    manager.handleCommand(.setSelectedWorktreeID(secondWorktree.id))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

  @Test func headWatcherEventClearsDeferredLineChangesAfterFilesChangedDebounce() async throws {
    let clock = TestClock()
    let tempRepository = try makeTempRepository(worktreeNames: ["sparrow", "swift"])
    let firstWorktree = try #require(tempRepository.worktrees.first)
    let secondWorktree = try #require(tempRepository.worktrees.dropFirst().first)
    let headMonitorStore = TestWorktreeHeadEventMonitorStore()
    let manager = WorktreeInfoWatcherManager(
      focusedInterval: .seconds(3_600),
      unfocusedInterval: .seconds(3_600),
      defaultLineChangesTiming: .init(filesChangedDebounce: .milliseconds(80), eventDebounce: .seconds(3_600)),
      lineChangePhaseOffset: { _, _ in .zero },
      pullRequestPhaseOffset: { _, _ in .zero },
      worktreeHeadEventMonitorFactory: headMonitorStore.makeMonitor,
      clock: clock
    )
    let (collector, task) = startCollecting(manager.eventStream())

    manager.handleCommand(.setPullRequestTrackingEnabled(false))
    manager.handleCommand(.setWorktrees([firstWorktree]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: firstWorktree.id) == 1)

    manager.handleCommand(.setWorktrees([firstWorktree, secondWorktree]))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 0)

    let monitor = try #require(headMonitorStore.monitor(for: secondWorktree.id))
    monitor.emit(.write)
    await drainAsyncEvents(120)

    await clock.advance(by: .milliseconds(79))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 0)

    await clock.advance(by: .milliseconds(1))
    await drainAsyncEvents(120)
    #expect(await collector.filesChangedCount(worktreeID: secondWorktree.id) == 1)

    manager.handleCommand(.stop)
    await task.value
    try FileManager.default.removeItem(at: tempRepository.tempRoot)
  }

}

actor EventCollector {
  private var events: [WorktreeInfoWatcherClient.Event] = []

  func append(_ event: WorktreeInfoWatcherClient.Event) {
    events.append(event)
  }

  func filesChangedCount(worktreeID: Worktree.ID) -> Int {
    events.reduce(into: 0) { result, event in
      if case .filesChanged(let id) = event, id == worktreeID {
        result += 1
      }
    }
  }

  func pullRequestRefreshCount(repositoryRootURL: URL) -> Int {
    events.reduce(into: 0) { result, event in
      if case .repositoryPullRequestRefresh(let rootURL, _) = event, rootURL == repositoryRootURL {
        result += 1
      }
    }
  }

  func repositoryWorktreesChangedCount(repositoryRootURL: URL) -> Int {
    let expectedURL = repositoryRootURL.standardizedFileURL
    return events.reduce(into: 0) { result, event in
      if case .repositoryWorktreesChanged(let rootURL) = event,
        rootURL.standardizedFileURL == expectedURL
      {
        result += 1
      }
    }
  }

  func repositoryRemoteConfigurationChangedCount(repositoryRootURL: URL) -> Int {
    let expectedURL = repositoryRootURL.standardizedFileURL
    return events.reduce(into: 0) { result, event in
      if case .repositoryRemoteConfigurationChanged(let rootURL) = event,
        rootURL.standardizedFileURL == expectedURL
      {
        result += 1
      }
    }
  }

  func plainRepositoryGitEventCount(rootURL: URL) -> Int {
    let expectedURL = rootURL.standardizedFileURL
    return events.reduce(into: 0) { result, event in
      if case .plainRepositoryBecameGitRepository(let emittedURL) = event,
        emittedURL.standardizedFileURL == expectedURL
      {
        result += 1
      }
    }
  }
}

private struct TempWorktree {
  let worktree: Worktree
  let tempRoot: URL
  let headURL: URL
}

private struct TempRepository {
  let worktrees: [Worktree]
  let tempRoot: URL
}

private func makeTempWorktree() throws -> TempWorktree {
  let fileManager = FileManager.default
  let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
  let worktreeDirectory = tempRoot.appending(path: "wt")
  let gitDirectory = worktreeDirectory.appending(path: ".git")
  try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
  let headURL = gitDirectory.appending(path: "HEAD")
  try "ref: refs/heads/main\n".write(to: headURL, atomically: true, encoding: .utf8)
  let worktree = Worktree(
    id: worktreeDirectory.path(percentEncoded: false),
    name: "eagle",
    detail: "detail",
    workingDirectory: worktreeDirectory,
    repositoryRootURL: tempRoot
  )
  return TempWorktree(worktree: worktree, tempRoot: tempRoot, headURL: headURL)
}

private func makeTempRepository(worktreeNames: [String]) throws -> TempRepository {
  let fileManager = FileManager.default
  let tempRoot = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
  var worktrees: [Worktree] = []
  for name in worktreeNames {
    let worktreeDirectory = tempRoot.appending(path: name)
    let gitDirectory = worktreeDirectory.appending(path: ".git")
    try fileManager.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    let headURL = gitDirectory.appending(path: "HEAD")
    try "ref: refs/heads/\(name)\n".write(to: headURL, atomically: true, encoding: .utf8)
    let worktree = Worktree(
      id: worktreeDirectory.path(percentEncoded: false),
      name: name,
      detail: "detail",
      workingDirectory: worktreeDirectory,
      repositoryRootURL: tempRoot
    )
    worktrees.append(worktree)
  }
  return TempRepository(worktrees: worktrees, tempRoot: tempRoot)
}

private func startCollecting(
  _ stream: AsyncStream<WorktreeInfoWatcherClient.Event>
) -> (EventCollector, Task<Void, Never>) {
  let collector = EventCollector()
  let task = Task {
    for await event in stream {
      if Task.isCancelled {
        break
      }
      await collector.append(event)
    }
  }
  return (collector, task)
}

private func drainAsyncEvents(_ iterations: Int = 20) async {
  for _ in 0..<iterations {
    await Task.yield()
  }
}

@MainActor
private final class TestWorktreeHeadEventMonitorStore {
  private var monitors: [Worktree.ID: TestWorktreeHeadEventMonitor] = [:]

  func makeMonitor(
    worktreeID: Worktree.ID,
    headURL _: URL,
    onEvent: @escaping @MainActor @Sendable (DispatchSource.FileSystemEvent) -> Void
  ) -> WorktreeHeadEventMonitoring? {
    let monitor = TestWorktreeHeadEventMonitor(onEvent: onEvent)
    monitors[worktreeID] = monitor
    return monitor
  }

  func monitor(for worktreeID: Worktree.ID) -> TestWorktreeHeadEventMonitor? {
    monitors[worktreeID]
  }
}

@MainActor
private final class TestWorktreeHeadEventMonitor: WorktreeHeadEventMonitoring {
  private let onEvent: @MainActor @Sendable (DispatchSource.FileSystemEvent) -> Void
  private(set) var isCanceled = false

  init(onEvent: @escaping @MainActor @Sendable (DispatchSource.FileSystemEvent) -> Void) {
    self.onEvent = onEvent
  }

  func emit(_ event: DispatchSource.FileSystemEvent) {
    onEvent(event)
  }

  func cancel() {
    isCanceled = true
  }
}

@MainActor
private final class TestWorktreeFileEventMonitorStore {
  private var monitors: [Worktree.ID: TestWorktreeFileEventMonitor] = [:]

  func makeMonitor(
    worktree: Worktree,
    onEvent: @escaping @MainActor @Sendable () -> Void
  ) -> WorktreeFileEventMonitoring? {
    let monitor = TestWorktreeFileEventMonitor(onEvent: onEvent)
    monitors[worktree.id] = monitor
    return monitor
  }

  func monitor(for worktreeID: Worktree.ID) -> TestWorktreeFileEventMonitor? {
    monitors[worktreeID]
  }
}

@MainActor
private final class TestWorktreeFileEventMonitor: WorktreeFileEventMonitoring {
  private let onEvent: @MainActor @Sendable () -> Void
  private(set) var isCanceled = false

  init(onEvent: @escaping @MainActor @Sendable () -> Void) {
    self.onEvent = onEvent
  }

  func emit() {
    onEvent()
  }

  func cancel() {
    isCanceled = true
  }
}

@MainActor
private final class TestPlainRepositoryFileEventMonitorStore {
  private let failedRoots: Set<URL>
  private var monitors: [URL: TestWorktreeFileEventMonitor] = [:]
  private(set) var attemptedRoots: [URL] = []

  init(failedRoots: Set<URL> = []) {
    self.failedRoots = Set(failedRoots.map(\.standardizedFileURL))
  }

  func makeMonitor(
    rootURL: URL,
    onEvent: @escaping @MainActor @Sendable () -> Void
  ) -> WorktreeFileEventMonitoring? {
    let root = rootURL.standardizedFileURL
    attemptedRoots.append(root)
    guard !failedRoots.contains(root) else { return nil }
    let monitor = TestWorktreeFileEventMonitor(onEvent: onEvent)
    monitors[root] = monitor
    return monitor
  }

  func monitor(for rootURL: URL) -> TestWorktreeFileEventMonitor? {
    monitors[rootURL.standardizedFileURL]
  }
}

@MainActor
private final class TestWorktreeRegistryMonitorStore {
  private var monitors: [URL: TestWorktreeRegistryMonitor] = [:]

  func makeMonitor(
    repositoryRootURL: URL,
    onEvent: @escaping @MainActor @Sendable () -> Void
  ) -> WorktreeRegistryMonitoring? {
    let monitor = TestWorktreeRegistryMonitor(onEvent: onEvent)
    monitors[repositoryRootURL.standardizedFileURL] = monitor
    return monitor
  }

  func monitor(for repositoryRootURL: URL) -> TestWorktreeRegistryMonitor? {
    monitors[repositoryRootURL.standardizedFileURL]
  }
}

@MainActor
private final class TestWorktreeRegistryMonitor: WorktreeRegistryMonitoring {
  private let onEvent: @MainActor @Sendable () -> Void
  private(set) var isCanceled = false

  init(onEvent: @escaping @MainActor @Sendable () -> Void) {
    self.onEvent = onEvent
  }

  func emit() {
    onEvent()
  }

  func cancel() {
    isCanceled = true
  }
}

@MainActor
private final class TestRemoteConfigMonitorStore {
  private var monitors: [URL: TestRemoteConfigMonitor] = [:]

  func makeMonitor(
    repositoryRootURL: URL,
    onEvent: @escaping @MainActor @Sendable () -> Void
  ) -> RemoteConfigMonitoring? {
    let monitor = TestRemoteConfigMonitor(onEvent: onEvent)
    monitors[repositoryRootURL.standardizedFileURL] = monitor
    return monitor
  }

  func monitor(for repositoryRootURL: URL) -> TestRemoteConfigMonitor? {
    monitors[repositoryRootURL.standardizedFileURL]
  }
}

@MainActor
private final class TestRemoteConfigMonitor: RemoteConfigMonitoring {
  private let onEvent: @MainActor @Sendable () -> Void
  private(set) var isCanceled = false

  init(onEvent: @escaping @MainActor @Sendable () -> Void) {
    self.onEvent = onEvent
  }

  func emit() {
    onEvent()
  }

  func cancel() {
    isCanceled = true
  }
}
