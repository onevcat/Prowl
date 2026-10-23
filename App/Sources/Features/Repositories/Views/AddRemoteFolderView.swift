import ComposableArchitecture
import SwiftUI

struct AddRemoteFolderView: View {
  @Bindable var store: StoreOf<AddRemoteFolderFeature>
  @FocusState private var isPathFieldFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Add Remote Folder")
          .font(.title3)
        Text("Open a folder on another machine over SSH.")
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 8) {
        Picker("Host", selection: $store.selectedProfileID) {
          ForEach(store.hostProfiles) { profile in
            Text(profile.alias)
              .tag(Optional(profile.id))
          }
          Text("New Host…")
            .tag(Optional<HostProfile.ID>.none)
        }
        .disabled(store.isValidating)
        if store.selectedProfile == nil {
          TextField("Host", text: $store.destination, prompt: Text("user@example.com"))
            .textFieldStyle(.roundedBorder)
            .monospaced()
            .disabled(store.isValidating)
          Text("A destination for ssh: user@host, or an alias from your SSH configuration.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Path")
          .foregroundStyle(.secondary)
        TextField("Path", text: $store.path, prompt: Text("~/projects/app"))
          .textFieldStyle(.roundedBorder)
          .monospaced()
          .disabled(store.isValidating)
          .focused($isPathFieldFocused)
          .onSubmit { store.send(.addButtonTapped) }
        Text("A repository adds its main worktree; any other folder is added as it is.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      Label {
        Text("Prowl keeps a background SSH connection to this host while its folders are in the sidebar.")
          .font(.footnote)
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: "network")
          .accessibilityHidden(true)
      }
      .foregroundStyle(.secondary)

      if let errorMessage = store.errorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        if store.isValidating {
          ProgressView()
            .controlSize(.small)
          Text("Checking the host…")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Cancel") {
          store.send(.cancelButtonTapped)
        }
        .keyboardShortcut(.cancelAction)
        .disabled(store.isValidating)
        .help("Close without adding a folder (Esc)")
        Button("Add") {
          store.send(.addButtonTapped)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!store.canAdd)
        .help("Check the host and add the folder (Return)")
      }
    }
    .padding(20)
    .frame(width: 460)
    .interactiveDismissDisabled(store.isValidating)
    .onAppear { isPathFieldFocused = store.selectedProfile != nil }
  }
}
