import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

@MainActor
struct ProjectWorkspaceTests {
  @Test func loadsWorkspaceMetadataWithDefaultsAndSnakeCaseSources() throws {
    let rootURL = try makeTemporaryWorkspaceRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try writeWorkspaceJSON(
      """
      {
        "title": "Multi Repo Task",
        "repositories": [
          {
            "role": "backend",
            "path": "api",
            "source_kind": "bare_repository",
            "source_location": "/Users/mikoto/Repos/api.git",
            "branch_name": "feature/workspace"
          },
          {
            "id": "web",
            "name": "Web",
            "path": "/tmp/web",
            "source_kind": "remote",
            "source_location": "git@github.com:onevcat/web.git"
          },
          {
            "name": "Shared",
            "path": "shared"
          }
        ]
      }
      """,
      to: rootURL
    )

    let workspace = try #require(ProjectWorkspace.load(from: rootURL))
    let rootPath = rootURL.standardizedFileURL.path(percentEncoded: false)

    #expect(workspace.id == rootPath)
    #expect(workspace.title == "Multi Repo Task")
    #expect(workspace.description == "")
    #expect(workspace.taskLinks == [])
    try #require(workspace.repositories.count == 3)

    let api = workspace.repositories[0]
    #expect(api.id == "api")
    #expect(api.name == "api")
    #expect(api.role == "backend")
    #expect(api.sourceKind == .bareRepository)
    #expect(api.sourceLocation == "/Users/mikoto/Repos/api.git")
    #expect(api.branchName == "feature/workspace")
    #expect(
      api.resolvedURL(relativeTo: rootURL).path(percentEncoded: false)
        == rootURL.appending(path: "api").standardizedFileURL.path(percentEncoded: false)
    )

    let web = workspace.repositories[1]
    #expect(web.id == "web")
    #expect(web.name == "Web")
    #expect(web.sourceKind == .remote)
    #expect(
      web.resolvedURL(relativeTo: rootURL).path(percentEncoded: false)
        == URL(fileURLWithPath: "/tmp/web").standardizedFileURL.path(percentEncoded: false)
    )

    let shared = workspace.repositories[2]
    #expect(shared.id == "shared")
    #expect(shared.name == "Shared")
    #expect(shared.sourceKind == .existingPath)
  }

  @Test func normalizesEmptyWorkspaceAndRepositoryFields() throws {
    let rootURL = URL(fileURLWithPath: "/tmp/prowl-workspace")

    let workspace = ProjectWorkspace(
      id: " ",
      title: " ",
      description: "  Touch app and API together  ",
      taskLinks: [" https://github.com/onevcat/Prowl/issues/1 ", " "],
      repositories: [
        ProjectWorkspace.RepositoryEntry(
          id: " ",
          name: " ",
          role: " ",
          path: " app ",
          sourceKind: .localRepository,
          sourceLocation: " ",
          branchName: " feature/workspace ",
          baseRef: " "
        )
      ]
    )
    .normalized(relativeTo: rootURL)

    #expect(workspace.id == "/tmp/prowl-workspace")
    #expect(workspace.title == "prowl-workspace")
    #expect(workspace.description == "Touch app and API together")
    #expect(workspace.taskLinks == ["https://github.com/onevcat/Prowl/issues/1"])

    let entry = try #require(workspace.repositories.first)
    #expect(entry.id == "app")
    #expect(entry.name == "app")
    #expect(entry.role == nil)
    #expect(entry.sourceKind == .localRepository)
    #expect(entry.sourceLocation == nil)
    #expect(entry.branchName == "feature/workspace")
    #expect(entry.baseRef == nil)
  }

  @Test func repositoryEntryNormalizerKeepsWorkspacePathPlain() throws {
    let rootURL = try makeTemporaryWorkspaceRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try writeWorkspaceJSON("{}", to: rootURL)

    let rootPath = rootURL.standardizedFileURL.path(percentEncoded: false)
    let normalized = RepositoryEntryNormalizer.normalize([
      PersistedRepositoryEntry(path: rootPath, kind: .git)
    ])

    #expect(normalized == [PersistedRepositoryEntry(path: rootPath, kind: .plain)])
  }

  @Test func listRuntimeContextsReportWorkspaceKind() {
    let rootURL = URL(fileURLWithPath: "/tmp/workspace")
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "Workspace",
      kind: .plain,
      worktrees: [],
      workspace: ProjectWorkspace(title: "Workspace")
    )
    var state = RepositoriesFeature.State()
    state.repositories = [repository]
    state.repositoryRoots = [rootURL]

    let contexts = ListRuntimeSnapshotBuilder.orderedWorktreeContexts(from: state)

    #expect(contexts.map(\.kind) == [.workspace])
    #expect(contexts.first?.id == repository.id)
  }

  private func makeTemporaryWorkspaceRoot() throws -> URL {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "prowl-workspace-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return rootURL
  }

  private func writeWorkspaceJSON(_ json: String, to rootURL: URL) throws {
    let metadataDirectoryURL = rootURL.appending(path: ProjectWorkspace.metadataDirectoryName)
    try FileManager.default.createDirectory(at: metadataDirectoryURL, withIntermediateDirectories: true)
    try Data(json.utf8).write(to: ProjectWorkspace.metadataURL(for: rootURL))
  }
}
