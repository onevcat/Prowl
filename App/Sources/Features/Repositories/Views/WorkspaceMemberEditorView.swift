import AppKit
import ComposableArchitecture
import SwiftUI

/// Level two of the workspace sheet: one repository. Adding walks source
/// choice → configuration; editing an existing member shows name, role,
/// and the staged removal.
struct WorkspaceMemberEditorView: View {
  @Bindable var store: StoreOf<WorkspaceMemberEditorFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if store.existing != nil {
            existingSections
          } else if let draft = store.draft {
            configureSections(draft)
          } else {
            sourceSections
          }
        }
        .padding(.trailing, 4)
      }
      .frame(maxHeight: 520)

      if let message = store.validationMessage, !message.isEmpty {
        Text(message)
          .font(.footnote)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      footer
    }
    .padding(20)
  }

  // MARK: - Header / footer

  private var header: some View {
    HStack(spacing: 10) {
      Button {
        store.send(.backButtonTapped)
      } label: {
        Label("Back", systemImage: "chevron.left")
      }
      .help("Back to the workspace")
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.title3)
        if let subtitle {
          Text(subtitle)
            .font(.footnote.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
    }
  }

  private var title: LocalizedStringKey {
    switch store.mode {
    case .add:
      return "Add Repository"
    case .editAdded, .editExisting:
      return "Edit Repository"
    }
  }

  private var subtitle: String? {
    if let existing = store.existing {
      return existing.entry.sourceLocation ?? existing.entry.path
    }
    if let draft = store.draft {
      return draft.sourceLocation
    }
    return nil
  }

  private var footer: some View {
    HStack {
      if store.mode == .editAdded {
        Button("Remove Repository", role: .destructive) {
          store.send(.removeAddedButtonTapped)
        }
        .help("Remove this repository from the workspace before it is created")
      }
      Spacer()
      Button("Cancel") {
        store.send(.backButtonTapped)
      }
      .keyboardShortcut(.cancelAction)
      .help("Discard changes to this repository (Esc)")
      Button(commitTitle) {
        store.send(.commitButtonTapped)
      }
      .keyboardShortcut(.defaultAction)
      .help(commitHelp)
      .disabled(!store.isConfiguring || store.isLoadingBaseRefs)
    }
  }

  private var commitTitle: LocalizedStringKey {
    store.mode == .add ? "Add" : "Done"
  }

  private var commitHelp: String {
    store.mode == .add
      ? String(localized: "Add this repository to the workspace list (↩)")
      : String(localized: "Apply changes to this repository (↩)")
  }

  // MARK: - Step 1: source

  private var sourceSections: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Where does the repository come from?")
        .foregroundStyle(.secondary)
      sourceOption(
        .opened,
        title: "Opened in Prowl",
        detail: "Pick one of the repositories already in the sidebar.",
        systemImage: "folder.badge.plus",
        isEnabled: !store.openedCandidates.isEmpty
      )
      if store.sourceChoice == .opened {
        openedCandidateList
      }
      sourceOption(
        .local,
        title: "Local Folder…",
        detail: "Choose a git repository on disk.",
        systemImage: "folder",
        isEnabled: true
      )
      sourceOption(
        .remote,
        title: "Remote URL",
        detail: "Clone from an SSH or HTTPS git URL into the workspace.",
        systemImage: "network",
        isEnabled: true
      )
      if store.sourceChoice == .remote {
        remoteURLField
      }
    }
  }

  private func sourceOption(
    _ choice: WorkspaceMemberEditorFeature.SourceChoice,
    title: LocalizedStringKey,
    detail: LocalizedStringKey,
    systemImage: String,
    isEnabled: Bool
  ) -> some View {
    let isSelected = store.sourceChoice == choice
    return Button {
      if choice == .local {
        chooseLocalFolder()
      } else {
        store.send(.sourceChosen(choice))
      }
    } label: {
      HStack(spacing: 12) {
        Image(systemName: systemImage)
          .font(.title3)
          .frame(width: 24)
          .accessibilityHidden(true)
          .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .fontWeight(.medium)
          Text(detail)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if isSelected {
          Image(systemName: "checkmark")
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
      )
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .help(isEnabled ? "" : "Every opened repository is already in this workspace")
  }

  private var openedCandidateList: some View {
    VStack(spacing: 0) {
      ForEach(store.openedCandidates) { candidate in
        Button {
          store.send(.openedCandidateChosen(candidate.id))
        } label: {
          HStack {
            Text(candidate.name.isEmpty ? candidate.sourceLocation : candidate.name)
            Spacer()
            Text(candidate.sourceLocation)
              .font(.footnote.monospaced())
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Add \(candidate.name)")
        if candidate.id != store.openedCandidates.last?.id {
          Divider()
        }
      }
    }
    .clipShape(.rect(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    }
    .padding(.leading, 36)
  }

  private var remoteURLField: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        TextField(
          "git@github.com:owner/repo.git",
          text: Binding(
            get: { store.remoteURL },
            set: { store.send(.remoteURLChanged($0)) }
          )
        )
        .textFieldStyle(.roundedBorder)
        .font(.body.monospaced())
        .overlay {
          invalidFieldBorder(store.validationField == .remoteURL)
        }
        .onSubmit {
          store.send(.remoteURLCommitted)
        }
        if store.isLoadingRemote {
          ProgressView()
            .controlSize(.small)
        }
      }
      if let message = store.remoteErrorMessage {
        Text(message)
          .font(.footnote)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text(store.isLoadingRemote ? "Loading branches…" : "Branches load as soon as you finish typing.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.leading, 36)
  }

  // MARK: - Step 2: configure an added repository

  private func configureSections(_ draft: ProjectWorkspaceCreationRepository) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Name")
            .foregroundStyle(.secondary)
          TextField(
            "Repository name",
            text: Binding(
              get: { draft.name },
              set: { store.send(.nameChanged($0)) }
            )
          )
          .textFieldStyle(.roundedBorder)
          .overlay {
            invalidFieldBorder(store.validationField == .name)
          }
        }
        VStack(alignment: .leading, spacing: 6) {
          Text("Role")
            .foregroundStyle(.secondary)
          TextField(
            "Optional: app, backend, docs…",
            text: Binding(
              get: { draft.role ?? "" },
              set: { store.send(.roleChanged($0)) }
            )
          )
          .textFieldStyle(.roundedBorder)
        }
      }

      checkoutSection(draft)

      DisclosureGroup("Advanced", isExpanded: $store.isAdvancedExpanded) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Folder inside workspace")
            .foregroundStyle(.secondary)
          TextField(
            Self.defaultFolderName(for: draft),
            text: Binding(
              get: { draft.path ?? "" },
              set: { store.send(.pathChanged($0)) }
            )
          )
          .textFieldStyle(.roundedBorder)
          .font(.body.monospaced())
          Text("Defaults to the repository name. Prowl adds a suffix if the folder already exists.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
      }
    }
  }

  private func checkoutSection(_ draft: ProjectWorkspaceCreationRepository) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Checkout")
        .foregroundStyle(.secondary)
      Picker(
        "Checkout",
        selection: Binding(
          get: { draft.checkoutMode },
          set: { store.send(.checkoutModeChanged($0)) }
        )
      ) {
        if draft.sourceKind.supportsLinkCheckout {
          Text("Link").tag(ProjectWorkspaceRepositoryCheckoutMode.link)
        }
        Text("New Branch").tag(ProjectWorkspaceRepositoryCheckoutMode.createBranch)
        Text("Existing Branch").tag(ProjectWorkspaceRepositoryCheckoutMode.useExistingRef)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .help("How this repository is placed in the workspace")

      if draft.checkoutMode != .link {
        HStack(spacing: 8) {
          if draft.checkoutMode == .createBranch {
            TextField(
              "New branch name",
              text: Binding(
                get: { draft.branchName ?? "" },
                set: { store.send(.branchNameChanged($0)) }
              )
            )
            .textFieldStyle(.roundedBorder)
            .font(.body.monospaced())
            .overlay {
              invalidFieldBorder(store.validationField == .branchName)
            }
            Text("from")
              .foregroundStyle(.secondary)
          }
          WorkspaceBranchRefPickerView(
            title: draft.checkoutMode == .createBranch
              ? String(localized: "Base branch") : String(localized: "Branch"),
            selection: draft.baseRef,
            options: draft.baseRefOptions,
            isDisabled: store.isLoadingBaseRefs || draft.baseRefOptions.isEmpty,
            isInvalid: store.validationField == .baseRef
          ) { ref in
            store.send(.baseRefChanged(ref))
          }
          if store.isLoadingBaseRefs {
            ProgressView()
              .controlSize(.small)
          }
        }
      }
      Text(checkoutHelp(draft))
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if draft.checkoutMode != .link, let localBranchName = draft.resettableLocalBranchName {
        VStack(alignment: .leading, spacing: 4) {
          Text("Local branch “\(localBranchName)” already exists and would be reset to this ref.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Picker(
            "Local branch “\(localBranchName)”",
            selection: Binding(
              get: { draft.resetLocalBranchToRemote },
              set: { store.send(.resetLocalBranchChanged($0)) }
            )
          ) {
            Text("Use local branch").tag(false)
            Text("Reset to \(draft.baseRef ?? "remote")").tag(true)
          }
          .pickerStyle(.radioGroup)
          .labelsHidden()
        }
      }
    }
  }

  private func checkoutHelp(_ draft: ProjectWorkspaceCreationRepository) -> LocalizedStringKey {
    if draft.sourceKind == .remote {
      switch draft.checkoutMode {
      case .link, .useExistingRef:
        return "Clones the repository into the workspace and checks out the selected branch."
      case .createBranch:
        return "Clones the repository into the workspace and creates the new branch from the selected base."
      }
    }
    switch draft.checkoutMode {
    case .link:
      return "Adds a symlink to the source checkout. Edits in the workspace change the original folder directly."
    case .createBranch:
      return "Creates an isolated worktree on a new branch. The source checkout is left untouched."
    case .useExistingRef:
      if draft.resettableLocalBranchName != nil {
        return """
          Creates a worktree on the selected branch. \
          A matching local branch already exists; choose whether to keep or reset it.
          """
      }
      return "Creates a worktree on the selected branch, or a local tracking branch for a remote ref."
    }
  }

  static func defaultFolderName(for draft: ProjectWorkspaceCreationRepository) -> String {
    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? String(localized: "Folder name") : name
  }

  // MARK: - Existing member

  private var existingSections: some View {
    VStack(alignment: .leading, spacing: 16) {
      if let existing = store.existing {
        HStack(spacing: 8) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Name")
              .foregroundStyle(.secondary)
            TextField(
              existing.entry.name,
              text: Binding(
                get: { existing.name },
                set: { store.send(.existingNameChanged($0)) }
              )
            )
            .textFieldStyle(.roundedBorder)
            .disabled(existing.isMarkedForRemoval)
          }
          VStack(alignment: .leading, spacing: 6) {
            Text("Role")
              .foregroundStyle(.secondary)
            TextField(
              "Optional: app, backend, docs…",
              text: Binding(
                get: { existing.role },
                set: { store.send(.existingRoleChanged($0)) }
              )
            )
            .textFieldStyle(.roundedBorder)
            .disabled(existing.isMarkedForRemoval)
          }
        }

        VStack(alignment: .leading, spacing: 4) {
          Text("Checkout")
            .foregroundStyle(.secondary)
          Text(WorkspaceMemberSummary.existing(existing.entry))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
          Text(
            """
            Source and checkout are fixed once a repository is in the workspace. \
            Remove and add it again to change them.
            """
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 8) {
          Toggle(
            "Remove from Workspace on save",
            isOn: Binding(
              get: { existing.isMarkedForRemoval },
              set: { store.send(.existingRemovalChanged($0)) }
            )
          )
          .tint(.red)
          .help("The entry leaves the workspace metadata when you save.")
          if let removal = existing.removal {
            Toggle(
              "Also delete the folder inside the workspace",
              isOn: Binding(
                get: { removal.deleteFiles },
                set: { store.send(.existingDeleteFilesChanged($0)) }
              )
            )
            .padding(.leading, 20)
            .help(deleteFilesHelp(existing.entry))
            if existing.offersBranchDeletion, let branchName = existing.entry.branchName {
              Toggle(
                isOn: Binding(
                  get: { removal.deleteBranch },
                  set: { store.send(.existingDeleteBranchChanged($0)) }
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
              .disabled(!removal.deleteFiles)
              .help("Runs git branch -D after the worktree is removed. Protected branches are kept.")
            }
            Text("Files stay on disk unless you delete them here.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private func deleteFilesHelp(_ entry: ProjectWorkspaceRepositoryEntry) -> String {
    switch entry.sourceKind {
    case .remote:
      return String(localized: "Deletes the cloned folder, including any uncommitted work in it.")
    case .existingPath, .localRepository:
      if entry.branchName == nil, entry.baseRef == nil {
        return String(localized: "Removes only the symlink; the linked repository is untouched.")
      }
      return String(localized: "Unregisters the worktree from its source repository and deletes the folder.")
    case .bareRepository:
      return String(localized: "Unregisters the worktree from its source repository and deletes the folder.")
    }
  }

  // MARK: - Helpers

  private func chooseLocalFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = false
    panel.allowsMultipleSelection = false
    panel.prompt = String(localized: "Choose")
    panel.message = String(localized: "Choose a repository folder")
    panel.begin { response in
      guard response == .OK, let url = panel.url else {
        return
      }
      store.send(.localFolderChosen(url.path(percentEncoded: false)))
    }
  }

  private func invalidFieldBorder(_ isInvalid: Bool) -> some View {
    RoundedRectangle(cornerRadius: 5)
      .stroke(isInvalid ? Color.red : Color.clear, lineWidth: isInvalid ? 1.5 : 0)
      .allowsHitTesting(false)
  }
}

/// Plain-language summaries shared by the list rows and the member editor.
enum WorkspaceMemberSummary {
  static func existing(_ entry: ProjectWorkspaceRepositoryEntry) -> String {
    let location = entry.sourceLocation ?? entry.path
    switch entry.sourceKind {
    case .remote:
      if let ref = entry.branchName ?? entry.baseRef {
        return String(localized: "Clone of \(location) @ \(ref)")
      }
      return String(localized: "Clone of \(location)")
    case .existingPath, .localRepository:
      if let branchName = entry.branchName {
        return String(localized: "Worktree on \(branchName) from \(location)")
      }
      if let baseRef = entry.baseRef {
        return String(localized: "Worktree on \(baseRef) from \(location)")
      }
      return String(localized: "Link → shares the live checkout at \(location)")
    case .bareRepository:
      let ref = entry.branchName ?? entry.baseRef ?? "HEAD"
      return String(localized: "Worktree on \(ref) from \(location)")
    }
  }

  static func added(_ repository: ProjectWorkspaceCreationRepository) -> String {
    let location = repository.sourceLocation
    if repository.sourceKind == .remote {
      if repository.checkoutMode == .createBranch, let branch = repository.branchName, !branch.isEmpty {
        return String(localized: "Clone \(location), new branch \(branch)")
      }
      if let ref = repository.baseRef {
        return String(localized: "Clone \(location) @ \(ref)")
      }
      return String(localized: "Clone \(location)")
    }
    switch repository.checkoutMode {
    case .link:
      return String(localized: "Link → shares the live checkout at \(location)")
    case .createBranch:
      let branch = repository.branchName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let base = repository.baseRef ?? "HEAD"
      return branch.isEmpty
        ? String(localized: "New branch from \(base) → worktree")
        : String(localized: "New branch \(branch) from \(base) → worktree")
    case .useExistingRef:
      let ref = repository.baseRef ?? "?"
      return String(localized: "Existing branch \(ref) → worktree")
    }
  }
}

struct WorkspaceBranchRefPickerView: View {
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
      RoundedRectangle(cornerRadius: 5)
        .stroke(isInvalid ? Color.red : Color.clear, lineWidth: isInvalid ? 1.5 : 0)
        .allowsHitTesting(false)
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
