import SwiftUI

struct WorkspaceDetailView: View {
  let repository: Repository
  let workspace: ProjectWorkspace

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      header
      if !workspace.description.isEmpty {
        Text(workspace.description)
          .font(.callout)
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
        .font(.largeTitle)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(workspace.title)
          .font(.title3.weight(.semibold))
          .textSelection(.enabled)
        Text(repository.rootURL.path(percentEncoded: false))
          .font(.subheadline.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        Text("\(workspace.repositories.count) repositories")
          .font(.subheadline)
          .foregroundStyle(.tertiary)
      }
    }
  }

  private var taskLinks: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Task Links")
        .font(.headline)
      ForEach(workspace.taskLinks, id: \.self) { link in
        Text(link)
          .font(.subheadline.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
    }
  }

  private var repositoriesTable: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Repositories")
        .font(.headline)
      if workspace.repositories.isEmpty {
        Text("No repositories are declared in this workspace metadata.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
          GridRow {
            tableHeader("Name")
            tableHeader("Role")
            tableHeader("Branch")
            tableHeader("Path")
          }
          Divider()
            .gridCellUnsizedAxes(.horizontal)
          ForEach(workspace.repositories) { entry in
            GridRow(alignment: .firstTextBaseline) {
              Text(entry.name)
                .font(.subheadline.weight(.medium))
              Text(entry.role ?? " ")
                .font(.subheadline)
                .foregroundStyle(.secondary)
              Text(entry.branchName ?? entry.baseRef ?? " ")
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
              Text(entry.resolvedURL(relativeTo: repository.rootURL).path(percentEncoded: false))
                .font(.subheadline.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            }
          }
        }
      }
    }
  }

  private func tableHeader(_ title: String) -> some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.tertiary)
  }
}
