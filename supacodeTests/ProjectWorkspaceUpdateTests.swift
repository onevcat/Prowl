import ComposableArchitecture
import Foundation
import Testing

@testable import supacode

@MainActor
struct ProjectWorkspaceUpdateTests {
  @Test func createWritesDescriptionTaskLinksAndRoleAndAllowsOneRepository() async throws {
    let rootURL = try makeTemporaryRoot(prefix: "prowl-create-single")
    let appURL = try makeTemporaryRoot(prefix: "prowl-app")
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: appURL)
    }

    let workspace = try await ProjectWorkspace.create(
      ProjectWorkspaceCreationRequest(
        draft: ProjectWorkspaceCreationDraft(
          title: "Solo",
          description: "  One repo to start  ",
          taskLinks: ["https://example.com/1"],
          rootURL: rootURL,
          repositories: [
            ProjectWorkspaceRepositoryPlan(
              id: "app",
              name: "App",
              role: " macOS app ",
              path: nil,
              sourceKind: .existingPath,
              sourceLocation: appURL.path(percentEncoded: false),
              checkout: .link
            )
          ]
        ),
        createdAt: Date(timeIntervalSince1970: 1_000)
      ),
      gitRunner: failingGitRunner
    )

    #expect(workspace.description == "One repo to start")
    #expect(workspace.taskLinks == ["https://example.com/1"])
    #expect(workspace.repositories.map(\.role) == ["macOS app"])
    let loaded = try #require(ProjectWorkspace.load(from: rootURL))
    #expect(loaded.repositories.count == 1)
    #expect(loaded.repositories[0].role == "macOS app")
  }

  @Test func createRejectsEmptyRepositoryList() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "prowl-create-empty-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    await #expect(throws: ProjectWorkspaceCreationError.notEnoughRepositories) {
      try await ProjectWorkspace.create(
        ProjectWorkspaceCreationRequest(
          draft: ProjectWorkspaceCreationDraft(title: "Empty", rootURL: rootURL, repositories: []),
          createdAt: Date()
        ),
        gitRunner: failingGitRunner
      )
    }
    #expect(!FileManager.default.fileExists(atPath: rootURL.path(percentEncoded: false)))
  }

  @Test func updateRewritesMetadataAndPreservesUnknownKeys() async throws {
    let rootURL = try makeTemporaryRoot(prefix: "prowl-update-meta")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try writeWorkspaceJSON(
      """
      {
        "schema_version": "prowl.workspace.v1",
        "title": "Old Title",
        "description": "Old description",
        "task_links": ["OLD-1"],
        "created_at": "2026-01-02T03:04:05Z",
        "agent_guide": { "enabled": true },
        "repositories": [
          {
            "id": "app",
            "name": "App",
            "role": "app",
            "path": "app",
            "source_kind": "existing_path",
            "source_location": "/tmp/source/app",
            "agent_notes": "keep me"
          },
          {
            "name": "API",
            "path": "api",
            "source_kind": "remote",
            "source_location": "git@github.com:onevcat/api.git",
            "base_ref": "origin/main",
            "bootstrap": { "script_ids": ["install"] }
          }
        ]
      }
      """,
      to: rootURL
    )
    let existing = try #require(ProjectWorkspace.load(from: rootURL))
    var app = try #require(existing.repositories.first { $0.id == "app" })
    app.name = "Mac App"
    app.role = nil
    let api = try #require(existing.repositories.first { $0.id == "api" })
    let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)

    let result = try await ProjectWorkspace.update(
      ProjectWorkspaceUpdateRequest(
        rootURL: rootURL,
        title: "  New Title ",
        description: "New description",
        taskLinks: ["https://example.com/2"],
        members: [.existing(api), .existing(app)],
        updatedAt: updatedAt
      ),
      gitRunner: failingGitRunner
    )

    #expect(result.cleanupFailures.isEmpty)
    #expect(result.workspace.title == "New Title")
    #expect(result.workspace.repositories.map(\.id) == ["api", "app"])
    #expect(result.workspace.createdAt == ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z"))
    #expect(result.workspace.updatedAt == updatedAt)

    let data = try Data(contentsOf: ProjectWorkspace.metadataURL(for: rootURL))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["title"] as? String == "New Title")
    #expect(object["description"] as? String == "New description")
    #expect(object["task_links"] as? [String] == ["https://example.com/2"])
    #expect((object["agent_guide"] as? [String: Any])?["enabled"] as? Bool == true)
    let repositories = try #require(object["repositories"] as? [[String: Any]])
    #expect(repositories.map { $0["id"] as? String } == ["api", "app"])
    let savedApp = try #require(repositories.last)
    #expect(savedApp["name"] as? String == "Mac App")
    #expect(savedApp["role"] == nil)
    #expect(savedApp["agent_notes"] as? String == "keep me")
    // An entry that had no `id` on disk is matched through its path.
    let savedAPI = try #require(repositories.first)
    #expect(savedAPI["id"] as? String == "api")
    #expect((savedAPI["bootstrap"] as? [String: Any])?["script_ids"] as? [String] == ["install"])

    let reloaded = try #require(ProjectWorkspace.load(from: rootURL))
    #expect(reloaded.repositories.map(\.name) == ["API", "Mac App"])
    #expect(reloaded.repositories.map(\.role) == [nil, nil])
  }

  @Test func updateMaterializesAddedMemberAndRollsBackWithoutTouchingExisting() async throws {
    let rootURL = try makeTemporaryRoot(prefix: "prowl-update-add")
    let appURL = try makeTemporaryRoot(prefix: "prowl-app")
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: appURL)
    }
    let existing = try await createLinkedWorkspace(rootURL: rootURL, appURL: appURL)
    let appEntry = try #require(existing.repositories.first)
    let cloneDestination = rootURL.appending(path: "api", directoryHint: .isDirectory)
    let commands = LockIsolated<[ProjectWorkspaceGitCommand]>([])
    let failingRunner = ProjectWorkspaceGitRunner { command in
      commands.withValue { $0.append(command) }
      if command.arguments.first == "clone" {
        try FileManager.default.createDirectory(at: cloneDestination, withIntermediateDirectories: true)
      }
      if command.arguments.contains("checkout") {
        throw ProjectWorkspaceCreationError.gitCommandFailed(command: command.displayCommand, message: "boom")
      }
    }
    let addedPlan = ProjectWorkspaceRepositoryPlan(
      id: "api",
      name: "API",
      role: "backend",
      path: "api",
      sourceKind: .remote,
      sourceLocation: "git@github.com:onevcat/api.git",
      checkout: .useExistingRef("origin/main")
    )

    await #expect(throws: ProjectWorkspaceCreationError.self) {
      try await ProjectWorkspace.update(
        ProjectWorkspaceUpdateRequest(
          rootURL: rootURL,
          title: "Changed",
          members: [.existing(appEntry), .added(addedPlan)],
          updatedAt: Date()
        ),
        gitRunner: failingRunner
      )
    }

    #expect(!FileManager.default.fileExists(atPath: cloneDestination.path(percentEncoded: false)))
    let appLinkPath = appEntry.resolvedURL(relativeTo: rootURL).path(percentEncoded: false)
    #expect(
      (try? URL(fileURLWithPath: appLinkPath).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    )
    let unchanged = try #require(ProjectWorkspace.load(from: rootURL))
    #expect(unchanged.title == existing.title)
    #expect(unchanged.repositories.map(\.id) == ["app"])

    let succeedingRunner = ProjectWorkspaceGitRunner { command in
      if command.arguments.first == "clone" {
        try FileManager.default.createDirectory(at: cloneDestination, withIntermediateDirectories: true)
      }
    }
    let result = try await ProjectWorkspace.update(
      ProjectWorkspaceUpdateRequest(
        rootURL: rootURL,
        title: "Changed",
        members: [.existing(appEntry), .added(addedPlan)],
        updatedAt: Date()
      ),
      gitRunner: succeedingRunner
    )
    #expect(result.workspace.repositories.map(\.id) == ["app", "api"])
    #expect(result.workspace.repositories.last?.role == "backend")
    #expect(result.workspace.repositories.last?.baseRef == "origin/main")
    #expect(ProjectWorkspace.load(from: rootURL)?.title == "Changed")
  }

  @Test func updateSuffixesAddedPathOccupiedByRemovedMemberLeftOnDisk() async throws {
    let rootURL = try makeTemporaryRoot(prefix: "prowl-update-suffix")
    let appURL = try makeTemporaryRoot(prefix: "prowl-app")
    let otherURL = try makeTemporaryRoot(prefix: "prowl-other")
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: appURL)
      try? FileManager.default.removeItem(at: otherURL)
    }
    let existing = try await createLinkedWorkspace(rootURL: rootURL, appURL: appURL)
    let appEntry = try #require(existing.repositories.first)

    let result = try await ProjectWorkspace.update(
      ProjectWorkspaceUpdateRequest(
        rootURL: rootURL,
        title: existing.title,
        members: [
          .added(
            ProjectWorkspaceRepositoryPlan(
              id: "app-again",
              name: "App",
              path: "app",
              sourceKind: .localRepository,
              sourceLocation: otherURL.path(percentEncoded: false),
              checkout: .link
            ))
        ],
        removals: [ProjectWorkspaceRepositoryRemoval(entry: appEntry, deleteFiles: false)],
        updatedAt: Date()
      ),
      gitRunner: failingGitRunner
    )

    #expect(result.workspace.repositories.map(\.path) == ["app-2"])
    #expect(result.cleanupFailures.isEmpty)
    #expect(result.completedRemovals.isEmpty)
    // The removed member's symlink was kept because deleteFiles was false.
    #expect(FileManager.default.fileExists(atPath: rootURL.appending(path: "app").path(percentEncoded: false)))
  }

  @Test func updateRemovesSymlinkForLinkedMemberWhenDeletingFiles() async throws {
    let rootURL = try makeTemporaryRoot(prefix: "prowl-update-unlink")
    let appURL = try makeTemporaryRoot(prefix: "prowl-app")
    let apiURL = try makeTemporaryRoot(prefix: "prowl-api")
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: appURL)
      try? FileManager.default.removeItem(at: apiURL)
    }
    let existing = try await createLinkedWorkspace(rootURL: rootURL, appURL: appURL, apiURL: apiURL)
    let appEntry = try #require(existing.repositories.first { $0.id == "app" })
    let apiEntry = try #require(existing.repositories.first { $0.id == "api" })

    let result = try await ProjectWorkspace.update(
      ProjectWorkspaceUpdateRequest(
        rootURL: rootURL,
        title: existing.title,
        members: [.existing(apiEntry)],
        removals: [ProjectWorkspaceRepositoryRemoval(entry: appEntry, deleteFiles: true)],
        updatedAt: Date()
      ),
      gitRunner: failingGitRunner
    )

    #expect(result.cleanupFailures.isEmpty)
    #expect(result.completedRemovals.map(\.id) == ["app"])
    let appLinkPath = rootURL.appending(path: "app").path(percentEncoded: false)
    #expect(!FileManager.default.fileExists(atPath: appLinkPath))
    #expect(
      (try? URL(fileURLWithPath: appLinkPath).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
    )
    // The linked source repository is untouched.
    #expect(FileManager.default.fileExists(atPath: appURL.path(percentEncoded: false)))
    #expect(ProjectWorkspace.load(from: rootURL)?.repositories.map(\.id) == ["api"])
  }

  @Test func updateUnregistersWorktreeMemberAndReportsFailedCleanup() async throws {
    let rootURL = try makeTemporaryRoot(prefix: "prowl-update-worktree")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let worktreeURL = rootURL.appending(path: "api", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
    let keptURL = rootURL.appending(path: "app", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: keptURL, withIntermediateDirectories: true)
    try writeWorkspaceJSON(
      """
      {
        "title": "Worktrees",
        "repositories": [
          { "id": "app", "name": "App", "path": "app", "source_kind": "remote",
            "source_location": "git@github.com:onevcat/app.git" },
          { "id": "api", "name": "API", "path": "api", "source_kind": "local_repository",
            "source_location": "/tmp/source/api", "branch_name": "feature/api" }
        ]
      }
      """,
      to: rootURL
    )
    let existing = try #require(ProjectWorkspace.load(from: rootURL))
    let appEntry = try #require(existing.repositories.first { $0.id == "app" })
    let apiEntry = try #require(existing.repositories.first { $0.id == "api" })
    let commands = LockIsolated<[ProjectWorkspaceGitCommand]>([])
    let worktreePath = normalizedPath(worktreeURL)

    let failed = try await ProjectWorkspace.update(
      ProjectWorkspaceUpdateRequest(
        rootURL: rootURL,
        title: "Worktrees",
        members: [.existing(appEntry)],
        removals: [ProjectWorkspaceRepositoryRemoval(entry: apiEntry, deleteFiles: true, deleteBranch: true)],
        updatedAt: Date()
      ),
      gitRunner: ProjectWorkspaceGitRunner { command in
        commands.withValue { $0.append(command) }
        throw ProjectWorkspaceCreationError.gitCommandFailed(command: command.displayCommand, message: "locked")
      }
    )

    #expect(
      commands.value.map(\.arguments) == [
        ["-C", "/tmp/source/api", "worktree", "remove", "--force", worktreePath]
      ])
    #expect(failed.cleanupFailures.map(\.entryID) == ["api"])
    #expect(failed.completedRemovals.isEmpty)
    // The metadata is already committed without the entry; the folder stays.
    #expect(ProjectWorkspace.load(from: rootURL)?.repositories.map(\.id) == ["app"])
    #expect(FileManager.default.fileExists(atPath: worktreePath))

    // A second attempt after the metadata dropped the entry is a plain
    // "remove a folder Prowl does not know" — the removal list is what drives it.
    let removed = try await ProjectWorkspace.update(
      ProjectWorkspaceUpdateRequest(
        rootURL: rootURL,
        title: "Worktrees",
        members: [.existing(appEntry)],
        removals: [ProjectWorkspaceRepositoryRemoval(entry: apiEntry, deleteFiles: true, deleteBranch: true)],
        updatedAt: Date()
      ),
      gitRunner: ProjectWorkspaceGitRunner { _ in
        try FileManager.default.removeItem(at: worktreeURL)
      }
    )
    #expect(removed.cleanupFailures.isEmpty)
    #expect(removed.completedRemovals.map(\.id) == ["api"])
    #expect(removed.completedRemovals.first?.deleteBranch == true)
    #expect(!FileManager.default.fileExists(atPath: worktreePath))
  }

  @Test func updateDeletesCloneFolderAndNeverTouchesPathsOutsideRoot() async throws {
    let rootURL = try makeTemporaryRoot(prefix: "prowl-update-clone")
    let outsideURL = try makeTemporaryRoot(prefix: "prowl-outside")
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: outsideURL)
    }
    let cloneURL = rootURL.appending(path: "api", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: cloneURL, withIntermediateDirectories: true)
    let outsidePath = outsideURL.standardizedFileURL.path(percentEncoded: false)
    try writeWorkspaceJSON(
      """
      {
        "title": "Clones",
        "repositories": [
          { "id": "api", "name": "API", "path": "api", "source_kind": "remote",
            "source_location": "git@github.com:onevcat/api.git" },
          { "id": "ext", "name": "External", "path": "\(outsidePath)", "source_kind": "existing_path" },
          { "id": "keep", "name": "Keep", "path": "keep", "source_kind": "existing_path" }
        ]
      }
      """,
      to: rootURL
    )
    let existing = try #require(ProjectWorkspace.load(from: rootURL))
    let apiEntry = try #require(existing.repositories.first { $0.id == "api" })
    let extEntry = try #require(existing.repositories.first { $0.id == "ext" })
    let keepEntry = try #require(existing.repositories.first { $0.id == "keep" })

    let result = try await ProjectWorkspace.update(
      ProjectWorkspaceUpdateRequest(
        rootURL: rootURL,
        title: "Clones",
        members: [.existing(keepEntry)],
        removals: [
          ProjectWorkspaceRepositoryRemoval(entry: apiEntry, deleteFiles: true),
          ProjectWorkspaceRepositoryRemoval(entry: extEntry, deleteFiles: true),
        ],
        updatedAt: Date()
      ),
      gitRunner: failingGitRunner
    )

    #expect(!FileManager.default.fileExists(atPath: cloneURL.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: outsidePath))
    #expect(result.cleanupFailures.map(\.entryID) == ["ext"])
    #expect(result.completedRemovals.map(\.id) == ["api"])
  }

  @Test func updateNeverDeletesRemoteEntryWithoutRecordedSource() async throws {
    let rootURL = try makeTemporaryRoot(prefix: "prowl-update-sourceless")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let folderURL = rootURL.appending(path: "api", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    let sentinelURL = folderURL.appending(path: "notes.txt")
    try Data("keep".utf8).write(to: sentinelURL)
    try writeWorkspaceJSON(
      """
      {
        "title": "Sourceless",
        "repositories": [
          { "id": "app", "name": "App", "path": "app", "source_kind": "existing_path" },
          { "id": "api", "name": "API", "path": "api", "source_kind": "remote" }
        ]
      }
      """,
      to: rootURL
    )
    let existing = try #require(ProjectWorkspace.load(from: rootURL))
    let appEntry = try #require(existing.repositories.first { $0.id == "app" })
    let apiEntry = try #require(existing.repositories.first { $0.id == "api" })
    #expect(apiEntry.sourceLocation == nil)

    let result = try await ProjectWorkspace.update(
      ProjectWorkspaceUpdateRequest(
        rootURL: rootURL,
        title: "Sourceless",
        members: [.existing(appEntry)],
        removals: [ProjectWorkspaceRepositoryRemoval(entry: apiEntry, deleteFiles: true)],
        updatedAt: Date()
      ),
      gitRunner: failingGitRunner
    )

    // Ownership cannot be established, so the folder stays and is reported.
    #expect(result.cleanupFailures.map(\.entryID) == ["api"])
    #expect(result.completedRemovals.isEmpty)
    #expect(FileManager.default.fileExists(atPath: sentinelURL.path(percentEncoded: false)))
    #expect(ProjectWorkspace.load(from: rootURL)?.repositories.map(\.id) == ["app"])
  }

  @Test func updateRejectsInvalidRequests() async throws {
    let rootURL = try makeTemporaryRoot(prefix: "prowl-update-invalid")
    let appURL = try makeTemporaryRoot(prefix: "prowl-app")
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: appURL)
    }
    let missingRoot = FileManager.default.temporaryDirectory
      .appending(path: "prowl-missing-\(UUID().uuidString)")

    await #expect(throws: ProjectWorkspaceCreationError.self) {
      try await ProjectWorkspace.update(
        ProjectWorkspaceUpdateRequest(
          rootURL: missingRoot, title: "X", members: [.existing(ProjectWorkspaceRepositoryEntry(id: "a", path: "a"))],
          updatedAt: Date()),
        gitRunner: failingGitRunner
      )
    }

    let existing = try await createLinkedWorkspace(rootURL: rootURL, appURL: appURL)
    let appEntry = try #require(existing.repositories.first)
    await #expect(throws: ProjectWorkspaceCreationError.missingTitle) {
      try await ProjectWorkspace.update(
        ProjectWorkspaceUpdateRequest(rootURL: rootURL, title: "  ", members: [.existing(appEntry)], updatedAt: Date()),
        gitRunner: failingGitRunner
      )
    }
    await #expect(throws: ProjectWorkspaceCreationError.notEnoughRepositories) {
      try await ProjectWorkspace.update(
        ProjectWorkspaceUpdateRequest(
          rootURL: rootURL, title: "Title", members: [],
          removals: [ProjectWorkspaceRepositoryRemoval(entry: appEntry, deleteFiles: true)],
          updatedAt: Date()),
        gitRunner: failingGitRunner
      )
    }
    // Validation failures never reach the cleanup step.
    #expect(FileManager.default.fileExists(atPath: rootURL.appending(path: "app").path(percentEncoded: false)))
  }

  // MARK: - Helpers

  private var failingGitRunner: ProjectWorkspaceGitRunner {
    ProjectWorkspaceGitRunner { command in
      throw ProjectWorkspaceCreationError.gitCommandFailed(command: command.displayCommand, message: "unexpected")
    }
  }

  private func createLinkedWorkspace(rootURL: URL, appURL: URL, apiURL: URL? = nil) async throws
    -> ProjectWorkspace
  {
    var plans = [
      ProjectWorkspaceRepositoryPlan(
        id: "app",
        name: "App",
        path: "app",
        sourceKind: .existingPath,
        sourceLocation: appURL.path(percentEncoded: false),
        checkout: .link
      )
    ]
    if let apiURL {
      plans.append(
        ProjectWorkspaceRepositoryPlan(
          id: "api",
          name: "API",
          path: "api",
          sourceKind: .existingPath,
          sourceLocation: apiURL.path(percentEncoded: false),
          checkout: .link
        ))
    }
    return try await ProjectWorkspace.create(
      ProjectWorkspaceCreationRequest(
        draft: ProjectWorkspaceCreationDraft(title: "Linked", rootURL: rootURL, repositories: plans),
        createdAt: Date(timeIntervalSince1970: 1_000)
      ),
      gitRunner: failingGitRunner
    )
  }

  /// Directory URLs render with a trailing slash; git commands receive the
  /// plain path.
  private func normalizedPath(_ url: URL) -> String {
    var path = url.standardizedFileURL.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") {
      path.removeLast()
    }
    return path
  }

  private func makeTemporaryRoot(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
      .standardizedFileURL
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func writeWorkspaceJSON(_ json: String, to rootURL: URL) throws {
    let metadataDirectoryURL = rootURL.appending(path: ProjectWorkspace.metadataDirectoryName)
    try FileManager.default.createDirectory(at: metadataDirectoryURL, withIntermediateDirectories: true)
    try Data(json.utf8).write(to: ProjectWorkspace.metadataURL(for: rootURL))
  }
}
