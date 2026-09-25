import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

@MainActor
struct WorkspaceMemberEditorFeatureTests {
  private let candidate = ProjectWorkspaceCreationRepository(
    id: "/tmp/source/app",
    name: "App",
    rootURL: URL(fileURLWithPath: "/tmp/source/app")
  )

  private let mainAndFeature = [
    GitBranchRefOption(ref: "main", kind: .local),
    GitBranchRefOption(ref: "feature/login", kind: .local),
    GitBranchRefOption(ref: "origin/main", kind: .remoteTracking),
  ]

  @Test func choosingAnOpenedCandidateLoadsItsBaseRefs() async {
    let store = TestStore(initialState: .add(openedCandidates: [candidate])) {
      WorkspaceMemberEditorFeature()
    } withDependencies: {
      $0.gitClient.repoRoot = { url in url }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "main" }
      $0.gitClient.branchRefOptions = { _ in self.mainAndFeature }
    }

    await store.send(.sourceChosen(.opened)) {
      $0.sourceChoice = .opened
    }
    await store.send(.openedCandidateChosen("/tmp/source/app")) {
      $0.draft = self.candidate
      $0.isLoadingBaseRefs = true
    }
    await store.receive(\.baseRefsLoaded) {
      $0.isLoadingBaseRefs = false
      $0.draft?.baseRefOptions = self.mainAndFeature
      $0.draft?.baseRef = "main"
    }
    // Link needs no ref, so Add succeeds as-is.
    await store.send(.commitButtonTapped)
    await store.receive(\.delegate.commitAdded)
  }

  @Test func baseRefLoadFailureIsShownButKeepsTheDraft() async {
    let store = TestStore(initialState: .add(openedCandidates: [candidate])) {
      WorkspaceMemberEditorFeature()
    } withDependencies: {
      $0.gitClient.repoRoot = { url in url }
      $0.gitClient.automaticWorktreeBaseRef = { _ in nil }
      $0.gitClient.branchRefOptions = { _ in throw GitClientError.notRepository }
    }
    store.exhaustivity = .off

    await store.send(.openedCandidateChosen("/tmp/source/app"))
    await store.receive(\.baseRefsLoaded) {
      $0.isLoadingBaseRefs = false
      $0.validationMessage = "Could not read branches for App: \(GitClientError.notRepository.localizedDescription)"
    }
    #expect(store.state.draft?.baseRefOptions == [])
  }

  @Test func localFolderChoiceCreatesADraftNamedAfterTheFolder() async {
    let store = TestStore(initialState: .add(openedCandidates: [])) {
      WorkspaceMemberEditorFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.gitClient.repoRoot = { url in url }
      $0.gitClient.automaticWorktreeBaseRef = { _ in "main" }
      $0.gitClient.branchRefOptions = { _ in self.mainAndFeature }
    }
    store.exhaustivity = .off

    await store.send(.localFolderChosen("/tmp/source/api.git/"))
    #expect(store.state.draft?.id == UUID(0).uuidString)
    #expect(store.state.draft?.name == "api")
    #expect(store.state.draft?.sourceKind == .localRepository)
    #expect(store.state.draft?.checkoutMode == .link)
    await store.receive(\.baseRefsLoaded)
    #expect(store.state.draft?.baseRef == "main")
  }

  @Test func remoteURLLoadsBranchesAfterTypingPausesAndBuildsAClone() async {
    let clock = TestClock()
    let store = TestStore(initialState: .add(openedCandidates: [])) {
      WorkspaceMemberEditorFeature()
    } withDependencies: {
      $0.uuid = .incrementing
      $0.continuousClock = clock
      $0.gitClient.remoteBranchRefs = { _ in
        GitRemoteBranchRefs(
          options: [
            GitBranchRefOption(ref: "origin/develop", kind: .fetchedRemote),
            GitBranchRefOption(ref: "origin/main", kind: .fetchedRemote),
          ],
          defaultBaseRef: "origin/main"
        )
      }
    }

    await store.send(.sourceChosen(.remote)) {
      $0.sourceChoice = .remote
    }
    await store.send(.remoteURLChanged("git@github.com:onevcat/api.gi")) {
      $0.remoteURL = "git@github.com:onevcat/api.gi"
    }
    // More typing restarts the pause.
    await store.send(.remoteURLChanged("git@github.com:onevcat/api.git")) {
      $0.remoteURL = "git@github.com:onevcat/api.git"
    }
    await clock.advance(by: .milliseconds(800))
    await store.receive(\.remoteURLCommitted) {
      $0.isLoadingRemote = true
    }
    await store.receive(\.remoteRefsLoaded) {
      $0.isLoadingRemote = false
      $0.draft = ProjectWorkspaceCreationRepository(
        id: UUID(0).uuidString,
        name: "api",
        sourceKind: .remote,
        sourceLocation: "git@github.com:onevcat/api.git",
        checkoutMode: .useExistingRef,
        baseRef: "origin/main",
        baseRefOptions: [
          GitBranchRefOption(ref: "origin/develop", kind: .fetchedRemote),
          GitBranchRefOption(ref: "origin/main", kind: .fetchedRemote),
        ]
      )
    }
    await store.send(.commitButtonTapped)
    await store.receive(\.delegate.commitAdded)
  }

  @Test func remoteFailureIsReportedAndCommitStaysUnavailable() async {
    let clock = TestClock()
    let store = TestStore(initialState: .add(openedCandidates: [])) {
      WorkspaceMemberEditorFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.gitClient.remoteBranchRefs = { _ in throw GitClientError.notRepository }
    }

    await store.send(.remoteURLChanged("git@github.com:onevcat/none.git")) {
      $0.remoteURL = "git@github.com:onevcat/none.git"
    }
    await store.send(.remoteURLCommitted) {
      $0.isLoadingRemote = true
    }
    await store.receive(\.remoteRefsFailed) {
      $0.isLoadingRemote = false
      $0.remoteErrorMessage = GitClientError.notRepository.localizedDescription
    }
    #expect(!store.state.isConfiguring)
    await store.send(.commitButtonTapped)
  }

  @Test func commitValidatesTheDraftAndPointsAtTheField() async {
    var draft = candidate
    draft.baseRefOptions = mainAndFeature
    draft.baseRef = "main"
    let store = TestStore(initialState: .editAdded(draft)) {
      WorkspaceMemberEditorFeature()
    }

    await store.send(.checkoutModeChanged(.createBranch)) {
      $0.draft?.checkoutMode = .createBranch
    }
    await store.send(.commitButtonTapped) {
      $0.validationMessage = "Branch name required for App."
      $0.validationField = .branchName
    }
    await store.send(.branchNameChanged("feature/checkout")) {
      $0.draft?.branchName = "feature/checkout"
      $0.validationMessage = nil
      $0.validationField = nil
    }
    await store.send(.baseRefChanged("nope"))
    await store.send(.baseRefChanged("feature/login")) {
      $0.draft?.baseRef = "feature/login"
    }
    await store.send(.roleChanged("app")) {
      $0.draft?.role = "app"
    }
    await store.send(.commitButtonTapped)
    var expected = draft
    expected.checkoutMode = .createBranch
    expected.branchName = "feature/checkout"
    expected.baseRef = "feature/login"
    expected.role = "app"
    await store.receive(.delegate(.commitAdded(expected)))
  }

  @Test func resetLocalBranchChoiceTogglesAndClearsOnRefChange() async {
    let draft = ProjectWorkspaceCreationRepository(
      id: "bare",
      name: "Repo A",
      sourceKind: .bareRepository,
      sourceLocation: "/tmp/repo-a.git",
      checkoutMode: .useExistingRef,
      baseRef: "origin/feature",
      baseRefOptions: [
        GitBranchRefOption(ref: "origin/feature", kind: .remoteTracking),
        GitBranchRefOption(ref: "feature", kind: .local),
      ]
    )
    let store = TestStore(initialState: .editAdded(draft)) {
      WorkspaceMemberEditorFeature()
    }

    #expect(store.state.draft?.resettableLocalBranchName == "feature")
    await store.send(.resetLocalBranchChanged(true)) {
      $0.draft?.resetLocalBranchToRemote = true
    }
    // Selecting a different ref invalidates the keep/reset choice.
    await store.send(.baseRefChanged("feature")) {
      $0.draft?.baseRef = "feature"
      $0.draft?.resetLocalBranchToRemote = false
    }
  }

  @Test func remoteDraftCannotSwitchToLink() async {
    let draft = ProjectWorkspaceCreationRepository(
      id: "r", name: "api", sourceKind: .remote, sourceLocation: "git@github.com:onevcat/api.git",
      checkoutMode: .useExistingRef, baseRef: "origin/main",
      baseRefOptions: [GitBranchRefOption(ref: "origin/main", kind: .fetchedRemote)])
    let store = TestStore(initialState: .editAdded(draft)) {
      WorkspaceMemberEditorFeature()
    }

    await store.send(.checkoutModeChanged(.link))
    await store.send(.removeAddedButtonTapped)
    await store.receive(.delegate(.removeAdded("r")))
  }

  @Test func existingMemberEditGatesRemovalFlagsAndCommitsAsIs() async {
    let entry = ProjectWorkspaceRepositoryEntry(
      id: "app", name: "App", path: "app", sourceKind: .existingPath,
      sourceLocation: "/tmp/source/app", branchName: "feature/app")
    let store = TestStore(initialState: .editExisting(WorkspaceEditorExistingRepository(entry: entry))) {
      WorkspaceMemberEditorFeature()
    }

    await store.send(.existingNameChanged("Mac App")) {
      $0.existing?.name = "Mac App"
    }
    await store.send(.existingRoleChanged("app")) {
      $0.existing?.role = "app"
    }
    // Flags are ignored until the member is marked for removal.
    await store.send(.existingDeleteFilesChanged(true))
    await store.send(.existingRemovalChanged(true)) {
      $0.existing?.removal = .init()
    }
    await store.send(.existingDeleteBranchChanged(true))
    await store.send(.existingDeleteFilesChanged(true)) {
      $0.existing?.removal?.deleteFiles = true
    }
    await store.send(.existingDeleteBranchChanged(true)) {
      $0.existing?.removal?.deleteBranch = true
    }
    await store.send(.existingDeleteFilesChanged(false)) {
      $0.existing?.removal = .init(deleteFiles: false, deleteBranch: false)
    }
    await store.send(.commitButtonTapped)
    await store.receive(\.delegate.commitExisting)
    await store.send(.backButtonTapped)
    await store.receive(\.delegate.cancel)
  }
}
