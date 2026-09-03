// supacode/Domain/Workflow/WorkflowSettingsCatalog.swift
// Rows of Settings › Agents › Workflows (docs-ai 063 D1): a pure derivation over one filesystem
// scan and UserGlobalSettings, so the page shows exactly what the enabled set, the bind-mode
// overrides, and the binding memory hold — and can be tested without the disk.

import Foundation

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

    var id: String { name }
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
  let launchRoles: [LaunchRole]
  /// Set when another file wins this id: "Overridden by demo.yaml" (same source) or
  /// "Overridden in <repository>".
  let shadowNote: String?

  /// Files are unique per path even when two of them declare the same id.
  var id: String { url.path(percentEncoded: false) }
  var fileName: String { url.lastPathComponent }
  var errorCount: Int { diagnostics.errorCount }
  var warningCount: Int { diagnostics.warningCount }
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

  static func build(scan: WorkflowSettingsScan, settings: UserGlobalSettings) -> WorkflowSettingsCatalog {
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
          rows: entries.map { builder.row($0, siblings: repository.entries, repository: repository) })
      })
  }

  static func settingsKey(scope: WorkflowScope, id: String) -> String {
    WorkflowCommandHandler.disabledKey(scope: scope, id: id)
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
      let settingsKey = file.id.map { WorkflowSettingsCatalog.settingsKey(scope: file.scope, id: $0) }
      let runScope: WorkflowRunScope =
        switch file.scope {
        case .bundle: .bundle
        case .user: .user
        case .repo: .repo(repositoryID: repository?.rootPath ?? "")
        }
      let launchRoles = (definition?.roles ?? []).compactMap { role -> WorkflowSettingsRow.LaunchRole? in
        guard role.source == .launch, let requirements = role.launch, let definition else { return nil }
        let key = WorkflowBindingResolver.memoryKey(scope: runScope, workflowID: definition.id, role: role)
        let context = WorkflowBindingResolverContext(profiles: settings.agentProfiles)
        return WorkflowSettingsRow.LaunchRole(
          name: role.name,
          memoryKey: key,
          rememberedProfileID: settings.rememberedWorkflowBinding(for: key),
          candidates: settings.agentProfiles.filter(\.isEnabled).map { profile in
            WorkflowSettingsRow.Candidate(
              profileID: profile.id,
              name: profile.name,
              agentToken: profile.runtime.agent.rawValue,
              unavailableReason: WorkflowBindingResolver.rejection(
                of: profile, requirements: requirements, context: context
              )?.userFacingText(requirements: requirements))
          })
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
        launchRoles: launchRoles,
        shadowNote: shadowNote(for: entry, siblings: siblings))
    }

    /// Discovery marks the loser; the note names the winner: an earlier file in the same
    /// source (repo and user cannot cross: `prowl.*` ids are reserved, and repo rows are read
    /// from their own catalog), or the repositories whose catalogs shadow this user file.
    private func shadowNote(for entry: WorkflowCatalogEntry, siblings: [WorkflowCatalogEntry]) -> String? {
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
