import AppKit
import ComposableArchitecture
import Sharing
import SwiftUI

struct WorkspaceCreationPromptView: View {
  @Bindable var store: StoreOf<WorkspaceCreationPromptFeature>
  @Shared(.bootstrapProfiles) private var bootstrapProfiles
  @FocusState private var isTitleFieldFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("New Workspace")
          .font(.title3)
        Text(repositoryCountText)
          .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Title")
          .foregroundStyle(.secondary)
        TextField(
          "Workspace title",
          text: Binding(
            get: { store.title },
            set: { store.send(.titleChanged($0)) }
          )
        )
        .textFieldStyle(.roundedBorder)
        .focused($isTitleFieldFocused)
        .disabled(store.isCreating)
        .overlay {
          invalidFieldBorder(store.validationTarget == .title)
        }
        .onSubmit {
          store.send(.createButtonTapped)
        }
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Folder")
          .foregroundStyle(.secondary)
        HStack(spacing: 8) {
          TextField(
            "Workspace folder",
            text: Binding(
              get: { store.rootPath },
              set: { store.send(.rootPathChanged($0)) }
            )
          )
          .textFieldStyle(.roundedBorder)
          .font(.body.monospaced())
          .disabled(store.isCreating)
          .overlay {
            invalidFieldBorder(store.validationTarget == .rootPath)
          }
          Button {
            chooseFolder()
          } label: {
            Label("Choose Folder", systemImage: "folder")
          }
          .help("Choose Workspace Folder")
          .disabled(store.isCreating)
        }
        Text(store.rootPathPreview)
          .font(.footnote.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Repositories")
          .foregroundStyle(.secondary)
        HStack(spacing: 8) {
          Menu {
            ForEach(store.availableOpenedRepositories) { repository in
              Button {
                store.send(.addOpenedRepository(repository.id))
              } label: {
                Text(repository.name.isEmpty ? repository.sourceLocation : repository.name)
              }
            }
          } label: {
            Label("Add Opened", systemImage: "folder.badge.plus")
          }
          .help("Add Opened Path")
          .disabled(store.isCreating || store.availableOpenedRepositories.isEmpty)

          Button {
            store.send(.addRemoteButtonTapped)
          } label: {
            Label("Add Remote", systemImage: "network")
          }
          .help("Add Remote Repository")
          .disabled(store.isCreating)

          Button {
            chooseRepositorySource(kind: .localRepository)
          } label: {
            Label("Add Local", systemImage: "folder")
          }
          .help("Add Local Repository")
          .disabled(store.isCreating)
        }
        ScrollViewReader { proxy in
          ScrollView {
            VStack(spacing: 0) {
              ForEach(store.repositories) { repository in
                repositoryEditor(repository)
                  .id(repository.id)
                if repository.id != store.repositories.last?.id {
                  Divider()
                }
              }
            }
          }
          .onChange(of: store.validationRequestID) { _, _ in
            guard let repositoryID = validationRepositoryID else {
              return
            }
            withAnimation(.easeInOut(duration: 0.2)) {
              proxy.scrollTo(repositoryID, anchor: .center)
            }
          }
        }
        .frame(maxHeight: 340)
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
      }

      if let message = store.validationMessage, !message.isEmpty {
        Text(message)
          .font(.footnote)
          .foregroundStyle(.red)
      }

