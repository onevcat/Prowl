// supacode/Domain/Workflow/WorkflowSettingsCatalog.swift
// Rows of Settings › Agents › Workflows (docs-ai 063 D1): a pure derivation over one filesystem
// scan and UserGlobalSettings, so the page shows exactly what the enabled set, the bind-mode
// overrides, and the binding memory hold — and can be tested without the disk.

import Foundation
import ProwlCLIShared

nonisolated struct WorkflowSettingsRepositoryContext: Equatable, Sendable {
  let repositoryID: String
  let name: String
  let rootURL: URL

  var rootPath: String { rootURL.path(percentEncoded: false) }
  var directory: URL { WorkflowSources.repoDirectory(root: rootURL) }
}

nonisolated enum WorkflowSettingsScope: Equatable, Sendable {
  case global
  case repository(WorkflowSettingsRepositoryContext)
}

/// One repository's `.prowl/workflows` as the scan found it.
nonisolated struct WorkflowSettingsRepositoryScan: Equatable, Sendable {
  let repositoryID: String
  let name: String
  /// `repositoryRootURL.path(percentEncoded: false)` — the `repo:` binding-memory scope
  /// (`WorkflowRunAdmission.runScope`).
  let rootPath: String
  let directory: URL
  /// The discovery catalog over (bundle, user, this repository). Repo rows come from its
  /// `.repo` entries; a `.user` entry marked shadowed here is overridden by this repository.
  let entries: [WorkflowCatalogEntry]
}

/// Everything one Settings scan read from disk, before settings are applied.
nonisolated struct WorkflowSettingsScan: Equatable, Sendable {
  let bundleDirectory: URL?
  let userDirectory: URL
  /// The discovery catalog over (bundle, user) alone.
  let entries: [WorkflowCatalogEntry]
  let repositories: [WorkflowSettingsRepositoryScan]

  static func empty(userDirectory: URL) -> Self {
    Self(bundleDirectory: nil, userDirectory: userDirectory, entries: [], repositories: [])
  }
}

nonisolated struct WorkflowSettingsRow: Equatable, Sendable, Identifiable {
  enum Status: Equatable, Sendable {
    case invalid(errors: Int)
    case disabled
    case superseded
    case readyWithWarnings(Int)
    case ready
  }

  struct Candidate: Equatable, Sendable, Identifiable {
    let profileID: UUID
    let name: String
    let agentToken: String
    /// nil = selectable; otherwise why the profile cannot serve the role (same rule as the sheet).
    let unavailableReason: String?

    var id: UUID { profileID }
  }

  struct LaunchRole: Equatable, Sendable, Identifiable {
    let name: String
    let memoryKey: WorkflowBindingMemoryKey
    let rememberedProfileID: UUID?
    let candidates: [Candidate]
    let placement: WorkflowPlacement
    let direction: WorkflowSplitDirection
    let background: Bool

    var id: String { name }
  }

  struct Role: Equatable, Sendable, Identifiable {
    let name: String
    let source: WorkflowRoleSource
    let launch: LaunchRole?

    var id: String { name }

    var behaviorDescription: String {
      switch source {
      case .current:
        return "Uses the pane that starts this workflow."
      case .pick:
        return "Choose an existing agent when starting."
      case .launch:
        guard let launch else { return "Prowl launches a new agent." }
        switch launch.placement {
        case .tab:
          return launch.background
            ? "Prowl launches a new agent in a background tab."
            : "Prowl launches a new agent in a new tab."
        case .split:
          let side =
            switch launch.direction {
            case .right: "right"
            case .left: "left"
            case .top: "top"
            case .down: "bottom"
            }
          let focus = launch.background ? " without changing focus" : ""
          return "Prowl launches a new agent in a split on the \(side)\(focus)."
        }
      }
    }
  }

  let scope: WorkflowScope
  let url: URL
  /// nil when the file did not parse.
  let workflowID: String?
  let name: String
  let description: String?
  let icon: String?
  let diagnostics: [WorkflowDiagnostic]
  let isValid: Bool
  /// `<scope>/<id>` — the key of `disabledWorkflowIDs` and the bind-mode override; nil
  /// without an id (nothing to toggle or bind then).
  let settingsKey: String?
  let isEnabled: Bool
  let bindModeOverride: WorkflowBindModeOverride.Mode?
  /// The `bind` every launch role declares when they agree; nil without launch roles or when mixed.
  let declaredBind: WorkflowBindMode?
  let roles: [Role]
  /// Set when another file wins this id: "Overridden by demo.yaml" (same source) or
  /// "Overridden in <repository>".
  let shadowNote: String?
  /// Set on an effective repository definition when it overrides a personal definition.
  let precedenceNote: String?

  /// Files are unique per path even when two of them declare the same id.
  var id: String { url.path(percentEncoded: false) }
  var fileName: String { url.lastPathComponent }
  var errorCount: Int { diagnostics.errorCount }
  var warningCount: Int { diagnostics.warningCount }
  var launchRoles: [LaunchRole] { roles.compactMap(\.launch) }

  var status: Status {
    if !isValid { return .invalid(errors: errorCount) }
    if shadowNote != nil { return .superseded }
    if !isEnabled { return .disabled }
    if warningCount > 0 { return .readyWithWarnings(warningCount) }
    return .ready
  }
}

