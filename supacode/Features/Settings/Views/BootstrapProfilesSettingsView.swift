import Sharing
import SwiftUI

struct BootstrapProfilesSettingsView: View {
  @Shared(.bootstrapProfiles) private var profiles
  @State private var selectedProfileID: String?
  @State private var profileIDDrafts: [String: String] = [:]
  @State private var profileIDValidationMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Button {
          addProfile()
        } label: {
          Label("Add", systemImage: "plus")
        }
        .help("Add a bootstrap profile")

        Button {
          duplicateSelectedProfile()
        } label: {
          Label("Duplicate", systemImage: "doc.on.doc")
        }
        .disabled(selectedProfile == nil)
        .help("Duplicate the selected bootstrap profile")

        Button(role: .destructive) {
          removeSelectedProfile()
        } label: {
          Label("Delete", systemImage: "trash")
        }
        .disabled(selectedProfile == nil)
        .help("Delete the selected bootstrap profile")
      }

      HSplitView {
        List(selection: $selectedProfileID) {
          ForEach(profiles) { profile in
            VStack(alignment: .leading, spacing: 2) {
              Text(profile.name.isEmpty ? profile.id : profile.name)
                .lineLimit(1)
              Text(profile.id)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .tag(profile.id)
          }
        }
        .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

        if let profile = selectedProfile {
          profileEditor(profile)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
          ContentUnavailableView(
            "No Bootstrap Profile Selected",
            systemImage: "terminal",
            description: Text("Add or select a profile to edit local workspace bootstrap scripts.")
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .onAppear {
      ensureSelection()
    }
    .onChange(of: profiles) { _, _ in
      ensureSelection()
    }
    .onChange(of: selectedProfileID) { _, _ in
      profileIDValidationMessage = nil
    }
  }

  private var selectedProfile: ProjectWorkspaceBootstrapProfile? {
    guard let selectedProfileID else {
      return nil
    }
    return profiles.first { $0.id == selectedProfileID }
  }

  private func profileEditor(_ profile: ProjectWorkspaceBootstrapProfile) -> some View {
    Form {
      Section("Profile") {
        idTextField(profile)
        editableTextField("Name", profileID: profile.id, keyPath: \.name)
        editableTextField("Description", profileID: profile.id, keyPath: \.description)
        editableTextField("Shell", profileID: profile.id, keyPath: \.shellText)
        HStack {
          Text("Timeout")
          TextField(
            "300",
            text: Binding(
              get: { String(profile.timeoutSeconds) },
              set: { value in
                updateProfile(id: profile.id) { $0.timeoutSeconds = max(1, Int(value) ?? 300) }
              }
            )
          )
          .textFieldStyle(.roundedBorder)
          .frame(width: 96)
          Text("seconds")
            .foregroundStyle(.secondary)
        }
      }

      Section("Script") {
        TextEditor(
          text: Binding(
            get: { profile.script },
            set: { script in updateProfile(id: profile.id) { $0.script = script } }
          )
        )
        .font(.body.monospaced())
        .frame(minHeight: 240)
        .overlay {
          RoundedRectangle(cornerRadius: 6)
            .stroke(.separator, lineWidth: 1)
        }
      }

      if let message = profileIDValidationMessage ?? validationMessage(for: profile) {
        Section {
          Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        }
      }
    }
    .formStyle(.grouped)
  }

  private func idTextField(_ profile: ProjectWorkspaceBootstrapProfile) -> some View {
    TextField(
      "ID",
      text: Binding(
        get: { profileIDDrafts[profile.id] ?? profile.id },
        set: { value in
          profileIDDrafts[profile.id] = value
          applyProfileIDDraft(value, currentID: profile.id)
        }
      )
    )
    .textFieldStyle(.roundedBorder)
  }

  private func editableTextField(
    _ title: String,
    profileID: String,
    keyPath: WritableKeyPath<ProjectWorkspaceBootstrapProfile, String>
  ) -> some View {
    TextField(
      title,
      text: Binding(
        get: { profiles.first(where: { $0.id == profileID })?[keyPath: keyPath] ?? "" },
        set: { value in
          let oldID = profileID
          updateProfile(id: oldID) { profile in
            profile[keyPath: keyPath] = value
            if keyPath == \.id {
              selectedProfileID = profile.id
            }
          }
        }
      )
    )
    .textFieldStyle(.roundedBorder)
  }

  private func addProfile() {
    let id = nextAvailableID(base: "bootstrap-profile")
    let profile = ProjectWorkspaceBootstrapProfile(
      id: id,
      name: "Bootstrap Profile",
      shell: "/bin/zsh",
      script: "set -euo pipefail\n"
    )
    $profiles.withLock { $0.append(profile.normalized) }
    selectedProfileID = id
    profileIDDrafts[id] = id
  }

  private func duplicateSelectedProfile() {
    guard var profile = selectedProfile else {
      return
    }
    profile.id = nextAvailableID(base: profile.id)
    profile.name = profile.name.isEmpty ? profile.id : "\(profile.name) Copy"
    $profiles.withLock { $0.append(profile.normalized) }
    selectedProfileID = profile.id
    profileIDDrafts[profile.id] = profile.id
  }

  private func removeSelectedProfile() {
    guard let selectedProfileID else {
      return
    }
    $profiles.withLock { profiles in
      profiles.removeAll { $0.id == selectedProfileID }
    }
    profileIDDrafts[selectedProfileID] = nil
    profileIDValidationMessage = nil
    self.selectedProfileID = profiles.first?.id
  }

  private func applyProfileIDDraft(_ value: String, currentID: String) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      profileIDValidationMessage = "ID is required."
      return
    }
    if trimmed != currentID, profiles.contains(where: { $0.id == trimmed }) {
      profileIDValidationMessage = "ID must be unique."
      return
    }
    profileIDValidationMessage = nil
    updateProfile(id: currentID) { $0.id = trimmed }
    profileIDDrafts[currentID] = nil
    profileIDDrafts[trimmed] = trimmed
    selectedProfileID = trimmed
  }

  private func updateProfile(
    id: String,
    mutate: (inout ProjectWorkspaceBootstrapProfile) -> Void
  ) {
    $profiles.withLock { profiles in
      guard let index = profiles.firstIndex(where: { $0.id == id }) else {
        return
      }
      var profile = profiles[index]
      mutate(&profile)
      profiles[index] = profile.normalized
    }
  }

  private func ensureSelection() {
    if let selectedProfileID, profiles.contains(where: { $0.id == selectedProfileID }) {
      return
    }
    selectedProfileID = profiles.first?.id
  }

  private func nextAvailableID(base: String) -> String {
    let normalizedBase =
      base
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let candidateBase = normalizedBase.isEmpty ? "bootstrap-profile" : normalizedBase
    let existing = Set(profiles.map(\.id))
    if !existing.contains(candidateBase) {
      return candidateBase
    }
    var suffix = 2
    while existing.contains("\(candidateBase)-\(suffix)") {
      suffix += 1
    }
    return "\(candidateBase)-\(suffix)"
  }

  private func validationMessage(for profile: ProjectWorkspaceBootstrapProfile) -> String? {
    if profile.id.isEmpty {
      return "ID is required."
    }
    if profiles.filter({ $0.id == profile.id }).count > 1 {
      return "ID must be unique."
    }
    if profile.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Script is required."
    }
    return nil
  }
}

extension ProjectWorkspaceBootstrapProfile {
  fileprivate var shellText: String {
    get { shell ?? "" }
    set {
      let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
      shell = trimmed.isEmpty ? nil : trimmed
    }
  }
}
