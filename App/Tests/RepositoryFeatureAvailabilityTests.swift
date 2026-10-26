import ComposableArchitecture
import DependenciesTestSupport
import Foundation
import IdentifiedCollections
import Sharing
import Testing

@testable import Prowl

@MainActor
struct RepositoryFeatureAvailabilityTests {
  @Test func everyFeatureIsAvailableLocally() {
    let location = RepositoryLocation.local(URL(fileURLWithPath: "/tmp/repo"))

    for feature in RepositoryFeature.allCases {
      #expect(location.availability(of: feature) == .available)
    }
  }

  @Test func everyFeatureButWorktreeCreationLineCountsAndTabsIsUnavailableRemotelyWithAReason() {
    let location = RemoteRepositoryFixtures.location("/home/dev/app")

    let available: Set<RepositoryFeature> = [.worktreeCreation, .lineCounts, .terminalTab]
    for feature in RepositoryFeature.allCases where !available.contains(feature) {
      let reason = location.availability(of: feature).unavailableReason
      #expect(reason == .remoteFolder(feature))
      #expect(reason?.message.isEmpty == false)
    }
    // The remote host creates worktrees (docs-ai 084 B3d); the refresh reads line counts (B3f);
    // a remote tab runs the remote launcher (C3b).
    for feature in available {
      #expect(location.availability(of: feature) == .available)
    }
    #expect(
      location.availability(of: .profileLaunch).unavailableReason?.message
        == "Agent Profiles cannot launch in remote folders yet."
    )
  }

  @Test func remoteWorktreeHasNoDiffTarget() {
    let state = makeState(selecting: .remote)

    #expect(state.selectedDiffTargetID == nil)
    #expect(state.diffTarget(for: .worktree(remoteWorktree.id)) == nil)
  }

  @Test func remotePlainFolderHasNoDiffTargetAndIsNoWorkspaceCandidate() {
    let folder = RemoteRepositoryFixtures.plainFolder()
    var state = RepositoriesFeature.State()
    state.repositories = [folder]
    state.selection = .repository(folder.id)

    #expect(state.selectedTerminalWorktree?.id == folder.id)
    #expect(state.selectedDiffTargetID == nil)
    #expect(state.workspaceCreationCandidates.isEmpty)
  }

  @Test func localWorktreeKeepsItsDiffTarget() {
    let state = makeState(selecting: .local)

    #expect(state.selectedDiffTargetID == .worktree(localWorktree.id))
    #expect(state.diffTarget(for: .worktree(localWorktree.id)) != nil)
  }

  @Test func workspaceCandidatesLeaveOutRemoteFolders() {
    let state = makeState(selecting: .local)

    #expect(state.workspaceCreationCandidates.map(\.id) == [localRepository.id])
  }

  @Test func remoteFilesChangedReadsNoLineCounts() async {
    let store = TestStore(initialState: makeState(selecting: .remote)) {
      RepositoriesFeature()
    } withDependencies: {
      $0.gitClient.lineChanges = { _ in
        Issue.record("line counts must not be read for a remote worktree")
        return nil
      }
    }

    await store.send(.worktreeInfoEvent(.filesChanged(worktreeID: remoteWorktree.id)))
  }

  @Test(.dependencies) func iconDetectionSkipsRemoteRepositories() {
    @Shared(.settingsFile) var settingsFile
    $settingsFile.withLock { $0.global.detectRepositoryIconsAutomatically = true }

    let remote = (0..<RepositoriesFeature.maxIconDetectionsPerAdd).map {
      RemoteRepositoryFixtures.gitRepository(path: "/home/dev/app-\($0)", name: "app-\($0)")
    }

    #expect(RepositoriesFeature().iconDetectionEffects(for: remote).isEmpty)
    // Remote repositories do not use up the slots of local ones.
    #expect(RepositoriesFeature().iconDetectionEffects(for: remote + [localRepository]).count == 1)
  }

  // MARK: - Fixtures

  private enum Selection { case local, remote }

  private var remoteRepository: Repository { RemoteRepositoryFixtures.gitRepository() }

  private var remoteWorktree: Worktree { remoteRepository.worktrees[0] }

  private var localWorktree: Worktree {
    let root = URL(fileURLWithPath: "/tmp/local-app")
    return Worktree(name: "main", detail: "", location: .local(root), repositoryLocation: .local(root))
  }

  private var localRepository: Repository {
    Repository(location: .local(URL(fileURLWithPath: "/tmp/local-app")), name: "local-app", worktrees: [localWorktree])
  }

  private func makeState(selecting selection: Selection) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.repositories = [localRepository, remoteRepository]
    state.selection = .worktree(selection == .local ? localWorktree.id : remoteWorktree.id)
    return state
  }
}