nonisolated struct WorkflowSettingsRepositoryGroup: Equatable, Sendable, Identifiable {
  let repositoryID: String
  let name: String
  let directory: URL
  let rows: [WorkflowSettingsRow]

  var id: String { repositoryID }
}

nonisolated struct WorkflowSettingsCatalog: Equatable, Sendable {
  let bundleDirectory: URL?
  let userDirectory: URL
  let bundle: [WorkflowSettingsRow]
  let user: [WorkflowSettingsRow]
  /// Only repositories that hold at least one workflow file.
  let repositories: [WorkflowSettingsRepositoryGroup]

  static func empty(userDirectory: URL) -> Self {
    Self(bundleDirectory: nil, userDirectory: userDirectory, bundle: [], user: [], repositories: [])
  }

  static func build(scan: WorkflowSettingsScan, settings: UserGlobalSettings)
    -> WorkflowSettingsCatalog
  {
    let builder = Builder(scan: scan, settings: settings)
    return WorkflowSettingsCatalog(
      bundleDirectory: scan.bundleDirectory,
      userDirectory: scan.userDirectory,
      bundle: scan.entries.filter { $0.file.scope == .bundle }.map {
        builder.row($0, siblings: scan.entries, repository: nil)
      },
      user: scan.entries.filter { $0.file.scope == .user }.map {
        builder.row($0, siblings: scan.entries, repository: nil)
      },
      repositories: scan.repositories.compactMap { repository in
        let entries = repository.entries.filter { $0.file.scope == .repo }
        guard !entries.isEmpty else { return nil }
        return WorkflowSettingsRepositoryGroup(
          repositoryID: repository.repositoryID,
          name: repository.name,
          directory: repository.directory,
          rows: entries.map {
            builder.row($0, siblings: repository.entries, repository: repository)
          })
      })
  }

  static func settingsKey(
    scope: WorkflowScope,
    id: String,
    repositoryRootPath: String? = nil
  ) -> String? {
    WorkflowPreferenceKey.make(
      scope: scope,
      workflowID: id,
      repositoryRootPath: repositoryRootPath)
  }

  private struct Builder {
    let scan: WorkflowSettingsScan
    let settings: UserGlobalSettings

    func row(
      _ entry: WorkflowCatalogEntry,
      siblings: [WorkflowCatalogEntry],
      repository: WorkflowSettingsRepositoryScan?
    ) -> WorkflowSettingsRow {
      let file = entry.file
      let definition = file.definition
      let runScope: WorkflowRunScope =
        switch file.scope {
        case .bundle: .bundle
        case .user: .user
        case .repo: .repo(repositoryID: repository?.rootPath ?? "")
        }
      let settingsKey = file.id.flatMap {
        WorkflowSettingsCatalog.settingsKey(
          scope: file.scope,
          id: $0,
          repositoryRootPath: repository?.rootPath)
      }
      let launchRoles = (definition?.roles ?? []).compactMap {
        role -> WorkflowSettingsRow.LaunchRole? in
        guard role.source == .launch, let requirements = role.launch, let definition else {
          return nil
        }
        let key = WorkflowBindingResolver.memoryKey(
          scope: runScope, workflowID: definition.id, role: role)
        let context = WorkflowBindingResolverContext(profiles: settings.agentProfiles)
        let remembered = settings.rememberedWorkflowBinding(for: key)
        // Enabled profiles, each with the resolver's own rejection (the sheet's rule), plus the
        // remembered profile when it was disabled since — so the picker can say why instead of
        // presenting it as deleted.
        let listed = settings.agentProfiles.filter { $0.isEnabled || $0.id == remembered }
        return WorkflowSettingsRow.LaunchRole(
          name: role.name,
          memoryKey: key,
          rememberedProfileID: remembered,
          candidates: listed.map { profile in
            WorkflowSettingsRow.Candidate(
              profileID: profile.id,
              name: profile.name,
              agentToken: profile.runtime.agent.rawValue,
              unavailableReason: WorkflowBindingResolver.rejection(
                of: profile, requirements: requirements, context: context
              )?.userFacingText(requirements: requirements))
          },
          placement: requirements.placement,
          direction: requirements.direction,
          background: requirements.background)
      }
      let roles = (definition?.roles ?? []).map { role in
        WorkflowSettingsRow.Role(
          name: role.name,
          source: role.source,
          launch: launchRoles.first { $0.name == role.name })
      }
      let binds = Set((definition?.roles ?? []).compactMap { $0.launch?.bind })
      return WorkflowSettingsRow(
        scope: file.scope,
        url: file.url,
        workflowID: file.id,
        name: definition?.name ?? file.url.lastPathComponent,
        description: definition?.description,
        icon: definition?.icon,
        diagnostics: file.diagnostics,
        isValid: file.isValid,
        settingsKey: settingsKey,
        isEnabled: settingsKey.map { !settings.disabledWorkflowIDs.contains($0) } ?? false,
        bindModeOverride: settingsKey.flatMap { settings.workflowBindMode(for: $0) },
        declaredBind: binds.count == 1 ? binds.first : nil,
        roles: roles,
        shadowNote: shadowNote(for: entry, siblings: siblings),
        precedenceNote: precedenceNote(for: entry, siblings: siblings))
    }

    private func precedenceNote(
      for entry: WorkflowCatalogEntry,
      siblings: [WorkflowCatalogEntry]
    ) -> String? {
      guard entry.file.scope == .repo, !entry.shadowed, let id = entry.file.id else { return nil }
      guard siblings.contains(where: { $0.file.scope == .user && $0.file.id == id }) else {
        return nil
      }
      return "Overrides your personal workflow in this repository."
    }

    /// Discovery marks the loser; the note names the winner: an earlier file in the same
    /// source, or the repositories whose catalogs shadow this user file.
    private func shadowNote(for entry: WorkflowCatalogEntry, siblings: [WorkflowCatalogEntry])
      -> String?
    {
      guard let id = entry.file.id else { return nil }
      if entry.shadowed,
        let winner = siblings.first(where: { $0.file.id == id && $0.file.isValid && !$0.shadowed })
      {
        return "Overridden by \(winner.file.url.lastPathComponent)"
      }
      guard entry.file.scope != .repo else { return nil }
      let overriding = scan.repositories.filter { repository in
        repository.entries.contains { $0.file.url == entry.file.url && $0.shadowed }
      }
      guard !overriding.isEmpty else { return nil }
      return "Overridden in \(overriding.map(\.name).joined(separator: ", "))"
    }
  }
}

extension WorkflowBindingRejection {
  /// The picker footnote for a profile that cannot serve a role (start sheet and Settings).
  nonisolated func userFacingText(requirements: WorkflowLaunchRequirements) -> String {
    switch self {
    case .missing:
      return "The profile no longer exists."
    case .disabled:
      return "Disabled in Settings."
    case .agentNotAllowed:
      let allowed = (requirements.agents ?? []).joined(separator: ", ")
      return "This role needs \(allowed.isEmpty ? "another agent" : allowed)."
    case .promptUnsupported:
      return "This profile's runtime cannot take a launch prompt."
    }
  }
}
