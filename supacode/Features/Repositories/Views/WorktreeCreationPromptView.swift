import ComposableArchitecture
import SwiftUI

struct WorktreeCreationPromptView: View {
  @Bindable var store: StoreOf<WorktreeCreationPromptFeature>
  @FocusState private var isBranchFieldFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("New Worktree")
          .interfaceFont(.title3)
        Text("Create a branch in \(store.repositoryName)")
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Branch name")
          .foregroundStyle(.secondary)
        TextField(
          "Branch name",
          text: $store.branchName,
          prompt: Text(store.randomPlaceholder)
        )
        .textFieldStyle(.roundedBorder)
        .focused($isBranchFieldFocused)
        .onSubmit {
          store.send(.createButtonTapped)
        }
        .overlay(alignment: .trailing) {
          if store.isSuggestingName {
            ProgressView()
              .controlSize(.mini)
              .padding(.trailing, 6)
          }
        }
        if let suggested = store.suggestedBranchName {
          HStack(spacing: 4) {
            Text("Auto suggestion: ")
              .interfaceFont(.footnote)
              .foregroundStyle(.tertiary)
            Text(suggested)
              .interfaceFont(.footnote)
              .monospaced()
              .foregroundStyle(.tertiary)
              .lineLimit(1)
            Button {
              store.send(.useSuggestedBranchName)
            } label: {
              Text("Use")
                .interfaceFont(.footnote)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            Spacer()
            Image(systemName: "questionmark.circle")
              .accessibilityLabel("About auto suggestion")
              .interfaceFont(.footnote)
              .foregroundStyle(.tertiary)
              .help(
                "Suggested by on-device AI based on your repository "
                  + "context and recent terminal activity. "
                  + "May not always be accurate."
              )
          }
        }
      }

      Picker("Branch from", selection: $store.selectedBaseRef) {
        Text(store.automaticBaseRefLabel)
          .tag(Optional<String>.none)
        ForEach(store.baseRefOptions, id: \.self) { ref in
          Text(ref)
            .tag(Optional(ref))
        }
      }

      VStack(alignment: .leading) {
        Toggle(
          "Fetch remote before creating worktree",
          isOn: $store.fetchRemote
        )
        .help("Runs git fetch <remote> before creating the worktree.")
        Text("Keeps remote-tracking base branches current. Fetch failures are logged and creation continues.")
          .interfaceFont(.footnote)
          .foregroundStyle(.secondary)
      }

      DisclosureGroup("Advanced", isExpanded: $store.showAdvancedOptions) {
        VStack(alignment: .leading, spacing: 12) {
          Text("Override where the new worktree folder is created. Leave a field blank to use its default.")
            .interfaceFont(.footnote)
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 8) {
            Text("Worktree name")
              .foregroundStyle(.secondary)
            TextField(
              "Worktree name",
              text: $store.worktreeNameOverride,
              prompt: Text(store.worktreeNamePlaceholder)
            )
            .textFieldStyle(.roundedBorder)
          }
          VStack(alignment: .leading, spacing: 8) {
            Text("Parent folder")
              .foregroundStyle(.secondary)
            TextField(
              "Parent folder",
              text: $store.worktreePathOverride,
              prompt: Text(store.defaultWorktreeBaseDirectory)
            )
            .textFieldStyle(.roundedBorder)
          }
        }
        .padding(.top, 4)
      }

      // Footer: surface a validation error, otherwise preview the full destination
      // path the worktree will be created at (mirrors the reducer's resolution).
      if let message = store.validationMessage ?? store.worktreeNameValidationError, !message.isEmpty {
        Text(message)
          .interfaceFont(.footnote)
          .foregroundStyle(.red)
      } else {
        Text(store.resolvedWorktreeLocationPreview)
          .interfaceFont(.footnote)
          .monospaced()
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .lineLimit(2)
          .truncationMode(.middle)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack {
        if store.isValidating {
          ProgressView()
            .controlSize(.small)
        }
        Spacer()
        Button("Cancel") {
          store.send(.cancelButtonTapped)
        }
        .keyboardShortcut(.cancelAction)
        .help("Cancel (Esc)")
        Button("Create") {
          store.send(.createButtonTapped)
        }
        .keyboardShortcut(.defaultAction)
        .help("Create (↩)")
        .disabled(store.isValidating)
      }
    }
    .padding(20)
    .frame(minWidth: 420)
    .task {
      isBranchFieldFocused = true
    }
  }
}
