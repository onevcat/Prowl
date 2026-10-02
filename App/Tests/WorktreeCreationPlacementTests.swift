import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

struct WorktreeCreationPlacementTests {
  // MARK: - Name validation

  @Test func emptyNameIsValid() {
    #expect(WorktreePlacementOverride.nameValidationError(nil) == nil)
    #expect(WorktreePlacementOverride.nameValidationError("") == nil)
    #expect(WorktreePlacementOverride.nameValidationError("   ") == nil)
  }

  @Test func plainNameIsValid() {
    #expect(WorktreePlacementOverride.nameValidationError("my-worktree") == nil)
  }

  @Test func slashesAreRejected() {
    #expect(WorktreePlacementOverride.nameValidationError("a/b") != nil)
    #expect(WorktreePlacementOverride.nameValidationError("a\\b") != nil)
  }

  @Test func dotSegmentsAndGitAreRejected() {
    #expect(WorktreePlacementOverride.nameValidationError(".") != nil)
    #expect(WorktreePlacementOverride.nameValidationError("..") != nil)
    #expect(WorktreePlacementOverride.nameValidationError(".git") != nil)
    #expect(WorktreePlacementOverride.nameValidationError(".GIT") != nil)
  }

  // MARK: - resolvedWorktreeDirectory

  private let defaultBase = URL(filePath: "/tmp/base", directoryHint: .isDirectory)
  private let repoRoot = URL(filePath: "/tmp/repo", directoryHint: .isDirectory)

  /// Compares paths ignoring a trailing slash. The resolved URLs use
  /// `directoryHint: .isDirectory`, so `path(percentEncoded:)` may keep a
  /// trailing slash — harmless for `wt --path` and the preview, but we don't
  /// want the assertions to depend on it.
  private func path(_ url: URL?) -> String? {
    guard let value = url?.path(percentEncoded: false) else { return nil }
    return value.count > 1 && value.hasSuffix("/") ? String(value.dropLast()) : value
  }

  @Test func noOverridesResolvesToNil() {
    let resolved = SupacodePaths.resolvedWorktreeDirectory(
      defaultBaseDirectory: defaultBase,
      repositoryRootURL: repoRoot,
      nameOverride: nil,
      pathOverride: nil,
      branchName: "feature/x"
    )
    #expect(resolved == nil)
  }

  @Test func nameOnlyOverridesLeafUnderDefaultBase() {
    let resolved = SupacodePaths.resolvedWorktreeDirectory(
      defaultBaseDirectory: defaultBase,
      repositoryRootURL: repoRoot,
      nameOverride: "custom-leaf",
      pathOverride: nil,
      branchName: "feature/x"
    )
    #expect(path(resolved) == "/tmp/base/custom-leaf")
  }

  @Test func pathOnlyOverridesParentKeepingBranchLeaf() {
    let resolved = SupacodePaths.resolvedWorktreeDirectory(
      defaultBaseDirectory: defaultBase,
      repositoryRootURL: repoRoot,
      nameOverride: nil,
      pathOverride: "/other/parent",
      branchName: "mybranch"
    )
    #expect(path(resolved) == "/other/parent/mybranch")
  }

  @Test func bothOverridesCombineParentAndLeaf() {
    let resolved = SupacodePaths.resolvedWorktreeDirectory(
      defaultBaseDirectory: defaultBase,
      repositoryRootURL: repoRoot,
      nameOverride: "leaf",
      pathOverride: "/other/parent",
      branchName: "mybranch"
    )
    #expect(path(resolved) == "/other/parent/leaf")
  }

  @Test func whitespaceOnlyOverridesResolveToNil() {
    let resolved = SupacodePaths.resolvedWorktreeDirectory(
      defaultBaseDirectory: defaultBase,
      repositoryRootURL: repoRoot,
      nameOverride: "  ",
      pathOverride: "  ",
      branchName: "feature/x"
    )
    #expect(resolved == nil)
  }

  // MARK: - previewWorktreeDirectory

  @Test func previewFallsBackToDefaultBaseAndBranchWhenEmpty() {
    let preview = SupacodePaths.previewWorktreeDirectory(
      defaultBaseDirectory: defaultBase,
      repositoryRootURL: repoRoot,
      nameOverride: "",
      pathOverride: "",
      branchName: "feature-x"
    )
    #expect(path(preview) == "/tmp/base/feature-x")
  }

  @Test func previewReflectsOverrides() {
    let preview = SupacodePaths.previewWorktreeDirectory(
      defaultBaseDirectory: defaultBase,
      repositoryRootURL: repoRoot,
      nameOverride: "leaf",
      pathOverride: "/p",
      branchName: "feature-x"
    )
    #expect(path(preview) == "/p/leaf")
  }
}

@MainActor
struct WorktreeCreationPromptPlacementTests {
  private func makeState(
    nameOverride: String = "",
    pathOverride: String = ""
  ) -> WorktreeCreationPromptFeature.State {
    WorktreeCreationPromptFeature.State(
      repositoryID: "/tmp/repo",
      repositoryRootURL: URL(filePath: "/tmp/repo", directoryHint: .isDirectory),
      repositoryName: "repo",
      automaticBaseRef: "origin/main",
      baseRefOptions: ["origin/main"],
      branchName: "feature/x",
      selectedBaseRef: nil,
      fetchRemote: false,
      defaultWorktreeBaseDirectory: "/tmp/base",
      worktreeNameOverride: nameOverride,
      worktreePathOverride: pathOverride,
      validationMessage: nil,
      randomPlaceholder: "bold-cat-042"
    )
  }

  @Test func createCarriesPlacementOverridesInSubmit() async {
    let store = TestStore(initialState: makeState(nameOverride: "leaf", pathOverride: "/parent")) {
      WorktreeCreationPromptFeature()
    }

    await store.send(.createButtonTapped)
    await store.receive(
      .delegate(
        .submit(
          repositoryID: "/tmp/repo",
          branchName: "feature/x",
          baseRef: nil,
          placement: WorktreePlacementOverride(name: "leaf", path: "/parent")
        )
      )
    )
  }

  @Test func createWithoutOverridesSubmitsEmptyPlacement() async {
    let store = TestStore(initialState: makeState()) {
      WorktreeCreationPromptFeature()
    }

    await store.send(.createButtonTapped)
    await store.receive(
      .delegate(
        .submit(
          repositoryID: "/tmp/repo",
          branchName: "feature/x",
          baseRef: nil,
          placement: WorktreePlacementOverride(name: nil, path: nil)
        )
      )
    )
  }

  @Test func invalidNameOverrideBlocksSubmit() async {
    let store = TestStore(initialState: makeState(nameOverride: "bad/leaf")) {
      WorktreeCreationPromptFeature()
    }

    await store.send(.createButtonTapped) {
      $0.validationMessage = "Worktree name can't contain slashes."
    }
    // No delegate.submit is emitted.
  }
}
