import ComposableArchitecture
import SwiftUI

struct SettingsView: View {
  @Bindable var store: StoreOf<AppFeature>
  @Bindable var settingsStore: StoreOf<SettingsFeature>
  @Environment(\.dismiss) private var dismiss
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  init(store: StoreOf<AppFeature>) {
    self.store = store
    settingsStore = store.scope(state: \.settings, action: \.settings)
  }

  var body: some View {
    let updatesStore = store.scope(state: \.updates, action: \.updates)
    let repositories = store.repositories.repositories
    let customTitles = store.repositories.repositoryCustomTitles
    let selection = settingsStore.selection ?? .general

    NavigationSplitView(columnVisibility: $columnVisibility) {
      List(selection: $settingsStore.selection.sending(\.setSelection)) {
        Label("General", systemImage: "gearshape")
          .tag(SettingsSection.general)
        Label("Notifications", systemImage: "bell")
          .tag(SettingsSection.notifications)
        Label("Shortcuts", systemImage: "keyboard")
          .tag(SettingsSection.shortcuts)
        Label("Worktree", systemImage: "archivebox")
          .tag(SettingsSection.worktree)
        Label("Updates", systemImage: "arrow.down.circle")
          .tag(SettingsSection.updates)
        Label("GitHub", systemImage: "arrow.triangle.branch")
          .tag(SettingsSection.github)
        Label("Commands", systemImage: "globe")
          .tag(SettingsSection.customCommands)
        Label("Advanced", systemImage: "gearshape.2")
          .tag(SettingsSection.advanced)

        Section("Agents") {
          Label("Profiles", systemImage: "person.crop.circle")
            .tag(SettingsSection.profiles)
          Label("CLI & Skills", systemImage: "terminal")
            .tag(SettingsSection.commandLineTool)
          Label("Workflows", systemImage: "point.3.connected.trianglepath.dotted")
            .tag(SettingsSection.workflows)
        }

        Section("Repositories") {
          ForEach(repositories) { repository in
            RepoDisplayName(
              fallbackName: repository.name,
              customTitle: customTitles[repository.id]
            )
            .tag(SettingsSection.repository(repository.id))
          }
        }
      }
      .listStyle(.sidebar)
      .frame(minWidth: 220, maxHeight: .infinity)
      .navigationSplitViewColumnWidth(220)
    } detail: {
      switch selection {
      case .general:
        SettingsDetailView {
          AppearanceSettingsView(store: settingsStore)
            .navigationTitle("General")
        }
      case .notifications:
        SettingsDetailView {
          NotificationsSettingsView(store: settingsStore)
            .navigationTitle("Notifications")
        }
      case .shortcuts:
        SettingsDetailView {
          ShortcutsSettingsView(store: settingsStore)
            .navigationTitle("Shortcuts")
        }
      case .worktree:
        SettingsDetailView {
          WorktreeSettingsView(store: settingsStore)
            .navigationTitle("Worktree")
        }
      case .updates:
        SettingsDetailView {
          UpdatesSettingsView(settingsStore: settingsStore, updatesStore: updatesStore)
            .navigationTitle("Updates")
        }
      case .advanced:
        SettingsDetailView {
          AdvancedSettingsView(store: settingsStore)
            .navigationTitle("Advanced")
        }
      case .github:
        SettingsDetailView {
          GithubSettingsView(store: settingsStore)
            .navigationTitle("GitHub")
        }
      case .customCommands:
        SettingsDetailView {
          if let globalCustomCommandsStore = settingsStore.scope(
            state: \.globalCustomCommands,
            action: \.globalCustomCommands
          ) {
            GlobalCustomCommandsView(store: globalCustomCommandsStore)
              .navigationTitle("Global Commands")
          } else {
            ProgressView()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      case .profiles:
        SettingsDetailView {
          if let agentProfilesStore = settingsStore.scope(
            state: \.agentProfiles,
            action: \.agentProfiles
          ) {
            AgentProfilesSettingsView(store: agentProfilesStore)
          } else {
            ProgressView()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      case .workflows:
        SettingsDetailView {
          if let workflowsStore = settingsStore.scope(state: \.workflows, action: \.workflows) {
            WorkflowsSettingsView(store: workflowsStore)
          } else {
            ProgressView()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      case .commandLineTool:
        SettingsDetailView {
          CommandLineToolSettingsView(store: settingsStore)
            .navigationTitle("CLI & Skills")
        }
      case .repository(let repositoryID):
        if let repository = repositories[id: repositoryID] {
          SettingsDetailView {
            if let repositorySettingsStore = settingsStore.scope(
              state: \.repositorySettings,
              action: \.repositorySettings
            ) {
              RepositorySettingsView(store: repositorySettingsStore)
                .id(repository.id)
                .navigationTitle(customTitles[repository.id] ?? repository.name)
            } else {
              // Settled placeholder while the scoped store is briefly nil (e.g. mid
              // repository switch), instead of `IfLetStore` flashing an empty pane.
              ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(customTitles[repository.id] ?? repository.name)
            }
          }
        } else {
          SettingsDetailView {
            Text("Repository not found.")
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .navigationTitle("Repositories")
          }
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .alert($settingsStore.scope(state: \.alert, action: \.alert))
    .frame(minWidth: 800, minHeight: 600)
    .focusedSceneAction(\.closeSettingsWindowAction, enabled: true) {
      dismiss()
    }
  }
}
