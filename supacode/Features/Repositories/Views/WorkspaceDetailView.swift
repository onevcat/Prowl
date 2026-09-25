import SwiftUI

struct WorkspaceDetailView: View {
  let repository: Repository
  let workspace: ProjectWorkspace
  var onEdit: (() -> Void)?

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
        Text(repositoryCountText)
          .font(.subheadline)
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 12)
      if let onEdit {
        Button {
          onEdit()
        } label: {
          Label("Edit Workspace…", systemImage: "folder.badge.gearshape")
        }
        .help("Edit the workspace title, description, links, and repositories")
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
        .font(.headline)
      ForEach(workspace.taskLinks, id: \.self) { link in
        if let url = Self.openableURL(link) {
          Link(destination: url) {
            Text(link)
              .font(.subheadline.monospaced())
          }
          .help("Open \(link)")
        } else {
          Text(link)
            .font(.subheadline.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
    }
  }

  private var repositoriesTable: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Repositories")
        .font(.headline)
      WorkspaceRepositoriesGridView(workspace: workspace, rootURL: repository.rootURL)
    }
  }

  /// Task links are free text (an issue key is as valid as a URL); only
  /// values with a web scheme become clickable.
  static func openableURL(_ link: String) -> URL? {
    guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https", url.host() != nil
    else {
      return nil
    }
    return url
  }
}
