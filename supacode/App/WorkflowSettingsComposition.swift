// supacode/App/WorkflowSettingsComposition.swift
// Live assembly of WorkflowSettingsClient (docs-ai 063 D1). The Settings page scans the same
// three sources with the same validation inputs the CLI's `workflow list` and the start sheet
// use, so a file's status never differs between the page, the popover, and the CLI.

import ComposableArchitecture
import Foundation

extension SupacodeApp {
  @MainActor
  static func makeWorkflowSettingsClient(
    terminalManager: WorktreeTerminalManager,
    storeBox: SupacodeAppStoreBox
  ) -> WorkflowSettingsClient {
    let userDirectory = WorkflowSources.userDirectory(home: FileManager.default.homeDirectoryForCurrentUser)
    return WorkflowSettingsClient(
      scan: {
        guard let appStore = storeBox.store else {
          throw WorkflowSettingsError(message: "Workflow settings are not available yet.")
        }
        let snapshot = makeWorkflowRuntimeSnapshot(appStore: appStore, terminalManager: terminalManager)
        func context(_ scope: WorkflowScope) -> WorkflowValidationContext {
          WorkflowValidationContext(
            scope: scope,
            bundledSkillIDs: snapshot.bundledSkillIDs,
            knownAgents: snapshot.knownAgents,
            installedAgents: snapshot.installedAgents,
            enabledProfiles: snapshot.enabledProfiles)
        }
        do {
          let entries = try WorkflowDiscovery.catalog(
            sources: WorkflowSources(bundle: snapshot.bundleWorkflowsURL, user: snapshot.userWorkflowsURL, repo: nil),
            context: context)
          let repositoriesState = appStore.state.repositories
          let repositories = try repositoriesState.repositories.map { repository in
            let directory = WorkflowSources.repoDirectory(root: repository.rootURL)
            let repoEntries = try WorkflowDiscovery.catalog(
              sources: WorkflowSources(
                bundle: snapshot.bundleWorkflowsURL, user: snapshot.userWorkflowsURL, repo: directory),
              context: context)
            return WorkflowSettingsRepositoryScan(
              repositoryID: repository.id,
              name: repositoriesState.repositoryCustomTitles[repository.id] ?? repository.name,
              rootPath: repository.rootURL.path(percentEncoded: false),
              directory: directory,
              entries: repoEntries)
          }
          return WorkflowSettingsScan(
            bundleDirectory: snapshot.bundleWorkflowsURL,
            userDirectory: snapshot.userWorkflowsURL,
            entries: entries,
            repositories: repositories)
        } catch {
          throw WorkflowSettingsError(message: "Could not read a workflow folder: \(error.localizedDescription)")
        }
      },
      createWorkflow: {
        do {
          return try WorkflowStarterTemplate.write(in: userDirectory)
        } catch {
          throw WorkflowSettingsError(message: "Could not create the workflow file: \(error.localizedDescription)")
        }
      },
      reveal: WorkflowSettingsClient.reveal,
      watch: WorkflowSettingsClient.watchDirectories
    )
  }
}
