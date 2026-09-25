import AppKit
import ComposableArchitecture
import SwiftUI

/// Creates a workspace or edits an existing one. Both modes share the same
/// form; edit mode adds the already-materialized members as read-only
/// provenance rows with name/role editing, reordering, and staged removal.
struct WorkspaceEditorView: View {
  @Bindable var store: StoreOf<WorkspaceEditorFeature>
  @FocusState private var isTitleFieldFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      headerSection
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          titleSection
          if !store.mode.isEditing {
            folderSection
          }
          descriptionSection
          taskLinksSection
          repositoriesSection
        }
        .padding(.trailing, 4)
      }
      .frame(maxHeight: 560)

      if let message = store.validationMessage, !message.isEmpty {
        Text(message)
          .font(.footnote)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      footer
    }
    .padding(20)
    .frame(minWidth: 720)
    .task {
      isTitleFieldFocused = true
    }
    .interactiveDismissDisabled(store.isSaving)
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

  // MARK: - Sections

  private var headerSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(store.mode.isEditing ? "Edit Workspace" : "New Workspace")
        .font(.title3)
      if store.mode.isEditing {
        Text(store.rootPath)
          .font(.footnote.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }
      Text(repositoryCountText)
        .foregroundStyle(.secondary)
    }
  }

  private var titleSection: some View {
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
      .disabled(store.isSaving)
      .overlay {
        invalidFieldBorder(store.validationTarget == .title)
      }
      .onSubmit {
        store.send(.submitButtonTapped)
      }
      helpText(
        store.mode.isEditing
          ? "Display name shown in the sidebar and workspace metadata. The folder on disk keeps its name."
          : "A short name for the shared task folder shown in the sidebar and workspace metadata.")
    }
  }

  private var folderSection: some View {
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
        .disabled(store.isSaving)
        .overlay {
          invalidFieldBorder(store.validationTarget == .rootPath)
        }
        Button {
          chooseFolder()
        } label: {
          Label("Choose Folder", systemImage: "folder")
        }
        .help("Choose Workspace Folder")
        .disabled(store.isSaving)
      }
      Text(store.rootPathPreview)
        .font(.footnote.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
      helpText(
        "Where Prowl creates the workspace root. Until you edit it, this path follows the workspace title."
      )
    }
  }

  private var descriptionSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Description")
        .foregroundStyle(.secondary)
      TextField(
        "What this workspace is for",
        text: Binding(
          get: { store.description },
          set: { store.send(.descriptionChanged($0)) }
        ),
        axis: .vertical
      )
      .lineLimit(2...5)
      .textFieldStyle(.roundedBorder)
      .disabled(store.isSaving)
      helpText("Optional task summary shown in the workspace detail view and available to agents.")
    }
  }

  private var taskLinksSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Task Links")
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          store.send(.addTaskLinkButtonTapped)
        } label: {
          Label("Add Link", systemImage: "plus")
        }
        .controlSize(.small)
        .help("Add a task link or identifier")
        .disabled(store.isSaving)
      }
      ForEach(store.taskLinks) { link in
        HStack(spacing: 8) {
          TextField(
            "https://… or an issue key",
            text: Binding(
              get: { link.value },
              set: { store.send(.taskLinkChanged(link.id, $0)) }
            )
          )
          .textFieldStyle(.roundedBorder)
          .font(.body.monospaced())
          .disabled(store.isSaving)
          Button {
            store.send(.removeTaskLink(link.id))
          } label: {
            Image(systemName: "minus.circle")
              .accessibilityLabel("Remove Link")
          }
          .buttonStyle(.borderless)
          .help("Remove Link")
          .disabled(store.isSaving)
        }
      }
      helpText("Optional issue URLs or identifiers for the work item. Empty rows are dropped on save.")
    }
  }

  private var repositoriesSection: some View {
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
        .disabled(store.isSaving || store.availableOpenedRepositories.isEmpty)

        Button {
          store.send(.addRemoteButtonTapped)
        } label: {
          Label("Add Remote", systemImage: "network")
        }
        .help("Add Remote Repository")
        .disabled(store.isSaving)

        Button {
          chooseRepositorySource(kind: .localRepository)
        } label: {
          Label("Add Local", systemImage: "folder")
        }
        .help("Add Local Repository")
        .disabled(store.isSaving)
      }
      helpText(repositoriesHelpText)
      ScrollViewReader { proxy in
        VStack(spacing: 0) {
          ForEach(store.existingRepositories) { repository in
            existingRepositoryEditor(repository)
              .id(repository.id)
            Divider()
          }
          ForEach(store.repositories) { repository in
            repositoryEditor(repository)
              .id(repository.id)
            if repository.id != store.repositories.last?.id {
              Divider()
            }
          }
          if store.existingRepositories.isEmpty, store.repositories.isEmpty {
            Text("No repositories yet. Add one from the buttons above.")
              .font(.callout)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .center)
              .padding(.vertical, 24)
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
      .clipShape(.rect(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
      }
    }
  }

  private var repositoriesHelpText: LocalizedStringKey {
    if store.mode.isEditing {
      return """
        Added repositories are materialized when you save. \
        Existing members keep their source and checkout; remove and re-add one to change them.
        """
    }
    return "Add at least one repository. Opened and local repositories can be linked or materialized as worktrees."
  }

  private var footer: some View {
    HStack {
      if store.isSaving {
        ProgressView()
          .controlSize(.small)
        Text(store.mode.isEditing ? "Saving…" : "Creating…")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Cancel") {
        store.send(.cancelButtonTapped)
      }
      .keyboardShortcut(.cancelAction)
      .help(cancelHelp)
      .disabled(store.isSaving && store.mode.isEditing)
      Button(store.mode.isEditing ? "Save" : "Create") {
        store.send(.submitButtonTapped)
      }
      .keyboardShortcut(.defaultAction)
      .help(store.mode.isEditing ? "Save Workspace (↩)" : "Create Workspace (↩)")
      .disabled(store.isSaving)
    }
  }

  private var cancelHelp: String {
    if store.isSaving {
      return store.mode.isEditing
        ? String(localized: "Saving cannot be canceled")
        : String(localized: "Cancel creation and roll back (Esc)")
    }
    return String(localized: "Cancel (Esc)")
  }

  private var repositoryCountText: String {
    let count = store.remainingRepositoryCount
    var text = count == 1 ? String(localized: "1 repository") : String(localized: "\(count) repositories")
    if store.hasPendingRemovals {
      let removed = store.existingRepositories.filter(\.isMarkedForRemoval).count
      text +=
        removed == 1
        ? String(localized: ", 1 to remove") : String(localized: ", \(removed) to remove")
    }
    return text
  }

  // MARK: - Existing member rows

  private func existingRepositoryEditor(_ repository: WorkspaceEditorExistingRepository) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      existingRepositoryHeader(repository)
      if let removal = repository.removal {
        existingRepositoryRemovalOptions(repository, removal: removal)
      } else {
        existingRepositoryFields(repository)
        existingRepositoryProvenance(repository)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 10)
    .background {
      if repository.isMarkedForRemoval {
        Color.red.opacity(0.06)
      }
    }
  }

  private func existingRepositoryHeader(_ repository: WorkspaceEditorExistingRepository) -> some View {
    HStack(spacing: 10) {
      Text(repository.name.isEmpty ? repository.entry.name : repository.name)
        .fontWeight(.medium)
        .lineLimit(1)
        .strikethrough(repository.isMarkedForRemoval)
      sourceKindBadge(repository.entry.sourceKind)
      if repository.isMarkedForRemoval {
        Text("Removed on save")
          .font(.caption)
          .foregroundStyle(.red)
      }
      Spacer()
      Button {
        store.send(.existingRepositoryMovedUp(repository.id))
      } label: {
        Image(systemName: "chevron.up")
          .accessibilityLabel("Move Up")
      }
      .buttonStyle(.borderless)
      .help("Move Up")
      .disabled(store.isSaving || store.existingRepositories.first?.id == repository.id)
      Button {
        store.send(.existingRepositoryMovedDown(repository.id))
      } label: {
        Image(systemName: "chevron.down")
          .accessibilityLabel("Move Down")
      }
      .buttonStyle(.borderless)
      .help("Move Down")
      .disabled(store.isSaving || store.existingRepositories.last?.id == repository.id)
      if repository.isMarkedForRemoval {
        Button("Undo") {
          store.send(.existingRepositoryRemovalUndone(repository.id))
        }
        .controlSize(.small)
        .help("Keep this repository in the workspace")
        .disabled(store.isSaving)
      } else {
        Button {
          store.send(.existingRepositoryMarkedForRemoval(repository.id))
        } label: {
          Image(systemName: "trash")
            .accessibilityLabel("Remove from Workspace")
        }
        .buttonStyle(.borderless)
        .help("Remove from Workspace on save")
        .disabled(store.isSaving)
      }
    }
  }

  private func existingRepositoryFields(_ repository: WorkspaceEditorExistingRepository) -> some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Name")
          .foregroundStyle(.secondary)
        TextField(
          "Repository name",
          text: Binding(
            get: { repository.name },
            set: { store.send(.existingRepositoryNameChanged(repository.id, $0)) }
          )
        )
        .textFieldStyle(.roundedBorder)
        .disabled(store.isSaving)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("Role")
          .foregroundStyle(.secondary)
        TextField(
          "app, backend, docs…",
          text: Binding(
            get: { repository.role },
            set: { store.send(.existingRepositoryRoleChanged(repository.id, $0)) }
          )
        )
        .textFieldStyle(.roundedBorder)
        .disabled(store.isSaving)
      }
    }
  }

  private func existingRepositoryProvenance(_ repository: WorkspaceEditorExistingRepository) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(provenanceTitle(repository.entry))
        .font(.footnote)
        .foregroundStyle(.secondary)
      if let sourceLocation = repository.entry.sourceLocation, !sourceLocation.isEmpty {
        Text(sourceLocation)
          .font(.footnote.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
      }
    }
  }

  private func existingRepositoryRemovalOptions(
    _ repository: WorkspaceEditorExistingRepository,
    removal: WorkspaceEditorExistingRepository.Removal
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle(
        "Also delete the folder inside the workspace",
        isOn: Binding(
          get: { removal.deleteFiles },
          set: { store.send(.existingRepositoryDeleteFilesChanged(repository.id, $0)) }
        )
      )
      .help(removalDeleteFilesHelp(repository.entry))
      .disabled(store.isSaving)
      if repository.offersBranchDeletion, let branchName = repository.entry.branchName {
        Toggle(
          isOn: Binding(
            get: { removal.deleteBranch },
            set: { store.send(.existingRepositoryDeleteBranchChanged(repository.id, $0)) }
          )
        ) {
          HStack(spacing: 4) {
            Text("Delete branch")
            Text(branchName)
              .font(.body.monospaced())
            Text("in the source repository")
          }
        }
        .padding(.leading, 20)
        .help("Delete the branch with git branch -D after the worktree is removed. Protected branches are kept.")
        .disabled(store.isSaving || !removal.deleteFiles)
      }
      helpText(removalHelp(repository.entry))
    }
  }

  private func provenanceTitle(_ entry: ProjectWorkspaceRepositoryEntry) -> String {
    let location = entry.path
    switch entry.sourceKind {
    case .remote:
      if let baseRef = entry.branchName ?? entry.baseRef {
        return String(localized: "Clone of \(baseRef) at \(location)")
      }
      return String(localized: "Clone at \(location)")
    case .existingPath, .localRepository:
      if let branchName = entry.branchName {
        return String(localized: "Worktree on \(branchName) at \(location)")
      }
      if let baseRef = entry.baseRef {
        return String(localized: "Worktree on \(baseRef) at \(location)")
      }
      return String(localized: "Linked checkout at \(location)")
    case .bareRepository:
      let ref = entry.branchName ?? entry.baseRef ?? "HEAD"
      return String(localized: "Worktree on \(ref) at \(location)")
    }
  }

  private func removalDeleteFilesHelp(_ entry: ProjectWorkspaceRepositoryEntry) -> String {
    switch entry.sourceKind {
    case .remote:
      return String(localized: "Deletes the cloned folder, including any uncommitted work in it.")
    case .existingPath, .localRepository:
      if entry.branchName == nil, entry.baseRef == nil {
        return String(localized: "Removes only the symlink; the linked repository is untouched.")
      }
      return String(
        localized:
          "Unregisters the worktree from its source repository (git worktree remove --force) and deletes the folder.")
    case .bareRepository:
      return String(
        localized:
          "Unregisters the worktree from its source repository (git worktree remove --force) and deletes the folder.")
    }
  }

  private func removalHelp(_ entry: ProjectWorkspaceRepositoryEntry) -> LocalizedStringKey {
    "The entry leaves the workspace metadata when you save. Files stay on disk unless you delete them here."
  }

  // MARK: - New member rows

  private func repositoryEditor(_ repository: ProjectWorkspaceCreationRepository) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      repositoryHeader(repository)
      repositoryNameAndPathFields(repository)
      repositorySourceField(repository)
      repositoryBranchFields(repository)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 10)
  }

  private func repositoryHeader(_ repository: ProjectWorkspaceCreationRepository) -> some View {
    HStack(spacing: 10) {
      Text(repository.name.isEmpty ? String(localized: "Repository") : repository.name)
        .fontWeight(.medium)
        .lineLimit(1)

      sourceKindBadge(repository.sourceKind)

      if store.mode.isEditing {
        Text("Added on save")
          .font(.caption)
          .foregroundStyle(.tint)
      }

      Spacer()

      Button {
        store.send(.removeRepository(repository.id))
      } label: {
        Image(systemName: "trash")
          .accessibilityLabel("Remove Repository")
      }
      .buttonStyle(.borderless)
      .help("Remove Repository")
      .disabled(store.isSaving)
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
        .disabled(store.isSaving)
        .overlay {
          invalidFieldBorder(repositoryFieldIsInvalid(repository, .name))
        }
        helpText("Display name for this repository in the workspace metadata.")
      }

      VStack(alignment: .leading, spacing: 4) {
        Text("Role")
          .foregroundStyle(.secondary)
        TextField(
          "app, backend, docs…",
          text: Binding(
            get: { repository.role ?? "" },
            set: { store.send(.repositoryRoleChanged(repository.id, $0)) }
          )
        )
        .textFieldStyle(.roundedBorder)
        .disabled(store.isSaving)
        helpText("Optional short role that tells agents what this repository is for.")
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
        .disabled(store.isSaving)
        helpText(
          "Destination folder under the workspace root. It does not change the original source path."
        )
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
        .disabled(store.isSaving)
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
          .disabled(store.isSaving)
        }
      }
      helpText(sourceLocationHelpText(repository.sourceKind))
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
        .disabled(store.isSaving)

        if repository.checkoutMode == .createBranch {
          TextField(
            "Branch",
            text: Binding(
              get: { repository.branchName ?? "" },
              set: { store.send(.repositoryBranchNameChanged(repository.id, $0)) }
            )
          )
          .textFieldStyle(.roundedBorder)
          .disabled(store.isSaving)
          .overlay {
            invalidFieldBorder(repositoryFieldIsInvalid(repository, .branchName))
          }
        }

        if repository.checkoutMode != .link {
          WorkspaceBranchRefPickerView(
            title: repository.checkoutMode == .createBranch
              ? String(localized: "Base ref")
              : String(localized: "Existing branch"),
            selection: repository.baseRef,
            options: repository.baseRefOptions,
            isDisabled: store.isSaving || repository.baseRefOptions.isEmpty,
            isInvalid: repositoryFieldIsInvalid(repository, .baseRef)
          ) { ref in
            store.send(.repositoryBaseRefChanged(repository.id, ref))
          }
          .disabled(store.isSaving || repository.baseRefOptions.isEmpty)
        }
      }

      helpText(branchActionHelpText(repository))

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
            .disabled(store.isSaving)
          }
        }
      }
    }
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

  // MARK: - Panels

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = String(localized: "Choose")
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
    panel.prompt = String(localized: "Choose")
    if let currentPath, !currentPath.isEmpty {
      panel.directoryURL = URL(filePath: currentPath).deletingLastPathComponent()
    }
    panel.message =
      kind == .bareRepository
      ? String(localized: "Choose a bare repository folder")
      : String(localized: "Choose a repository folder")
    return panel
  }

  // MARK: - Copy helpers

  private func sourceKindTitle(_ kind: ProjectWorkspaceRepositorySourceKind) -> String {
    switch kind {
    case .existingPath:
      return String(localized: "Opened in Prowl")
    case .localRepository:
      return String(localized: "Picked from Disk")
    case .remote:
      return String(localized: "Remote Clone")
    case .bareRepository:
      return String(localized: "Bare Worktree")
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
      return String(localized: "Added from repositories already opened in Prowl.")
    case .localRepository:
      return String(localized: "Added by choosing a repository folder from disk.")
    case .remote:
      return String(localized: "Added from a remote URL and cloned into the workspace.")
    case .bareRepository:
      return String(localized: "Added from a local bare repository.")
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
      return String(localized: "Repository folder")
    case .remote:
      return String(localized: "Remote URL")
    case .bareRepository:
      return String(localized: "Bare repository folder")
    }
  }

  private func sourceLocationHelpText(_ kind: ProjectWorkspaceRepositorySourceKind) -> LocalizedStringKey {
    switch kind {
    case .existingPath:
      return
        """
        Existing opened repository path. Link keeps using this checkout; \
        branch actions create workspace worktrees from it.
        """
    case .localRepository:
      return
        "Local repository folder on disk. It can be linked as-is or used as the source for a workspace worktree."
    case .remote:
      return "Remote URL cloned into the workspace folder after branches are loaded."
    case .bareRepository:
      return "Advanced source: a local bare repository used only for git worktree materialization."
    }
  }

  private func branchActionHelpText(_ repository: ProjectWorkspaceCreationRepository) -> LocalizedStringKey {
    switch repository.checkoutMode {
    case .link:
      return
        "Link adds a symlink to the source checkout, so workspace edits affect the original folder directly."
    case .createBranch:
      return
        "Create Branch materializes an isolated checkout on a new branch from the selected base ref."
    case .useExistingRef:
      if repository.resettableLocalBranchName != nil {
        return
          """
          Use Existing checks out the selected branch. \
          If a matching local branch already exists, choose whether to keep or reset it.
          """
      }
      return
        "Use Existing checks out the selected local branch or creates a local tracking branch from a remote ref."
    }
  }

  private func helpText(_ text: LocalizedStringKey) -> some View {
    Text(text)
      .font(.footnote)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var validationRepositoryID: String? {
    switch store.validationTarget {
    case .repository(let repositoryID, _):
      return repositoryID
    case .existingRepository(let entryID):
      return entryID
    case .title, .rootPath, nil:
      return nil
    }
  }

  private func repositoryFieldIsInvalid(
    _ repository: ProjectWorkspaceCreationRepository,
    _ field: WorkspaceEditorFeature.RepositoryField
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
