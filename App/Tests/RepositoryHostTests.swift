import ComposableArchitecture
import ConcurrencyExtras
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Testing

@testable import Prowl

@MainActor
struct RepositoryHostTests {
  @Test func localLocationsRunOnTheLocalGitClient() async throws {
    let root = URL(fileURLWithPath: "/tmp/local-app")
    let calls = LockIsolated<[String]>([])
    var git = GitClientDependency.testValue
    git.branchRefs = { url in
      calls.withValue { $0.append("branchRefs \(url.path(percentEncoded: false))") }
      return ["main"]
    }
    git.fetchRemote = { remote, url in
      calls.withValue { $0.append("fetch \(remote) \(url.path(percentEncoded: false))") }
    }
    git.branchName = { url in
      calls.withValue { $0.append("branchName \(url.path(percentEncoded: false))") }
      return "main"
    }
    let host = RepositoryHost(local: git)

    #expect(try await host.branchRefs(in: .local(root)) == ["main"])
    try await host.fetchRemote("origin", in: .local(root))
    #expect(await host.branchName(of: .local(root)) == "main")
    #expect(
      calls.value == [
        "branchRefs /tmp/local-app",
        "fetch origin /tmp/local-app",
        "branchName /tmp/local-app",
      ])
  }

  @Test func remoteLocationsNeverReachTheLocalGitClient() async {
    let host = RepositoryHost(local: Self.failingGitClient)
    let remote = RemoteRepositoryFixtures.gitRepository()
    let location = remote.location
    let worktree = remote.worktrees[0]

    await #expect(throws: RepositoryHostError.remoteUnavailable(location)) {
      try await host.worktrees(in: location)
    }
    await #expect(throws: RepositoryHostError.remoteUnavailable(location)) {
      try await host.pruneWorktrees(in: location)
    }
    await #expect(throws: RepositoryHostError.remoteUnavailable(location)) {
      try await host.fetchRemote("origin", in: location)
    }
    await #expect(throws: RepositoryHostError.remoteUnavailable(location)) {
      _ = try await host.localBranchNames(in: location)
    }
    await #expect(throws: RepositoryHostError.remoteUnavailable(location)) {
      _ = try await host.branchRefs(in: location)
    }
    await #expect(throws: RepositoryHostError.remoteUnavailable(location)) {
      _ = try await host.remoteNames(in: location)
    }
    await #expect(throws: RepositoryHostError.remoteUnavailable(location)) {
      _ = try await host.isBareRepository(location)
    }
    await #expect(throws: RepositoryHostError.remoteUnavailable(location)) {
      _ = try await host.ignoredFileCount(in: location)
    }
    await #expect(throws: RepositoryHostError.remoteUnavailable(location)) {
      _ = try await host.untrackedFileCount(in: location)
    }
    await #expect(throws: RepositoryHostError.remoteUnavailable(location)) {
      _ = try await host.deleteLocalBranch(named: "main", in: location, force: true)
    }
    await #expect(throws: RepositoryHostError.remoteUnavailable(worktree.location)) {
      _ = try await host.removeWorktree(worktree, deleteBranch: false)
    }
    await #expect(throws: RepositoryHostError.remoteUnavailable(worktree.location)) {
      try await host.renameBranch(in: worktree.location, to: "next")
    }
    #expect(await host.isValidBranchName("next", in: location) == false)
    #expect(await host.automaticWorktreeBaseRef(in: location) == nil)
    #expect(await host.branchName(of: worktree.location) == nil)
    #expect(await host.lineChanges(in: worktree.location) == nil)
    #expect(await host.repositoryWebURL(for: location) == nil)
    #expect(await host.remoteInfo(for: location) == nil)
    #expect(await host.githubRemoteInfos(for: location).isEmpty)
  }

  @Test func remoteWorktreeCreationFailsBeforeTheLocalStream() async {
    let host = RepositoryHost(local: Self.failingGitClient)
    let location = RemoteRepositoryFixtures.location("/home/dev/app")
    let request = GitWorktreeCreateRequest(
      name: "feature",
      repoRoot: URL(fileURLWithPath: "/home/dev/app"),
      baseDirectory: URL(fileURLWithPath: "/home/dev/worktrees"),
      copyFiles: .init(ignored: false, untracked: false),
      baseRef: "main"
    )

    await #expect(throws: RepositoryHostError.remoteUnavailable(location)) {
      for try await _ in host.createWorktreeStream(in: location, request) {}
    }
  }

  @Test func localWorktreeCreationRunsInTheHostRepository() async throws {
    let root = URL(fileURLWithPath: "/tmp/local-app")
    let requests = LockIsolated<[GitWorktreeCreateRequest]>([])
    var git = Self.failingGitClient
    git.createWorktreeStream = { request in
      requests.withValue { $0.append(request) }
      return AsyncThrowingStream { $0.finish() }
    }
    let request = GitWorktreeCreateRequest(
      name: "feature",
      repoRoot: URL(fileURLWithPath: "/tmp/other"),
      baseDirectory: URL(fileURLWithPath: "/tmp/worktrees"),
      copyFiles: .init(ignored: false, untracked: false),
      baseRef: "main"
    )

    for try await _ in RepositoryHost(local: git).createWorktreeStream(in: .local(root), request) {}

    #expect(requests.value.map(\.repoRoot) == [root])
  }

  @Test(.dependencies) func remoteConfigurationChangesSkipRemoteRepositories() async {
    var state = RepositoriesFeature.State()
    state.repositories = [
      RemoteRepositoryFixtures.gitRepository(),
      Repository(location: .local(URL(fileURLWithPath: "/tmp/local-app")), name: "local-app", worktrees: []),
    ]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient = Self.failingGitClient
    }

    await store.send(
      .worktreeInfoEvent(
        .repositoryRemoteConfigurationChanged(repository: .local(URL(fileURLWithPath: "/tmp/elsewhere")))))
  }

  @Test(.dependencies) func remotePullRequestRefreshIsSkippedUntilTheHostHasRemotes() async {
    let remote = RemoteRepositoryFixtures.gitRepository()
    let worktreeID = remote.worktrees[0].id
    var state = RepositoriesFeature.State()
    state.repositories = [remote]
    state.selection = .worktree(worktreeID)
    state.githubIntegrationAvailability = .unknown
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient = Self.failingGitClient
      $0.githubCLI.resolveRemoteInfo = { _ in
        Issue.record("gh repo view must not run for a remote repository")
        return nil
      }
      $0.githubCLI.retryRateLimitedRequests = {}
    }

    // No availability probe, no pending or in-flight refresh, no forced mark.
    await store.send(
      .worktreeInfoEvent(.repositoryPullRequestRefresh(repository: remote.location, worktreeIDs: [worktreeID]))
    )
    await store.receive(\.githubIntegration.repositoryPullRequestRefreshRequested)
    await store.send(.githubIntegration(.delayedPullRequestRefresh(worktreeID)))
    await store.send(.githubIntegration(.retryRateLimitedRequests))
  }

  @Test(.dependencies) func openingARemoteRepositoryOnItsCodeHostExplainsTheMissingURL() async {
    let remote = RemoteRepositoryFixtures.gitRepository()
    var state = RepositoriesFeature.State()
    state.repositories = [remote]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient = Self.failingGitClient
    }
    store.exhaustivity = .off

    await store.send(.githubIntegration(.pullRequestAction(remote.worktrees[0].id, .openOnCodeHost)))
    await store.receive(\.presentAlert)
  }

  @Test(.dependencies) func remoteRepositorySettingsLoadWithoutLocalGit() async {
    let remote = RemoteRepositoryFixtures.location("/home/dev/app")
    let store = TestStore(
      initialState: RepositorySettingsFeature.State(
        location: remote,
        repositoryKind: .git,
        settings: .default,
        userSettings: .default
      )
    ) {
      RepositorySettingsFeature()
    } withDependencies: {
      $0.gitClient = Self.failingGitClient
    }
    store.exhaustivity = .off

    await store.send(.task)
    await store.receive(\.settingsLoaded)
    await store.receive(\.branchDataLoaded) {
      $0.defaultWorktreeBaseRef = "HEAD"
      $0.branchOptions = ["HEAD"]
      $0.isBranchDataLoaded = true
    }
    await store.send(.workflowsAppeared)
    #expect(store.state.exampleWorktreePath.isEmpty)
  }

  @Test(.dependencies) func remoteRepositorySettingsKeepRemotePathsAndExplainLocalOnlyParts() async {
    let remote = RemoteRepositoryFixtures.location("/home/dev/app")
    let store = TestStore(
      initialState: RepositorySettingsFeature.State(
        location: remote,
        repositoryKind: .git,
        settings: .default,
        userSettings: .default
      )
    ) {
      RepositorySettingsFeature()
    }
    store.exhaustivity = .off
    var settings = RepositorySettings.default
    settings.worktreeBaseDirectoryPath = "~/worktrees"

    await store.send(
      .settingsLoaded(
        settings,
        .default,
        isBareRepository: false,
        globalDefaultWorktreeBaseDirectoryPath: nil,
        globalCopyIgnoredOnWorktreeCreate: false,
        globalCopyUntrackedOnWorktreeCreate: false,
        globalPullRequestMergeStrategy: .merge,
        keybindingUserOverrides: .empty
      )
    ) {
      // `~` belongs to the remote host, so the path is not expanded on this Mac.
      $0.settings.worktreeBaseDirectoryPath = "~/worktrees"
    }
    await store.send(.suggestIconTapped)
    await store.receive(\.symbolSuggestionsFailed) {
      $0.symbolSuggestions = .failed("Suggestions are not available for remote folders yet.")
    }
    await store.send(.importUserImage(URL(fileURLWithPath: "/tmp/icon.png"))) {
      $0.appearanceImportError = "Images are not available for remote folders yet."
    }
  }

  /// Without a host connection, the prompt cannot place a remote worktree.
  @Test(.dependencies) func creatingAWorktreeInARemoteRepositoryWithoutAHostExplainsWhy() async {
    let remote = RemoteRepositoryFixtures.gitRepository()
    var state = RepositoriesFeature.State()
    state.repositories = [remote]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    }

    await store.send(
      .worktreeCreation(
        .promptedWorktreeCreationDataLoaded(
          repositoryID: remote.id, baseRefOptions: [], automaticBaseRef: "", selectedBaseRef: nil,
          remoteHomeDirectory: nil))
    ) {
      $0.alert = RepositoriesFeature().messageAlert(
        title: "Unable to create worktree",
        message: "The remote host could not be reached."
      )
    }
  }

  @Test(.dependencies) func openingATerminalTabInARemoteWorktreeShowsTheReason() async {
    let remote = RemoteRepositoryFixtures.gitRepository()
    var state = RepositoriesFeature.State()
    state.repositories = [remote]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.terminalClient.send = { _ in Issue.record("no terminal command for a remote worktree") }
    }
    store.exhaustivity = .off

    await store.send(.newTerminalTab(remote.worktrees[0].id))
    await store.receive(\.showToast)
  }

  @Test(.dependencies) func remoteRepositoriesStayInTheRootListsAfterASnapshotLoad() async {
    let remote = RemoteRepositoryFixtures.gitRepository()
    let local = Repository(location: .local(URL(fileURLWithPath: "/tmp/local-app/")), name: "local-app", worktrees: [])
    var state = RepositoriesFeature.State()
    state.repositoryOrderIDs = [remote.id, local.id]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient = Self.failingGitClient
    }
    store.exhaustivity = .off

    await store.send(.repositorySnapshotLoaded([local, remote]))

    #expect(store.state.repositoryRoots == [local.location, remote.location])
    #expect(store.state.repositoryOrderIDs == [remote.id, local.id])
    #expect(store.state.orderedRepositoryIDs() == [remote.id, local.id])
  }

  @Test(.dependencies) func aRemoteEntryFailsToLoadUnderItsOwnIDAndIsNeverRewrittenAsLocal() async {
    let remote = RemoteRepositoryFixtures.location("/srv/app")
    let entries = [PersistedRepositoryEntry(path: remote.id, kind: .git)]
    let feature = withDependencies {
      $0.gitClient = Self.failingGitClient
      $0.continuousClock = TestClock()
    } operation: {
      RepositoriesFeature()
    }

    let upgraded = await feature.upgradedRepositoryEntriesIfNeeded(entries)
    let (loaded, failures) = await feature.loadRepositoriesData(entries)

    #expect(upgraded == entries)
    #expect(loaded.isEmpty)
    #expect(failures.map(\.rootID) == [remote.id])
  }

  @Test(.dependencies) func remoteBranchChangesReadNoLocalHead() async {
    let remote = RemoteRepositoryFixtures.gitRepository()
    var state = RepositoriesFeature.State()
    state.repositories = [remote]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient = Self.failingGitClient
    }

    await store.send(.worktreeInfoEvent(.branchChanged(worktreeID: remote.worktrees[0].id)))
  }

  @Test(.dependencies) func renamingARemoteBranchExplainsThatRemoteFoldersAreUnavailable() async {
    let remote = RemoteRepositoryFixtures.gitRepository()
    var state = RepositoriesFeature.State()
    state.repositories = [remote]
    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient = Self.failingGitClient
    }
    store.exhaustivity = .off

    await store.send(.requestRenameBranch(remote.worktrees[0].id, "next"))
    await store.receive(\.presentAlert) {
      $0.alert = RepositoriesFeature().messageAlert(
        title: "Unable to rename branch",
        message: "Remote folders are not available yet."
      )
    }
  }

  /// Every operation records an issue, so no test can fall through to real git.
  private static var failingGitClient: GitClientDependency {
    GitClientDependency(
      repoRoot: { url in
        recordLocalGitCall("repoRoot")
        return url
      },
      worktrees: { _ in
        recordLocalGitCall("worktrees")
        return []
      },
      pruneWorktrees: { _ in recordLocalGitCall("pruneWorktrees") },
      localBranchNames: { _ in
        recordLocalGitCall("localBranchNames")
        return []
      },
      isValidBranchName: { _, _ in
        recordLocalGitCall("isValidBranchName")
        return true
      },
      branchRefs: { _ in
        recordLocalGitCall("branchRefs")
        return []
      },
      branchRefOptions: { _ in
        recordLocalGitCall("branchRefOptions")
        return []
      },
      remoteBranchRefs: { _ in
        recordLocalGitCall("remoteBranchRefs")
        return GitRemoteBranchRefs(options: [], defaultBaseRef: nil)
      },
      defaultRemoteBranchRef: { _ in
        recordLocalGitCall("defaultRemoteBranchRef")
        return nil
      },
      automaticWorktreeBaseRef: { _ in
        recordLocalGitCall("automaticWorktreeBaseRef")
        return "main"
      },
      ignoredFileCount: { _ in
        recordLocalGitCall("ignoredFileCount")
        return 0
      },
      untrackedFileCount: { _ in
        recordLocalGitCall("untrackedFileCount")
        return 0
      },
      createWorktree: { _, _, _, _, _, _ in
        recordLocalGitCall("createWorktree")
        throw CancellationError()
      },
      createWorktreeStream: { _ in
        recordLocalGitCall("createWorktreeStream")
        return AsyncThrowingStream { $0.finish() }
      },
      removeWorktree: { _, _ in
        recordLocalGitCall("removeWorktree")
        return URL(fileURLWithPath: "/")
      },
      deleteLocalBranch: { _, _, _ in
        recordLocalGitCall("deleteLocalBranch")
        return .deleted
      },
      isBareRepository: { _ in
        recordLocalGitCall("isBareRepository")
        return false
      },
      branchName: { _ in
        recordLocalGitCall("branchName")
        return "main"
      },
      lineChanges: { _ in
        recordLocalGitCall("lineChanges")
        return nil
      },
      renameBranch: { _, _ in recordLocalGitCall("renameBranch") },
      repositoryWebURL: { _ in
        recordLocalGitCall("repositoryWebURL")
        return nil
      },
      githubRemoteInfos: { _ in
        recordLocalGitCall("githubRemoteInfos")
        return []
      },
      remoteInfo: { _ in
        recordLocalGitCall("remoteInfo")
        return nil
      },
      remoteNames: { _ in
        recordLocalGitCall("remoteNames")
        return []
      },
      fetchRemote: { _, _ in recordLocalGitCall("fetchRemote") }
    )
  }
}

nonisolated private func recordLocalGitCall(_ name: String) {
  Issue.record("local git client called: \(name)")
}
