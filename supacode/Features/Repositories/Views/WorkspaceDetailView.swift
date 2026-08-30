import SwiftUI

struct WorkspaceDetailView: View {
  let repository: Repository
  let workspace: ProjectWorkspace

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      header
      if !workspace.description.isEmpty {
        Text(workspace.description)
          .interfaceFont(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      if !workspace.taskLinks.isEmpty {
        taskLinks
      }
      repositoriesTable
      Spacer(minLength: 0)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "folder.badge.person.crop")
        .interfaceFont(.largeTitle)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(workspace.title)
          .interfaceFont(.title3, weight: .semibold)
          .textSelection(.enabled)
        Text(repository.rootURL.path(percentEncoded: false))
          .interfaceFont(.subheadline, design: .monospaced)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        Text(repositoryCountText)
          .interfaceFont(.subheadline)
          .foregroundStyle(.tertiary)
      }
    }
  }

  private var repositoryCountText: String {
    workspace.repositories.count == 1
      ? "1 repository" : "\(workspace.repositories.count) repositories"
  }

  private var taskLinks: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Task Links")
        .interfaceFont(.headline)
      ForEach(workspace.taskLinks, id: \.self) { link in
        Text(link)
          .interfaceFont(.subheadline, design: .monospaced)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
  }

  private var repositoriesTable: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Repositories")
        .interfaceFont(.headline)
      WorkspaceRepositoriesGridView(workspace: workspace, rootURL: repository.rootURL)
    }
  }
}
