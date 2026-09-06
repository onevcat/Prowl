import ComposableArchitecture
import ProwlCLIShared
import SwiftUI

/// Settings → Agents → Profiles: the profile list, with a native drill-in editor page per
/// profile. `NavigationStack` is driven by TCA's `StackState`, so the system
/// Back control writes its pop directly to the reducer-owned route.
/// List order is the recommendation fallback order.
struct AgentProfilesSettingsView: View {
  @Bindable var store: StoreOf<AgentProfilesFeature>

  var body: some View {
    NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
      Form {
        profileListSection
      }
      .formStyle(.grouped)
      .navigationTitle("Agent Profiles")
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .task { store.send(.task) }
    } destination: { editorStore in
      AgentProfileEditorView(store: editorStore)
    }
  }

  private var profileListSection: some View {
    Section {
      if store.settings.agentProfiles.isEmpty {
        Text("No agent profiles yet. Add one to launch agents from the Agents menu.")
          .foregroundStyle(.secondary)
      }
      ForEach(store.settings.agentProfiles) { profile in
        profileRow(profile)
      }
      HStack(spacing: 8) {
        Menu {
          ForEach(AgentProfileRuntime.allCases) { runtime in
            Button(AgentRuntimeAdapterRegistry.displayName(for: runtime)) {
              store.send(.addProfile(runtime))
            }
          }
        } label: {
          Label("Add Profile", systemImage: "plus")
        }
        .fixedSize()
        .help("Add a new agent profile")
        Spacer()
      }
    } header: {
      VStack(alignment: .leading, spacing: 4) {
        Text("Agent Profiles")
        Text(
          "Named launch presets for verified agents, available from the toolbar Agents menu "
            + "and the Command Palette. The first enabled profile is the recommendation fallback."
        )
        .foregroundStyle(.secondary)
      }
    }
  }

  private func profileRow(_ profile: AgentProfile) -> some View {
    HStack(spacing: 8) {
      if let binding = profileBinding(profile.id) {
        Toggle("", isOn: binding.isEnabled)
          .labelsHidden()
          .toggleStyle(.checkbox)
          .help("Show this profile in the Agents menu")
      }
      NavigationLink(state: AgentProfileEditorFeature.State(profile: profile)) {
        profileLabel(profile)
      }
    }
    .contextMenu {
      Button("Move Up") { move(profile.id, by: -1) }
        .disabled(index(of: profile.id) == 0)
      Button("Move Down") { move(profile.id, by: 1) }
        .disabled(index(of: profile.id) == store.settings.agentProfiles.count - 1)
    }
  }

  // `.help` on the NavigationLink itself would shadow the badge's own tooltip,
  // so the edit hint is scoped to the regions around the badge instead.
  private func profileLabel(_ profile: AgentProfile) -> some View {
    HStack(spacing: 8) {
      HStack(spacing: 8) {
        AgentProfileIconImage(source: profile.iconSource, pointSize: 16)
          .frame(width: 16, height: 16)
        Text(profile.name)
      }
      .help("Edit this profile")
      if profile.bindsDedicatedHome {
        Image(systemName: "person.crop.circle.badge.checkmark")
          .foregroundStyle(.secondary)
          .accessibilityLabel("Dedicated account")
          .help("Uses a dedicated home with its own account")
      }
      Spacer()
      Text(AgentRuntimeAdapterRegistry.displayName(for: profile.runtime))
        .foregroundStyle(.secondary)
        .help("Edit this profile")
    }
  }

  private func index(of id: AgentProfile.ID) -> Int? {
    store.settings.agentProfiles.firstIndex { $0.id == id }
  }

  private func move(_ id: AgentProfile.ID, by offset: Int) {
    guard let index = index(of: id) else { return }
    let destination = offset > 0 ? index + 2 : index - 1
    store.send(.moveProfiles(IndexSet(integer: index), destination))
  }

  private func profileBinding(_ id: AgentProfile.ID) -> Binding<AgentProfile>? {
    guard let index = store.settings.agentProfiles.firstIndex(where: { $0.id == id }) else {
      return nil
    }
    return $store.settings.agentProfiles[index]
  }
}
