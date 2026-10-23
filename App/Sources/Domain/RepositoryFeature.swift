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
  /// Opening a terminal tab (a remote tab runs the remote launcher, docs-ai 084 C3b).
  case terminalTab
  /// Splitting a terminal pane (remote splits come with C4).
  case terminalSplit
  /// Typing a custom command into the focused pane: in a remote folder that pane may be
  /// the local shell or an authentication prompt (docs-ai 084 C3c).
  case inPlaceCommand
  /// Running a workflow: its history and role launches are rooted in a local worktree (A4a, C2).
  case workflow
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
      case .terminalSplit:
        String(localized: "Panes cannot split in remote folders yet.")
      case .inPlaceCommand:
        String(localized: "In Place commands do not run in remote folders yet.")
      case .workflow:
        String(localized: "Workflows cannot run in remote folders yet.")
      }
    }
  }
}

extension UserCustomCommandExecution {
  /// The feature that a custom command with this execution needs.
  var repositoryFeature: RepositoryFeature {
    switch self {
    case .shellScript: .terminalTab
    case .split: .terminalSplit
    case .terminalInput: .inPlaceCommand
    }
  }
}

extension OpenWorktreeAction {
  /// The feature that this action needs: Finder, or another app.
  var repositoryFeature: RepositoryFeature {
    if case .finder = self { return .finder }
    return .openInEditor
  }
}

extension RepositoryLocation {
  /// Whether `feature` works for a repository at this location. Every feature
  /// is available locally; on a remote host, worktree creation (docs-ai 084 B3d), line
  /// counts, which the refresh reads (B3f), and terminal tabs (C3b) are so far.
  func availability(of feature: RepositoryFeature) -> FeatureAvailability {
    switch self {
    case .local:
      .available
    case .remote:
      Self.remoteFeatures.contains(feature) ? .available : .unavailable(.remoteFolder(feature))
    }
  }

  private static let remoteFeatures: Set<RepositoryFeature> = [.worktreeCreation, .lineCounts, .terminalTab]
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
