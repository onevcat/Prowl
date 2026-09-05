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
    WorkflowSettingsClient(
      scan: { scope in
        guard let appStore = storeBox.store else {
          throw WorkflowSettingsError(message: "Workflow settings are not available yet.")
        }
        let snapshot = makeWorkflowRuntimeSnapshot(
          appStore: appStore, terminalManager: terminalManager)
        func context(_ scope: WorkflowScope) -> WorkflowValidationContext {
          WorkflowValidationContext(
            scope: scope,
            bundledSkillIDs: snapshot.bundledSkillIDs,
            knownAgents: snapshot.knownAgents,
            installedAgents: snapshot.installedAgents,
            enabledProfiles: snapshot.enabledProfiles)
        }
        do {
          switch scope {
          case .global:
            let entries = try WorkflowDiscovery.catalog(
              sources: WorkflowSources(
                bundle: snapshot.bundleWorkflowsURL,
                user: snapshot.userWorkflowsURL,
                repo: nil),
              context: context)
            return WorkflowSettingsScan(
              bundleDirectory: snapshot.bundleWorkflowsURL,
              userDirectory: snapshot.userWorkflowsURL,
              entries: entries,
              repositories: [])

          case .repository(let repository):
            let entries = try WorkflowDiscovery.catalog(
              sources: WorkflowSources(
                bundle: snapshot.bundleWorkflowsURL,
                user: snapshot.userWorkflowsURL,
                repo: repository.directory),
              context: context)
            return WorkflowSettingsScan(
              bundleDirectory: snapshot.bundleWorkflowsURL,
              userDirectory: snapshot.userWorkflowsURL,
              entries: entries.filter { $0.file.scope != .repo },
              repositories: [
                WorkflowSettingsRepositoryScan(
                  repositoryID: repository.repositoryID,
                  name: repository.name,
                  rootPath: repository.rootPath,
                  directory: repository.directory,
                  entries: entries)
              ])
          }
        } catch {
          throw WorkflowSettingsError(
            message: "Could not read a workflow folder: \(error.localizedDescription)")
        }
      },
      createWorkflow: { directory in
        do {
          return try WorkflowStarterTemplate.write(in: directory)
        } catch {
          throw WorkflowSettingsError(
            message: "Could not create the workflow file: \(error.localizedDescription)")
        }
      },
      trashWorkflow: { url in
        do {
          try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
          throw WorkflowSettingsError(
            message: "Could not move the workflow to Trash: \(error.localizedDescription)")
        }
      },
      runTargets: { scope in
        guard let appStore = storeBox.store else { return [] }
        let snapshot = makeWorkflowRuntimeSnapshot(
          appStore: appStore, terminalManager: terminalManager)
        let targets = snapshot.resolution.worktrees.map { worktree in
          WorkflowSettingsRunTarget(
            id: worktree.id,
            name: worktree.name,
            repositoryName: URL(filePath: worktree.rootPath, directoryHint: .isDirectory)
              .lastPathComponent,
            rootPath: worktree.rootPath,
            isPreferred: worktree.id == snapshot.resolution.focusedWorktreeID)
        }
        return WorkflowSettingsRunTarget.visible(targets, in: scope)
      },
      reveal: WorkflowSettingsClient.reveal,
      watch: WorkflowSettingsClient.watchPaths
    )
  }
}
