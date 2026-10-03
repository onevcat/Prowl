import ComposableArchitecture
import Foundation

/// Re-resolves the outgoing comparison from scratch: pull request base →
/// configured worktree base → automatic default branch. The diff window runs
/// this on every outgoing refresh and on mode switches, so a pull request
/// created, retargeted, or closed while the window is open moves the base
/// visibly instead of pinning the value captured at open time.
typealias OutgoingComparisonResolver = @Sendable () async throws -> GitOutgoingChangesComparison

nonisolated struct OutgoingChangesClient: Sendable {
  var open:
    @MainActor @Sendable (
      _ target: DiffTarget,
      _ resolvedKeybindings: ResolvedKeybindingMap,
      _ onError: @escaping @MainActor @Sendable (OpenActionError) -> Void
    ) async -> Void
  var makeResolver: @MainActor @Sendable (_ target: DiffTarget) -> OutgoingComparisonResolver
}

extension OutgoingChangesClient {
  /// `pullRequestInfo` reads the currently cached pull request for a diff
  /// target (a worktree or a workspace child); the app wires it to live store
  /// state so resolvers observe pull request changes that happen after the
  /// diff window was opened.
  static func live(
    pullRequestInfo: @escaping @MainActor @Sendable (DiffTargetID) -> GithubPullRequest?
  ) -> Self {
    let makeResolver: @MainActor @Sendable (DiffTarget) -> OutgoingComparisonResolver = { target in
      {
        let pullRequest = await pullRequestInfo(target.id)
        let pullRequestBase = pullRequest.map {
          GitPullRequestBase(url: $0.url, baseRefName: $0.baseRefName ?? "")
        }
        @Shared(.repositorySettings(target.repositoryRootURL)) var repositorySettings
        let gitClient = GitClient()
        let base = try await gitClient.outgoingBaseResolution(
          pullRequest: pullRequestBase,
          configuredBaseRef: repositorySettings.worktreeBaseRef,
          in: target.workingDirectory
        )
        return try await gitClient.outgoingChangesComparison(base: base, at: target.workingDirectory)
      }
    }
    return OutgoingChangesClient(
      open: { target, resolvedKeybindings, onError in
        let resolver = makeResolver(target)
        do {
          let comparison = try await resolver()
          @Shared(.settingsFile) var settingsFile
          DiffWindowManager.shared.show(
            worktreeURL: target.workingDirectory,
            branchName: target.branchName,
            comparison: .outgoing(comparison),
            outgoingResolver: resolver,
            resolvedKeybindings: resolvedKeybindings,
            colorScheme: settingsFile.global.appearanceMode.colorScheme
          )
        } catch {
          onError(
            OpenActionError(
              title: String(localized: "Unable to show outgoing changes"),
              message: error.localizedDescription
            )
          )
        }
      },
      makeResolver: makeResolver
    )
  }
}

extension OutgoingChangesClient: DependencyKey {
  static let liveValue = OutgoingChangesClient.live(pullRequestInfo: { _ in nil })

  static let testValue = OutgoingChangesClient(
    open: { _, _, _ in },
    makeResolver: { _ in { throw OutgoingBaseResolutionError.noResolvableBase } }
  )
}

extension DependencyValues {
  var outgoingChangesClient: OutgoingChangesClient {
    get { self[OutgoingChangesClient.self] }
    set { self[OutgoingChangesClient.self] = newValue }
  }
}
