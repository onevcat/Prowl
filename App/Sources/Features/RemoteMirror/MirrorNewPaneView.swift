import SwiftUI

struct MirrorNewPaneView: View {
  @Bindable var model: MirrorLaunchModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("New Pane").font(.headline)
      Form {
        Picker("Worktree", selection: $model.worktreeID) {
          Text("Choose a worktree").tag(nil as String?)
          ForEach(model.worktrees) { worktree in
            Text(worktree.label).tag(Optional(worktree.id))
          }
        }
        Picker("Open", selection: $model.kind) {
          if model.supportsShell { Text("Shell").tag(MirrorLaunchModel.Kind.shell) }
          if model.supportsProfiles { Text("Agent Profile").tag(MirrorLaunchModel.Kind.agent) }
        }
        if model.kind == .agent {
          Picker("Profile", selection: $model.profileID) {
            Text("Choose a Profile").tag(nil as String?)
            ForEach(model.profiles) { profile in
              Text(profile.name + (profile.isAvailable ? "" : " — Unavailable"))
                .tag(Optional(profile.id))
                .disabled(!profile.isAvailable)
            }
          }
        }
      }
      if let worktree = model.worktrees.first(where: { $0.id == model.worktreeID }) {
        Text(worktree.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
      if model.kind == .agent {
        VStack(alignment: .leading, spacing: 6) {
          Text("Initial prompt (optional)").font(.subheadline)
          TextField("What should the Agent do?", text: $model.prompt, axis: .vertical)
            .lineLimit(3...6)
            .textFieldStyle(.roundedBorder)
        }
      }
      Text("The new tab opens in the background on Host and is mirrored here.")
        .font(.caption).foregroundStyle(.secondary)
      if model.isLoading { ProgressView("Loading Host configuration…").controlSize(.small) }
      if !model.isLoading, model.worktrees.isEmpty {
        Text("No worktrees are available. Add a project on Host, then refresh.")
          .foregroundStyle(.secondary)
      }
      if let error = model.error {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .disabled(model.isLoading || model.isCreating || model.creationUncertain)
    .task { await model.load() }
  }
}
