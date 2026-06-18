import ComposableArchitecture
import SwiftUI

extension View {
  @ViewBuilder
  fileprivate func removingSidebarToggle() -> some View {
    if #available(macOS 14.0, *) {
      toolbar(removing: .sidebarToggle)
    } else {
      self
    }
  }
}

struct SettingsView: View {
  @Bindable var store: StoreOf<AppFeature>
  @Bindable var settingsStore: StoreOf<SettingsFeature>

  init(store: StoreOf<AppFeature>) {
    self.store = store
    settingsStore = store.scope(state: \.settings, action: \.settings)
  }

  var body: some View {
    let updatesStore = store.scope(state: \.updates, action: \.updates)
    let repositories = store.repositories.repositories
    let customTitles = store.repositories.repositoryCustomTitles
    let selection = settingsStore.selection ?? .general

    NavigationSplitView(columnVisibility: .constant(.all)) {
      VStack(spacing: 0) {
        List(selection: $settingsStore.selection.sending(\.setSelection)) {
          Label("General", systemImage: "gearshape")
            .tag(SettingsSection.general)
          Label("Notifications", systemImage: "bell")
            .tag(SettingsSection.notifications)
          Label("Shortcuts", systemImage: "keyboard")
            .tag(SettingsSection.shortcuts)
          Label("Worktree", systemImage: "archivebox")
            .tag(SettingsSection.worktree)
          Label("Bootstrap", systemImage: "terminal")
            .tag(SettingsSection.bootstrap)
          Label("Updates", systemImage: "arrow.down.circle")
            .tag(SettingsSection.updates)
          Label("Advanced", systemImage: "gearshape.2")
            .tag(SettingsSection.advanced)
          Label("GitHub", systemImage: "arrow.triangle.branch")
            .tag(SettingsSection.github)

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
        .removingSidebarToggle()
      }
    } detail: {
      switch selection {
      case .general:
        SettingsDetailView {
          AppearanceSettingsView(store: settingsStore)
            .navigationTitle("General")
            .navigationSubtitle("Appearance and preferences")
        }
      case .notifications:
        SettingsDetailView {
          NotificationsSettingsView(store: settingsStore)
            .navigationTitle("Notifications")
            .navigationSubtitle("In-app alerts and delivery")
        }
      case .shortcuts:
        SettingsDetailView {
          ShortcutsSettingsView(store: settingsStore)
            .navigationTitle("Shortcuts")
            .navigationSubtitle("Global keybindings")
        }
      case .worktree:
        SettingsDetailView {
          WorktreeSettingsView(store: settingsStore)
            .navigationTitle("Worktree")
            .navigationSubtitle("Archive behavior")
        }
      case .bootstrap:
        SettingsDetailView {
          BootstrapProfilesSettingsView()
            .navigationTitle("Bootstrap")
            .navigationSubtitle("Workspace bootstrap profiles")
        }
      case .updates:
        SettingsDetailView {
          UpdatesSettingsView(settingsStore: settingsStore, updatesStore: updatesStore)
            .navigationTitle("Updates")
            .navigationSubtitle("Update preferences")
        }
      case .advanced:
        SettingsDetailView {
          AdvancedSettingsView(store: settingsStore)
            .navigationTitle("Advanced")
            .navigationSubtitle("Analytics and diagnostics")
        }
      case .github:
        SettingsDetailView {
          GithubSettingsView(store: settingsStore)
            .navigationTitle("GitHub")
            .navigationSubtitle("GitHub CLI integration")
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
                .navigationSubtitle(repository.rootURL.path(percentEncoded: false))
            } else {
              // Settled placeholder while the scoped store is briefly nil (e.g. mid
              // repository switch), instead of `IfLetStore` flashing an empty pane.
              ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(customTitles[repository.id] ?? repository.name)
                .navigationSubtitle(repository.rootURL.path(percentEncoded: false))
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
    .frame(minWidth: 800, minHeight: 500)
    .background {
      WindowAppearanceSetter(colorScheme: settingsStore.appearanceMode.colorScheme)
      WindowLevelSetter(level: .normal)
    }
    .ignoresSafeArea(.container, edges: .top)
  }
}
