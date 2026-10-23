import Foundation

/// Features whose availability depends on where a repository lives
/// (docs-ai 084 D3). The rules that depend on the repository kind stay in
/// `Repository.Capabilities`.
nonisolated enum RepositoryFeature: CaseIterable, Hashable, Sendable {
  /// The diff window, external diff tools and outgoing changes: they all open a `DiffTarget`.
  case diff
  case lineCounts
  case iconDetection
  case openInEditor
  case finder
  case workspace
  case archiveScript
  /// Launching an Agent Profile in the repository (remote launches come with 082 L1f).
  case profileLaunch
  /// Creating a worktree (remote creation runs through the remote host, B3 and later).
  case worktreeCreation
  /// Opening a terminal tab from the sidebar (remote tabs come with C3).
  case terminalTab
}

nonisolated enum FeatureAvailability: Equatable, Sendable {
  case available
  case unavailable(FeatureUnavailableReason)

  var isAvailable: Bool { self == .available }

  var unavailableReason: FeatureUnavailableReason? {
    guard case .unavailable(let reason) = self else { return nil }
    return reason
  }
}

nonisolated enum FeatureUnavailableReason: Equatable, Sendable {
  case remoteFolder(RepositoryFeature)

  /// Localized copy for tooltips and toasts. CLI and workflow errors use fixed English.
  var message: String {
    switch self {
    case .remoteFolder(let feature):
      switch feature {
      case .diff:
        String(localized: "Diffs are not available for remote folders.")
      case .lineCounts:
        String(localized: "Line counts are not available for remote folders.")
      case .iconDetection:
        String(localized: "Icon detection is not available for remote folders.")
      case .openInEditor:
        String(localized: "Opening in an app is not available for remote folders.")
      case .finder:
        String(localized: "Finder is not available for remote folders.")
      case .workspace:
        String(localized: "Workspaces cannot include remote folders.")
      case .archiveScript:
        String(localized: "Archive scripts do not run for remote folders.")
      case .profileLaunch:
        String(localized: "Agent Profiles cannot launch in remote folders yet.")
      case .worktreeCreation:
        String(localized: "Worktrees cannot be created in remote folders yet.")
      case .terminalTab:
        String(localized: "Terminals cannot open in remote folders yet.")
      }
    }
  }
}

extension RepositoryLocation {
  /// Whether `feature` works for a repository at this location. Every feature
  /// is available locally; on a remote host, only worktree creation is so far
  /// (docs-ai 084 B3d).
  func availability(of feature: RepositoryFeature) -> FeatureAvailability {
    switch self {
    case .local:
      .available
    case .remote:
      feature == .worktreeCreation ? .available : .unavailable(.remoteFolder(feature))
    }
  }
}

nonisolated extension RepositoryLocation {
  /// Whether pull request status refreshes for a repository at this location. A remote
  /// repository's GitHub remotes come from its host (docs-ai 084 B3); until then a
  /// refresh would find none, so the cadence, forced refreshes and the request skip it.
  var refreshesPullRequests: Bool {
    localURL != nil
  }
}

extension Repository {
  func availability(of feature: RepositoryFeature) -> FeatureAvailability {
    location.availability(of: feature)
  }
}

extension Worktree {
  /// The availability of the worktree's repository.
  func availability(of feature: RepositoryFeature) -> FeatureAvailability {
    repositoryLocation.availability(of: feature)
  }
}
