import AppKit
import ComposableArchitecture
import SwiftUI

/// The workspace sheet. Level one (`WorkspacePanelView`) edits the workspace
/// metadata and lists its repositories; adding or editing one repository
/// swaps in `WorkspaceMemberEditorView` inside the same sheet.
struct WorkspaceEditorView: View {
  @Bindable var store: StoreOf<WorkspaceEditorFeature>

  var body: some View {
    Group {
      if let memberStore = store.scope(state: \.memberEditor, action: \.memberEditor.presented) {
        WorkspaceMemberEditorView(store: memberStore)
          .transition(.move(edge: .trailing).combined(with: .opacity))
      } else {
        WorkspacePanelView(store: store)
          .transition(.move(edge: .leading).combined(with: .opacity))
      }
    }
    .animation(.easeInOut(duration: 0.2), value: store.memberEditor == nil)
    .frame(width: 640)
    .interactiveDismissDisabled(store.isSaving)
  }
}

private struct WorkspacePanelView: View {
  @Bindable var store: StoreOf<WorkspaceEditorFeature>
  @FocusState private var isTitleFieldFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          titleSection
          descriptionSection
          taskLinksSection
          if !store.mode.isEditing {
            folderSection
          }
          repositoriesSection
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
    .task {
      isTitleFieldFocused = true
    }
  }

  private var header: some View {
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
      Text(
        "A workspace gathers several repositories in one folder so an agent can work across them from a single root."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var titleSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Title")
        .foregroundStyle(.secondary)
      TextField(
        "What this workspace is for, in a few words",
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
    }
  }

  private var descriptionSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Description")
        .foregroundStyle(.secondary)
      TextField(
        "Optional. Shown to you and to agents working in this workspace.",
        text: Binding(
          get: { store.description },
          set: { store.send(.descriptionChanged($0)) }
        ),
        axis: .vertical
      )
      .lineLimit(2...4)
      .textFieldStyle(.roundedBorder)
      .disabled(store.isSaving)
    }
  }

  private var taskLinksSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Task Links")
        .foregroundStyle(.secondary)
      TextField(
        "Optional. One issue URL or identifier per line.",
        text: Binding(
          get: { store.taskLinksText },
          set: { store.send(.taskLinksTextChanged($0)) }
        ),
        axis: .vertical
      )
      .lineLimit(1...4)
      .textFieldStyle(.roundedBorder)
      .font(.body.monospaced())
      .disabled(store.isSaving)
    }
  }

  private var folderSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Folder")
        .foregroundStyle(.secondary)
      HStack(spacing: 8) {
        Text(store.rootPathPreview)
          .font(.callout.monospaced())
          .foregroundStyle(store.validationTarget == .rootPath ? .red : .secondary)
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
        Spacer(minLength: 8)
        Button("Change…") {
          chooseFolder()
        }
        .controlSize(.small)
        .help("Choose a different folder for the workspace root")
        .disabled(store.isSaving)
      }
      Text(
        store.isRootPathDirty
          ? "Prowl creates the workspace in this folder."
          : "Follows the title until you change it. Prowl creates the workspace in this folder."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
    }
  }

  private var repositoriesSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Repositories")
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          store.send(.addRepositoryButtonTapped)
        } label: {
          Label("Add Repository…", systemImage: "plus")
        }
        .help("Add an opened, local, or remote repository to this workspace")
        .disabled(store.isSaving)
      }
      let members = store.orderedMembers
      VStack(spacing: 0) {
        if members.isEmpty {
          emptyRepositoriesState
        }
        ForEach(members) { member in
          WorkspaceMemberRowView(
            member: member,
            isEditing: store.mode.isEditing,
            isFirst: member.id == members.first?.id,
            isLast: member.id == members.last?.id,
            isDisabled: store.isSaving,
            onEdit: { store.send(.editMember(member.id)) },
            onRemove: { store.send(.removeMember(member.id)) },
            onUndo: {
              if case .existing(let id) = member.id {
                store.send(.undoRemoval(id))
              }
            },
            onMoveUp: { store.send(.memberMovedUp(member.id)) },
            onMoveDown: { store.send(.memberMovedDown(member.id)) }
          )
          if member.id != members.last?.id {
            Divider()
          }
        }
      }
      .clipShape(.rect(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(
            store.validationTarget == .repositories ? Color.red : Color(nsColor: .separatorColor),
            lineWidth: store.validationTarget == .repositories ? 1.5 : 1)
      }
    }
  }

  private var emptyRepositoriesState: some View {
    VStack(spacing: 6) {
      Image(systemName: "folder.badge.plus")
        .font(.title2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("No repositories yet")
        .font(.callout.weight(.medium))
      Text(
        "Add at least one. Each repository is linked, checked out on a branch, or cloned into the workspace folder."
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
    .padding(.horizontal, 16)
  }

  private var footer: some View {
    HStack(alignment: .center, spacing: 12) {
      if store.isSaving {
        ProgressView()
          .controlSize(.small)
      }
      Text(summaryText)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
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
      .disabled(store.isSaving || store.remainingRepositoryCount == 0)
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

  /// One line that says what Create / Save is about to do.
  private var summaryText: String {
    if store.isSaving {
      return store.mode.isEditing ? String(localized: "Saving…") : String(localized: "Creating…")
    }
    let added = store.repositories.count
    let removed = store.existingRepositories.filter(\.isMarkedForRemoval).count
    let remaining = store.remainingRepositoryCount
    if store.mode.isEditing {
      guard remaining > 0 else {
        return String(localized: "A workspace keeps at least one repository. Undo a removal or add one.")
      }
      guard added > 0 || removed > 0 else {
        return remaining == 1
          ? String(localized: "Save keeps 1 repository.")
          : String(localized: "Save keeps \(remaining) repositories.")
      }
      var parts: [String] = []
      if added > 0 {
        parts.append(added == 1 ? String(localized: "adds 1") : String(localized: "adds \(added)"))
      }
      if removed > 0 {
        parts.append(
          removed == 1 ? String(localized: "removes 1") : String(localized: "removes \(removed)"))
      }
      let changes = parts.formatted(.list(type: .and, width: .narrow))
      return String(localized: "Save \(changes); \(remaining) repositories afterwards.")
    }
    guard remaining > 0 else {
      return String(localized: "Add a repository to create the workspace.")
    }
    let kinds = Self.kindSummary(for: store.repositories)
    let folder = URL(filePath: store.rootPathPreview).lastPathComponent
    return remaining == 1
      ? String(localized: "Creates \(folder) with 1 repository (\(kinds)).")
      : String(localized: "Creates \(folder) with \(remaining) repositories (\(kinds)).")
  }

  private static func kindSummary(for repositories: IdentifiedArrayOf<ProjectWorkspaceCreationRepository>)
    -> String
  {
    var linked = 0
    var worktrees = 0
    var clones = 0
    for repository in repositories {
      if repository.sourceKind == .remote {
        clones += 1
      } else if repository.checkoutMode == .link {
        linked += 1
      } else {
        worktrees += 1
      }
    }
    var parts: [String] = []
    if linked > 0 {
      parts.append(linked == 1 ? String(localized: "1 link") : String(localized: "\(linked) links"))
    }
    if worktrees > 0 {
      parts.append(
        worktrees == 1 ? String(localized: "1 worktree") : String(localized: "\(worktrees) worktrees"))
    }
    if clones > 0 {
      parts.append(clones == 1 ? String(localized: "1 clone") : String(localized: "\(clones) clones"))
    }
    return parts.formatted(.list(type: .and, width: .narrow))
  }

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

  private func invalidFieldBorder(_ isInvalid: Bool) -> some View {
    RoundedRectangle(cornerRadius: 5)
      .stroke(isInvalid ? Color.red : Color.clear, lineWidth: isInvalid ? 1.5 : 0)
      .allowsHitTesting(false)
  }
}

/// One repository in the workspace list: name, role, and a plain sentence
/// saying what Create / Save does with it.
private struct WorkspaceMemberRowView: View {
  let member: WorkspaceEditorMember
  let isEditing: Bool
  let isFirst: Bool
  let isLast: Bool
  let isDisabled: Bool
  let onEdit: () -> Void
  let onRemove: () -> Void
  let onUndo: () -> Void
  let onMoveUp: () -> Void
  let onMoveDown: () -> Void

  @State private var isHovered = false

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: iconName)
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(name)
            .fontWeight(.medium)
            .strikethrough(isMarkedForRemoval)
            .lineLimit(1)
          if let role, !role.isEmpty {
            Text(role)
              .font(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          if let status = pendingStatus {
            Text(status.text)
              .font(.caption)
              .foregroundStyle(status.isRemoval ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
          }
        }
        Text(summary)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 8)
      HStack(spacing: 4) {
        if isMarkedForRemoval {
          Button("Undo", action: onUndo)
            .controlSize(.small)
            .help("Keep this repository in the workspace")
        } else {
          Button(action: onEdit) {
            Image(systemName: "pencil")
              .accessibilityLabel("Edit Repository")
          }
          .buttonStyle(.borderless)
          .help("Edit this repository")
          Button(action: onRemove) {
            Image(systemName: "trash")
              .accessibilityLabel("Remove Repository")
          }
          .buttonStyle(.borderless)
          .help(isExisting ? "Remove from the workspace on save" : "Remove this repository")
        }
      }
      .opacity(isHovered || isMarkedForRemoval ? 1 : 0.35)
      .disabled(isDisabled)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background {
      if isMarkedForRemoval {
        Color.red.opacity(0.06)
      } else if isHovered {
        Color.primary.opacity(0.04)
      }
    }
    .contentShape(.rect)
    .onHover { isHovered = $0 }
    .contextMenu {
      Button("Edit…", action: onEdit)
        .disabled(isMarkedForRemoval)
      Divider()
      Button("Move Up", action: onMoveUp)
        .disabled(isFirst)
      Button("Move Down", action: onMoveDown)
        .disabled(isLast)
      Divider()
      if isMarkedForRemoval {
        Button("Undo Removal", action: onUndo)
      } else {
        Button("Remove", action: onRemove)
      }
    }
    .help(summary)
  }

  private var isExisting: Bool {
    if case .existing = member { return true }
    return false
  }

  private var isMarkedForRemoval: Bool {
    if case .existing(let repository) = member { return repository.isMarkedForRemoval }
    return false
  }

  private var name: String {
    switch member {
    case .existing(let repository):
      let trimmed = repository.name.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? repository.entry.name : trimmed
    case .added(let repository):
      return repository.name.isEmpty ? String(localized: "Repository") : repository.name
    }
  }

  private var role: String? {
    switch member {
    case .existing(let repository):
      return repository.role
    case .added(let repository):
      return repository.role
    }
  }

  private var iconName: String {
    switch member {
    case .existing(let repository):
      switch repository.entry.sourceKind {
      case .remote:
        return "network"
      case .existingPath, .localRepository, .bareRepository:
        return repository.entry.branchName == nil && repository.entry.baseRef == nil
          ? "link" : "arrow.triangle.branch"
      }
    case .added(let repository):
      if repository.sourceKind == .remote {
        return "network"
      }
      return repository.checkoutMode == .link ? "link" : "arrow.triangle.branch"
    }
  }

  private var pendingStatus: (text: String, isRemoval: Bool)? {
    switch member {
    case .existing(let repository):
      return repository.isMarkedForRemoval ? (String(localized: "Removed on save"), true) : nil
    case .added:
      return isEditing ? (String(localized: "Added on save"), false) : nil
    }
  }

  /// What Create / Save does with this row, in one sentence.
  private var summary: String {
    switch member {
    case .existing(let repository):
      return WorkspaceMemberSummary.existing(repository.entry)
    case .added(let repository):
      return WorkspaceMemberSummary.added(repository)
    }
  }
}
