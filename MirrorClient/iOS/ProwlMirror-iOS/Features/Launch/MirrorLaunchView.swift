import SwiftUI

struct MirrorLaunchView: View {
  @State private var model: MirrorLaunchModel
  @State private var creationTask: Task<Void, Never>?
  let onCreated: (MirrorPaneDescriptor) -> Void

  init(session: MirrorSession, onCreated: @escaping (MirrorPaneDescriptor) -> Void) {
    self.init(execute: { try await session.command($0) }, onCreated: onCreated)
  }

  init(execute: @escaping (MirrorCommandRequest.Command) async throws -> MirrorJSON,
    onCreated: @escaping (MirrorPaneDescriptor) -> Void) {
    _model = State(initialValue: MirrorLaunchModel(execute: execute))
    self.onCreated = onCreated
  }

  var body: some View {
    Form {
      Section("Workspace") {
        if model.worktrees.isEmpty {
          Text("No open workspaces. Open a workspace on Host, then refresh.").foregroundStyle(.secondary)
        } else {
          Picker("Workspace", selection: $model.worktreeID) {
            ForEach(model.worktrees) { worktree in
              Text(worktree.label).tag(Optional(worktree.id))
            }
          }
          if let chosen = model.worktrees.first(where: { $0.id == model.worktreeID }) {
            Text(chosen.path).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      Section {
        Picker("Agent Profile", selection: $model.profileID) {
          Text("Choose a Profile").tag(String?.none)
          ForEach(model.profiles.filter(\.isAvailable)) { profile in
            Text("\(profile.name) · \(profile.runtime)").tag(Optional(profile.id))
          }
        }
        ForEach(model.profiles.filter { !$0.isAvailable }) { profile in
          Text("\(profile.name): \(profile.enabled ? profile.availability.reason ?? "Unavailable" : "Disabled")")
            .font(.caption).foregroundStyle(.secondary)
        }
        if model.profiles.isEmpty {
          Text("Configure an Agent Profile in Prowl on Host, then refresh.").foregroundStyle(.secondary)
        }
      } header: { Text("Agent") } footer: {
        Text("Uses the Host Profile’s model, permissions and launch settings.")
      }
      Section("Initial message (optional)") {
        TextField("What should the Agent work on?", text: $model.prompt, axis: .vertical)
          .lineLimit(3...8)
          .accessibilityIdentifier("launch-prompt")
        if model.prompt.utf8.count > MirrorWire.maximumInput {
          Text("The message is too long.").foregroundStyle(.red)
        }
      }
      if let error = model.error {
        Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("launch-error") }
      }
      Section {
        Button {
          creationTask = Task {
            if let pane = await model.create(), !Task.isCancelled { onCreated(pane) }
          }
        } label: {
          HStack {
            Text(model.isCreating ? "Creating…" : "Create and Mirror")
            if model.isCreating { Spacer(); ProgressView() }
          }
        }
        .disabled(!model.canCreate)
        .accessibilityIdentifier("create-and-mirror")
        .help("Start an ordinary pane with this Host Profile and open its mirror")
      }
    }
    .disabled(model.isCreating)
    .navigationTitle("New Agent Pane")
    .onDisappear { creationTask?.cancel() }
    .toolbar {
      Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }
        .disabled(model.isLoading || model.isCreating)
        .help("Reload workspaces and Agent Profiles from Host")
    }
    .overlay { if model.isLoading { ProgressView("Loading Host configuration…") } }
    .task { await model.load() }
  }
}