      HStack {
        if store.isCreating {
          ProgressView()
            .controlSize(.small)
        }
        Spacer()
        Button("Cancel") {
          store.send(.cancelButtonTapped)
        }
        .keyboardShortcut(.cancelAction)
        .help(store.isCreating ? "Cancel creation and roll back (Esc)" : "Cancel (Esc)")
        Button("Create") {
          store.send(.createButtonTapped)
        }
        .keyboardShortcut(.defaultAction)
        .help("Create Workspace (↩)")
        .disabled(store.isCreating)
      }
    }
    .padding(20)
    .frame(minWidth: 680)
    .task {
      isTitleFieldFocused = true
    }
    .sheet(
      isPresented: Binding(
        get: { store.remoteRepositoryPrompt != nil },
        set: { isPresented in
          if !isPresented {
            store.send(.remoteRepositoryPromptDismissed)
          }
        }
      )
    ) {
      remoteRepositoryPromptView()
    }
  }

  private var repositoryCountText: String {
    store.repositories.count == 1 ? "1 repository" : "\(store.repositories.count) repositories"
  }

  private func repositoryEditor(_ repository: ProjectWorkspaceCreationRepository) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      repositoryHeader(repository)
      repositoryNameAndPathFields(repository)
      repositorySourceField(repository)
      repositoryBranchFields(repository)
      repositoryBootstrapFields(repository)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 10)
  }

  private func repositoryHeader(_ repository: ProjectWorkspaceCreationRepository) -> some View {
    HStack(spacing: 10) {
      Text(repository.name.isEmpty ? "Repository" : repository.name)
        .fontWeight(.medium)
        .lineLimit(1)

      sourceKindBadge(repository.sourceKind)

      Spacer()

      Button {
        store.send(.removeRepository(repository.id))
      } label: {
        Image(systemName: "trash")
          .accessibilityLabel("Remove Repository")
      }
      .buttonStyle(.borderless)
      .help("Remove Repository")
      .disabled(store.isCreating)
    }
  }

  private func repositoryNameAndPathFields(_ repository: ProjectWorkspaceCreationRepository)
    -> some View
  {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Name")
          .foregroundStyle(.secondary)
        TextField(
          "Repository name",
          text: Binding(
            get: { repository.name },
            set: { store.send(.repositoryNameChanged(repository.id, $0)) }
          )
        )
        .textFieldStyle(.roundedBorder)
        .disabled(store.isCreating)
        .overlay {
          invalidFieldBorder(repositoryFieldIsInvalid(repository, .name))
        }
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Folder inside workspace")
          .foregroundStyle(.secondary)
        TextField(
          "Folder name",
          text: Binding(
            get: { repository.path ?? "" },
            set: { store.send(.repositoryPathChanged(repository.id, $0)) }
          )
        )
        .textFieldStyle(.roundedBorder)
        .disabled(store.isCreating)
      }
    }
  }

  private func repositorySourceField(_ repository: ProjectWorkspaceCreationRepository) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        TextField(
          sourceLocationPlaceholder(repository.sourceKind),
          text: Binding(
            get: { repository.sourceLocation },
            set: { store.send(.repositorySourceLocationChanged(repository.id, $0)) }
          )
        )
        .textFieldStyle(.roundedBorder)
        .font(.body.monospaced())
        .disabled(store.isCreating)
        .overlay {
          invalidFieldBorder(repositoryFieldIsInvalid(repository, .source))
        }

        if repository.sourceKind != .remote {
          Button {
            chooseSource(for: repository)
          } label: {
            Image(systemName: "folder")
              .accessibilityLabel("Choose Repository Source")
          }
          .help("Choose Repository Source")
          .disabled(store.isCreating)
        }
      }
    }
  }

  private func repositoryBranchFields(_ repository: ProjectWorkspaceCreationRepository) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Picker(
          "Branch action",
          selection: Binding(
            get: { repository.checkoutMode },
            set: { store.send(.repositoryCheckoutModeChanged(repository.id, $0)) }
          )
        ) {
          if repository.sourceKind.supportsLinkCheckout {
            Text("Link").tag(ProjectWorkspaceRepositoryCheckoutMode.link)
          }
          Text("Create Branch").tag(ProjectWorkspaceRepositoryCheckoutMode.createBranch)
          Text("Use Existing").tag(ProjectWorkspaceRepositoryCheckoutMode.useExistingRef)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 150)
        .help("Choose Branch Action")
        .disabled(store.isCreating)

        if repository.checkoutMode == .createBranch {
          TextField(
            "Branch",
            text: Binding(
              get: { repository.branchName ?? "" },
              set: { store.send(.repositoryBranchNameChanged(repository.id, $0)) }
            )
          )
          .textFieldStyle(.roundedBorder)
          .disabled(store.isCreating)
          .overlay {
            invalidFieldBorder(repositoryFieldIsInvalid(repository, .branchName))
          }
        }

        if repository.checkoutMode != .link {
          WorkspaceBranchRefPickerView(
            title: repository.checkoutMode == .createBranch ? "Base ref" : "Existing branch",
            selection: repository.baseRef,
            options: repository.baseRefOptions,
            isDisabled: store.isCreating || repository.baseRefOptions.isEmpty,
            isInvalid: repositoryFieldIsInvalid(repository, .baseRef)
          ) { ref in
            store.send(.repositoryBaseRefChanged(repository.id, ref))
          }
          .disabled(store.isCreating || repository.baseRefOptions.isEmpty)
        }
      }

      if repository.checkoutMode != .link {
        if let localBranchName = repository.resettableLocalBranchName {
          VStack(alignment: .leading, spacing: 4) {
            Text("Local branch “\(localBranchName)” already exists and would be reset to this ref.")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            Picker(
              "Local branch “\(localBranchName)”",
              selection: Binding(
                get: { repository.resetLocalBranchToRemote },
                set: { store.send(.repositoryResetLocalBranchChanged(repository.id, $0)) }
              )
            ) {
              Text("Use local branch").tag(false)
              Text("Reset to \(repository.baseRef ?? "remote")").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(store.isCreating)
          }
        }
      }
    }
  }

  private func repositoryBootstrapFields(_ repository: ProjectWorkspaceCreationRepository)
    -> some View
  {
    let disablesAutomaticBootstrap = repository.checkoutMode == .link
    let selectedProfileIDs = repository.bootstrapScriptIDs
    let hasSelectedProfiles = !selectedProfileIDs.isEmpty
    let availableProfiles = bootstrapProfiles.filter { !selectedProfileIDs.contains($0.id) }
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Menu {
          if availableProfiles.isEmpty {
            Text(bootstrapProfiles.isEmpty ? "No bootstrap profiles" : "All profiles selected")
          } else {
            ForEach(availableProfiles) { profile in
              Button(bootstrapProfileTitle(profile)) {
                store.send(.repositoryBootstrapProfileAdded(repository.id, profile.id))
              }
            }
          }
        } label: {
          Label("Bootstrap Profile", systemImage: "plus")
        }
        .frame(minWidth: 190, alignment: .leading)
        .disabled(store.isCreating || bootstrapProfiles.isEmpty || disablesAutomaticBootstrap)
        .help(bootstrapProfilePickerHelpText(disablesAutomaticBootstrap: disablesAutomaticBootstrap))

        Button {
          store.send(.manageBootstrapProfilesButtonTapped)
        } label: {
          Label("Manage", systemImage: "slider.horizontal.3")
        }
        .disabled(store.isCreating)
        .help("Open Bootstrap settings")

        Toggle(
          "Create",
          isOn: Binding(
            get: { repository.bootstrapRunOnCreate },
            set: { store.send(.repositoryBootstrapRunOnCreateChanged(repository.id, $0)) }
          )
        )
        .disabled(store.isCreating || disablesAutomaticBootstrap || !hasSelectedProfiles)
        .help("Run these profiles after the child repository is materialized during workspace creation")

        Toggle(
          "Required",
          isOn: Binding(
            get: { repository.bootstrapRequired },
            set: { store.send(.repositoryBootstrapRequiredChanged(repository.id, $0)) }
          )
        )
        .disabled(
          store.isCreating || disablesAutomaticBootstrap || !hasSelectedProfiles
            || !repository.bootstrapRunOnCreate
        )
        .help("If the create-time bootstrap fails, fail workspace creation and roll back Prowl-created folders")
      }

      if hasSelectedProfiles {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Array(selectedProfileIDs.enumerated()), id: \.element) { index, profileID in
            bootstrapProfileRow(
              profileID: profileID,
              index: index,
              count: selectedProfileIDs.count,
              repositoryID: repository.id
            )
          }
        }
      }
      Text(bootstrapStatusText(for: repository, disablesAutomaticBootstrap: disablesAutomaticBootstrap))
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
    }
  }

  private func bootstrapProfileRow(
    profileID: String,
    index: Int,
    count: Int,
    repositoryID: Repository.ID
  ) -> some View {
    HStack(spacing: 6) {
      Text(bootstrapProfileTitle(id: profileID))
        .lineLimit(1)
      Spacer()
      Button {
        store.send(.repositoryBootstrapProfileMoved(repositoryID, profileID, .earlier))
      } label: {
        Image(systemName: "chevron.up")
          .accessibilityLabel("Move earlier")
      }
      .buttonStyle(.borderless)
      .disabled(index == 0 || store.isCreating)
      .help("Move bootstrap profile earlier")
      Button {
        store.send(.repositoryBootstrapProfileMoved(repositoryID, profileID, .later))
      } label: {
        Image(systemName: "chevron.down")
          .accessibilityLabel("Move later")
      }
      .buttonStyle(.borderless)
      .disabled(index == count - 1 || store.isCreating)
      .help("Move bootstrap profile later")
      Button {
        store.send(.repositoryBootstrapProfileRemoved(repositoryID, profileID))
      } label: {
        Image(systemName: "xmark")
          .accessibilityLabel("Remove")
      }
      .buttonStyle(.borderless)
      .disabled(store.isCreating)
      .help("Remove bootstrap profile")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
  }

  private func bootstrapProfileTitle(_ profile: ProjectWorkspaceBootstrapProfile) -> String {
    if profile.name.isEmpty || profile.name == profile.id {
      return profile.id
    }
    return "\(profile.name) (\(profile.id))"
  }

  private func bootstrapProfileTitle(id: String) -> String {
    if let profile = bootstrapProfiles.first(where: { $0.id == id }) {
      return bootstrapProfileTitle(profile)
    }
    return id
  }

  private func bootstrapProfilePickerHelpText(disablesAutomaticBootstrap: Bool) -> String {
    if disablesAutomaticBootstrap {
      return "Linked repositories use the original checkout, so create-time bootstrap is disabled."
    }
    return "Add a local bootstrap profile from ~/.prowl/bootstrap-profiles.json"
  }

  private func bootstrapStatusText(
    for repository: ProjectWorkspaceCreationRepository,
    disablesAutomaticBootstrap: Bool
  ) -> String {
    if disablesAutomaticBootstrap {
      return "Link mode skips create-time bootstrap."
    }
    if bootstrapProfiles.isEmpty {
      return "No profiles yet."
    }
    let count = repository.bootstrapScriptIDs.count
    guard count > 0 else {
      return "Optional."
    }
    var parts = ["\(count) selected"]
    if repository.bootstrapRunOnCreate {
      parts.append("runs on create")
    }
    if repository.bootstrapRequired {
      parts.append("required")
    }
    return parts.joined(separator: ", ") + "."
  }

  @ViewBuilder
  private func remoteRepositoryPromptView() -> some View {
    if let prompt = store.remoteRepositoryPrompt {
      VStack(alignment: .leading, spacing: 16) {
        Text("Add Remote Repository")
          .font(.title3)

        VStack(alignment: .leading, spacing: 8) {
          Text("Remote URL")
            .foregroundStyle(.secondary)
          TextField(
            "git@github.com:owner/repo.git",
            text: Binding(
              get: { prompt.url },
              set: { store.send(.remoteRepositoryPromptURLChanged($0)) }
            )
          )
          .textFieldStyle(.roundedBorder)
          .font(.body.monospaced())
          .disabled(prompt.isLoading)
          helpText("Remote git URL to clone into the workspace, such as SSH or HTTPS.")
        }

        VStack(alignment: .leading, spacing: 8) {
          Text("Name")
            .foregroundStyle(.secondary)
          TextField(
            "Repository name",
            text: Binding(
              get: { prompt.name },
              set: { store.send(.remoteRepositoryPromptNameChanged($0)) }
            )
          )
          .textFieldStyle(.roundedBorder)
          .disabled(prompt.isLoading)
          helpText("Display name and default folder name for this remote repository.")
        }

        if !prompt.branchOptions.isEmpty {
          Text("\(prompt.branchOptions.count) remote branches loaded")
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else {
          helpText("Load branches before adding so Prowl can choose an existing branch safely.")
        }

        if let message = prompt.validationMessage, !message.isEmpty {
          Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
        }

        HStack {
          if prompt.isLoading {
            ProgressView()
              .controlSize(.small)
          }
          Spacer()
          Button("Cancel") {
            store.send(.remoteRepositoryPromptDismissed)
          }
          .keyboardShortcut(.cancelAction)
          .help("Cancel (Esc)")

          Button("Load") {
            store.send(.remoteRepositoryPromptLoadButtonTapped)
          }
          .help("Load Remote Branches")
          .disabled(
            prompt.isLoading || prompt.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

          Button("Add") {
            store.send(.remoteRepositoryPromptAddButtonTapped)
          }
          .keyboardShortcut(.defaultAction)
          .help("Add Remote Repository")
          .disabled(prompt.isLoading || prompt.branchOptions.isEmpty)
        }
      }
      .padding(20)
      .frame(width: 520)
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    panel.directoryURL = URL(filePath: store.rootPath).deletingLastPathComponent()
    panel.begin { response in
      guard response == .OK, let url = panel.url else {
        return
      }
      store.send(.rootPathChosen(url.path(percentEncoded: false)))
    }
  }

  private func chooseRepositorySource(kind: ProjectWorkspaceRepositorySourceKind) {
    let panel = repositorySourcePanel(kind: kind, currentPath: nil)
    panel.begin { response in
      guard response == .OK, let url = panel.url else {
        return
      }
      store.send(.addRepositoryFromURL(kind, url.path(percentEncoded: false)))
    }
  }

  private func chooseSource(for repository: ProjectWorkspaceCreationRepository) {
    let panel = repositorySourcePanel(
      kind: repository.sourceKind, currentPath: repository.sourceLocation)
    panel.begin { response in
      guard response == .OK, let url = panel.url else {
        return
      }
      store.send(.repositorySourceChosen(repository.id, url.path(percentEncoded: false)))
    }
  }

  private func repositorySourcePanel(
    kind: ProjectWorkspaceRepositorySourceKind,
    currentPath: String?
  ) -> NSOpenPanel {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    if let currentPath, !currentPath.isEmpty {
      panel.directoryURL = URL(filePath: currentPath).deletingLastPathComponent()
    }
    panel.message =
      kind == .bareRepository ? "Choose a bare repository folder" : "Choose a repository folder"
    return panel
  }

  private func sourceKindTitle(_ kind: ProjectWorkspaceRepositorySourceKind) -> String {
    switch kind {
    case .existingPath:
      return "Opened in Prowl"
    case .localRepository:
      return "Picked from Disk"
    case .remote:
      return "Remote Clone"
    case .bareRepository:
      return "Bare Worktree"
    }
  }

  private func sourceKindIcon(_ kind: ProjectWorkspaceRepositorySourceKind) -> String {
    switch kind {
    case .existingPath:
      return "folder.badge.plus"
    case .localRepository:
      return "folder"
    case .remote:
      return "network"
    case .bareRepository:
      return "externaldrive"
    }
  }

  private func sourceKindBadgeHelp(_ kind: ProjectWorkspaceRepositorySourceKind) -> String {
    switch kind {
    case .existingPath:
      return "Added from repositories already opened in Prowl."
    case .localRepository:
      return "Added by choosing a repository folder from disk."
    case .remote:
      return "Added from a remote URL and cloned into the workspace."
    case .bareRepository:
      return "Added from a local bare repository."
    }
  }

  private func sourceKindBadge(_ kind: ProjectWorkspaceRepositorySourceKind) -> some View {
    Label(sourceKindTitle(kind), systemImage: sourceKindIcon(kind))
      .font(.caption)
      .foregroundStyle(.secondary)
      .labelStyle(.titleAndIcon)
      .lineLimit(1)
      .help(sourceKindBadgeHelp(kind))
  }

  private func sourceLocationPlaceholder(_ kind: ProjectWorkspaceRepositorySourceKind) -> String {
    switch kind {
    case .existingPath, .localRepository:
      return "Repository folder"
    case .remote:
      return "Remote URL"
    case .bareRepository:
      return "Bare repository folder"
    }
  }

  private func helpText(_ text: String) -> some View {
    Text(text)
      .font(.footnote)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var validationRepositoryID: Repository.ID? {
    guard case .repository(let repositoryID, _) = store.validationTarget else {
      return nil
    }
    return repositoryID
  }

  private func repositoryFieldIsInvalid(
    _ repository: ProjectWorkspaceCreationRepository,
    _ field: WorkspaceCreationPromptFeature.RepositoryField
  ) -> Bool {
    store.validationTarget == .repository(repository.id, field)
  }

  private func invalidFieldBorder(_ isInvalid: Bool) -> some View {
    RoundedRectangle(cornerRadius: 5)
      .stroke(isInvalid ? Color.red : Color.clear, lineWidth: isInvalid ? 1.5 : 0)
      .allowsHitTesting(false)
  }
}

private struct WorkspaceBranchRefPickerView: View {
  let title: String
  let selection: String?
  let options: [GitBranchRefOption]
  let isDisabled: Bool
  let isInvalid: Bool
  let onSelect: (String) -> Void

  @State private var isPresented = false
  @State private var searchText = ""

  var body: some View {
    Button {
      isPresented = true
    } label: {
      HStack {
        Text(displayTitle)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 8)
        Image(systemName: "chevron.down")
          .imageScale(.small)
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(.bordered)
    .overlay {
      invalidFieldBorder
    }
    .help("Choose \(title)")
    .disabled(isDisabled)
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 10) {
        TextField("Search branches", text: $searchText)
          .textFieldStyle(.roundedBorder)

        ScrollView {
          VStack(alignment: .leading, spacing: 10) {
            ForEach(groupedOptions, id: \.kind) { group in
              VStack(alignment: .leading, spacing: 4) {
                Text(group.kind.title)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                ForEach(group.options) { option in
                  Button {
                    onSelect(option.ref)
                    isPresented = false
                    searchText = ""
                  } label: {
                    HStack {
                      if option.ref == selection {
                        Image(systemName: "checkmark")
                          .frame(width: 14)
                          .accessibilityHidden(true)
                      } else {
                        Color.clear
                          .frame(width: 14, height: 1)
                      }
                      Text(option.ref)
                        .lineLimit(1)
                        .truncationMode(.middle)
                      Spacer()
                    }
                  }
                  .buttonStyle(.plain)
                  .padding(.vertical, 3)
                }
              }
            }
            if groupedOptions.isEmpty {
              Text("No matching branches")
                .foregroundStyle(.secondary)
            }
          }
        }
        .frame(maxHeight: 260)
      }
      .padding(14)
      .frame(width: 420)
    }
  }

  private var displayTitle: String {
    guard let selection, !selection.isEmpty else {
      return title
    }
    return selection
  }

  private var invalidFieldBorder: some View {
    RoundedRectangle(cornerRadius: 5)
      .stroke(isInvalid ? Color.red : Color.clear, lineWidth: isInvalid ? 1.5 : 0)
      .allowsHitTesting(false)
  }

  private var groupedOptions: [(kind: GitBranchRefKind, options: [GitBranchRefOption])] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered =
      query.isEmpty
      ? options
      : options.filter { $0.ref.localizedCaseInsensitiveContains(query) }
    return GitBranchRefKind.allCases.compactMap { kind in
      let group = filtered.filter { $0.kind == kind }
      return group.isEmpty ? nil : (kind, group)
    }
  }
}
