import SwiftUI

/// New Session (docs-ai 089 S3): shaped like the composer. The first message on top, and under
/// it two menus, where (a Host project and worktree) and who (an Agent Profile), and Start.
struct MirrorLaunchView: View {
  @State private var model: MirrorLaunchModel
  @State private var creationTask: Task<Void, Never>?
  @FocusState private var promptFocused: Bool
  /// The last Profile started from this device, chosen again next time when it is available.
  @AppStorage("mirror.lastProfileID") private var lastProfileID = ""
  let onCreated: (MirrorPaneDescriptor) -> Void
  /// The panes of the project the person started from (docs-ai 089 S1).
  private let paneIDs: [String]

  init(session: MirrorSession, onCreated: @escaping (MirrorPaneDescriptor) -> Void) {
    self.init(execute: { try await session.command($0) }, onCreated: onCreated)
  }

  init(
    execute: @escaping (MirrorCommandRequest.Command) async throws -> MirrorJSON,
    paneIDs: [String] = [],
    onCreated: @escaping (MirrorPaneDescriptor) -> Void
  ) {
    _model = State(initialValue: MirrorLaunchModel(execute: execute))
    self.paneIDs = paneIDs
    self.onCreated = onCreated
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if model.isLoading {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Loading projects and Profiles…")
        }
        .font(.footnote).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
      }
      VStack(alignment: .leading, spacing: 10) {
        TextField("What should the agent work on?", text: $model.prompt, axis: .vertical)
          .lineLimit(4...10)
          .focused($promptFocused)
          .autocorrectionDisabled()
          .padding(.horizontal, 6)
          .padding(.top, 6)
          .accessibilityIdentifier("launch-prompt")
        // Where and who on their own lines, so names do not truncate; Start sits at the corner.
        HStack(alignment: .bottom, spacing: 8) {
          VStack(alignment: .leading, spacing: 6) {
            projectMenu
            profileMenu
          }
          Spacer(minLength: 4)
          startButton
        }
      }
      .padding(10)
      .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
      if let error = model.error {
        MirrorFailureLabel(text: error).font(.footnote).accessibilityIdentifier("launch-error")
      } else if model.prompt.utf8.count > MirrorWire.maximumInput {
        MirrorFailureLabel(text: String(localized: "The message is too long.")).font(.footnote)
      } else {
        Text("Uses the Host Profile’s model, permissions and launch settings.")
          .font(.footnote).foregroundStyle(.secondary)
          .padding(.horizontal, 6)
      }
      if !model.isLoading, model.worktrees.isEmpty || model.profiles.isEmpty {
        emptyHints
      }
      Spacer(minLength: 0)
    }
    .padding()
    .disabled(model.isCreating)
    .navigationTitle("New Session")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("Done") { promptFocused = false }
          .accessibilityIdentifier("launch-prompt-done")
          .help("Hide the keyboard")
      }
      ToolbarItem(placement: .primaryAction) {
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
          .disabled(model.isLoading || model.isCreating)
          .help("Reload projects and Agent Profiles from the Host")
      }
    }
    .onDisappear { creationTask?.cancel() }
    .task { await load() }
  }

  private func load() async {
    if !paneIDs.isEmpty { model.focusProject(paneIDs: paneIDs) }
    await model.load()
    if model.profiles.contains(where: { $0.id == lastProfileID && $0.isAvailable }) {
      model.profileID = lastProfileID
    }
  }

  // MARK: - Where

  private var selectedWorktree: MirrorLaunchWorktree? {
    model.worktrees.first { $0.id == model.worktreeID }
  }

  /// Worktrees grouped by repository, in the Host's order.
  private var projects: [(name: String, worktrees: [MirrorLaunchWorktree])] {
    var order: [String] = []
    var byRoot: [String: [MirrorLaunchWorktree]] = [:]
    for worktree in model.worktrees {
      if byRoot[worktree.rootPath] == nil { order.append(worktree.rootPath) }
      byRoot[worktree.rootPath, default: []].append(worktree)
    }
    return order.map { root in (name: URL(fileURLWithPath: root).lastPathComponent, worktrees: byRoot[root] ?? []) }
  }

  private var projectMenu: some View {
    Menu {
      ForEach(projects, id: \.name) { project in
        if project.worktrees.count == 1, let only = project.worktrees.first {
          worktreeButton(only, label: project.name)
        } else {
          Menu(project.name) {
            ForEach(project.worktrees) { worktree in worktreeButton(worktree, label: worktree.name) }
          }
        }
      }
    } label: {
      chip(systemImage: "folder", text: selectedWorktree.map(\.label) ?? String(localized: "Choose a project"))
    }
    .disabled(model.worktrees.isEmpty)
    .accessibilityIdentifier("launch-project")
    .help("The Host project and worktree the agent runs in")
  }

  private func worktreeButton(_ worktree: MirrorLaunchWorktree, label: String) -> some View {
    Button {
      model.worktreeID = worktree.id
    } label: {
      if worktree.id == model.worktreeID {
        Label(label, systemImage: "checkmark")
      } else {
        Text(label)
      }
      Text(worktree.path)
    }
  }

  // MARK: - Who

  private var selectedProfile: MirrorLaunchProfile? {
    model.profiles.first { $0.id == model.profileID }
  }

  private var profileMenu: some View {
    Menu {
      ForEach(model.profiles) { profile in
        Button {
          model.profileID = profile.id
        } label: {
          // A menu shows a second Text as the subtitle only directly in the label.
          Text(profile.name)
          Text(profileDetail(profile))
          Image(systemName: profile.id == model.profileID ? "checkmark" : symbol(for: profile))
        }
        .disabled(!profile.isAvailable)
      }
    } label: {
      HStack(spacing: 6) {
        if let profile = selectedProfile {
          MirrorAgentIcon(agent: profile.runtime)
        } else {
          Image(systemName: "person.crop.circle.badge.questionmark")
        }
        Text(selectedProfile?.name ?? String(localized: "Choose a Profile")).lineLimit(1)
        Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
      }
      .font(.subheadline.weight(.medium))
      .padding(.horizontal, 10).padding(.vertical, 7)
      .background(Color(.tertiarySystemFill), in: Capsule())
    }
    .disabled(model.profiles.isEmpty)
    .accessibilityIdentifier("launch-profile")
    .help("The Agent Profile to start; its model and permissions come from the Mac")
  }

  private func profileDetail(_ profile: MirrorLaunchProfile) -> String {
    guard profile.isAvailable else {
      return profile.enabled
        ? profile.availability.reason ?? String(localized: "Unavailable") : String(localized: "Disabled")
    }
    let parts = [MirrorAgentIcon.displayName(for: profile.runtime), profile.model, profile.effort].compactMap { $0 }
    return parts.joined(separator: " · ")
  }

  private func symbol(for profile: MirrorLaunchProfile) -> String {
    if let icon = profile.icon, UIImage(systemName: icon) != nil { return icon }
    return "sparkle"
  }

  // MARK: - Start

  private var startButton: some View {
    Button {
      creationTask = Task {
        if let pane = await model.create(), !Task.isCancelled {
          if let id = model.profileID { lastProfileID = id }
          onCreated(pane)
        }
      }
    } label: {
      Group {
        if model.isCreating {
          ProgressView().tint(.white)
        } else {
          Image(systemName: "arrow.up").font(.body.weight(.bold))
        }
      }
      .foregroundStyle(.white)
      .frame(width: 34, height: 34)
      .background(model.canCreate ? Color.accentColor : Color(.systemGray3), in: Circle())
    }
    .disabled(!model.canCreate)
    .accessibilityLabel(model.isCreating ? "Starting" : "Start Session")
    .accessibilityIdentifier("create-and-mirror")
    .help("Start the agent on the Host and open it here")
  }

  private func chip(systemImage: String, text: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage)
      Text(text).lineLimit(1)
      Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }
    .font(.subheadline.weight(.medium))
    .padding(.horizontal, 10).padding(.vertical, 7)
    .background(Color(.tertiarySystemFill), in: Capsule())
  }

  @ViewBuilder private var emptyHints: some View {
    VStack(alignment: .leading, spacing: 6) {
      if model.worktrees.isEmpty {
        Label("Open a project in Prowl on the Mac, then refresh.", systemImage: "folder.badge.questionmark")
      }
      if model.profiles.isEmpty {
        Label("Configure an Agent Profile in Prowl on the Mac, then refresh.", systemImage: "person.badge.plus")
      }
    }
    .font(.footnote).foregroundStyle(.secondary)
    .padding(.horizontal, 6)
  }
}
