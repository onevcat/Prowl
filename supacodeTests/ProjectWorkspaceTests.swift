import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

@MainActor
struct ProjectWorkspaceTests {
  @Test func baseRefOptionsKeepsDetectedKindForAutomaticSlashBranch() {
    let options = ProjectWorkspaceCreationRepository.baseRefOptions(
      automaticBaseRef: "feature/login",
      options: [
        GitBranchRefOption(ref: "feature/login", kind: .local),
        GitBranchRefOption(ref: "origin/main", kind: .remoteTracking),
      ]
    )

    #expect(
      options == [
        GitBranchRefOption(ref: "feature/login", kind: .local),
        GitBranchRefOption(ref: "origin/main", kind: .remoteTracking),
      ])
  }

  @Test func preferredBaseRefMatchesTrimmedAutomaticBaseRef() {
    let preferred = ProjectWorkspaceCreationRepository.preferredBaseRef(
      automaticBaseRef: " develop \n",
      options: [
        GitBranchRefOption(ref: "develop", kind: .local),
        GitBranchRefOption(ref: "main", kind: .local),
      ]
    )

    #expect(preferred == "develop")
  }

  @Test func remoteNamingStripsOnlyTrailingGitSuffix() {
    #expect(
      GitRemoteNaming.repositoryName(fromRemoteURL: "git@github.com:onevcat/x.github.io.git")
        == "x.github.io")
    #expect(
      GitRemoteNaming.repositoryName(fromRemoteURL: "https://github.com/onevcat/app.git") == "app")
    #expect(
      GitRemoteNaming.repositoryName(fromRemoteURL: "https://github.com/onevcat/app") == "app")
  }

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
    #expect(workspace.schemaVersion == ProjectWorkspace.currentSchemaVersion)
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

  @Test func decodesWorkspaceBootstrapMetadata() throws {
    let rootURL = try makeTemporaryWorkspaceRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try writeWorkspaceJSON(
      """
      {
        "title": "Bootstrap Task",
        "repositories": [
          {
            "id": "app",
            "name": "App",
            "path": "app",
            "bootstrap": {
              "script_kind": "user_profile",
              "script_id": "sync-app",
              "run_on": ["create", "manual"],
              "required": true
            }
          }
        ]
      }
      """,
      to: rootURL
    )

    let workspace = try #require(ProjectWorkspace.load(from: rootURL))
    let bootstrap = try #require(workspace.repositories.first?.bootstrap)
    #expect(bootstrap.scriptKind == .userProfile)
    #expect(bootstrap.scriptID == "sync-app")
    #expect(bootstrap.scriptIDs == ["sync-app"])
    #expect(bootstrap.runOn == [.create, .manual])
    #expect(bootstrap.required == true)
  }

  @Test func decodesWorkspaceBootstrapScriptIDsMetadata() throws {
    let rootURL = try makeTemporaryWorkspaceRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try writeWorkspaceJSON(
      """
      {
        "title": "Bootstrap Task",
        "repositories": [
          {
            "id": "app",
            "name": "App",
            "path": "app",
            "bootstrap": {
              "script_kind": "user_profile",
              "script_ids": ["common", "sync-app", "common"],
              "run_on": ["create"],
              "required": false
            }
          }
        ]
      }
      """,
      to: rootURL
    )

    let workspace = try #require(ProjectWorkspace.load(from: rootURL))
    let bootstrap = try #require(workspace.repositories.first?.bootstrap)
    #expect(bootstrap.scriptIDs == ["common", "sync-app"])
    #expect(bootstrap.scriptID == "common")
    #expect(bootstrap.runOn == [.create])
  }

  @Test func decodesWorkspaceAgentGuideMetadata() throws {
    let rootURL = try makeTemporaryWorkspaceRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }

    try writeWorkspaceJSON(
      """
      {
        "title": "Agent Task",
        "agent_guide": {
          "enabled": true,
          "outputs": ["AGENTS.md", "../outside.md", "CLAUDE.md"],
          "include_child_instruction_files": false,
          "extra_notes": "Coordinate edits before touching shared files."
        },
        "repositories": [
          {
            "id": "app",
            "name": "App",
            "path": "app",
            "role": "macOS app",
            "agent_notes": "Use TCA reducer tests."
          }
        ]
      }
      """,
      to: rootURL
    )

    let workspace = try #require(ProjectWorkspace.load(from: rootURL))
    let guide = try #require(workspace.agentGuide)
    #expect(guide.enabled)
    #expect(guide.outputs == ["AGENTS.md", "CLAUDE.md"])
    #expect(guide.includeChildInstructionFiles == false)
    #expect(guide.extraNotes == "Coordinate edits before touching shared files.")
    #expect(workspace.repositories.first?.agentNotes == "Use TCA reducer tests.")
  }

  @Test func agentGuideWriterCreatesManagedBlockAndReferencesChildInstructions() throws {
    let rootURL = try makeTemporaryWorkspaceRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(
      at: rootURL.appending(path: "app"), withIntermediateDirectories: true)
    try Data("child".utf8).write(to: rootURL.appending(path: "app").appending(path: "AGENTS.md"))

    let workspace = ProjectWorkspace(
      title: "Agent Task",
      description: "Touch app and API together.",
      taskLinks: ["https://example.test/task"],
      agentGuide: ProjectWorkspaceAgentGuide(enabled: true),
      repositories: [
        ProjectWorkspace.RepositoryEntry(
          id: "app",
          name: "App",
          role: "macOS app",
          agentNotes: "Use reducer tests.",
          path: "app",
          sourceKind: .localRepository,
          branchName: "codex/task"
        )
      ]
    )

    try ProjectWorkspaceAgentGuideFileWriter().write(workspace: workspace, rootURL: rootURL)

    let guide = try String(contentsOf: rootURL.appending(path: "AGENTS.md"), encoding: .utf8)
    #expect(guide.contains(ProjectWorkspaceAgentGuideFileWriter.startMarker))
    #expect(guide.contains("- `app`: macOS app"))
    #expect(guide.contains("- Agent notes: Use reducer tests."))
    #expect(guide.contains("- `app/AGENTS.md`"))
  }

  @Test func agentGuideWriterReplacesManagedBlockOnly() throws {
    let rootURL = try makeTemporaryWorkspaceRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let outputURL = rootURL.appending(path: "AGENTS.md")
    try Data(
      """
      # Custom

      keep before
      \(ProjectWorkspaceAgentGuideFileWriter.startMarker)
      old
      \(ProjectWorkspaceAgentGuideFileWriter.endMarker)
      keep after
      """.utf8
    )
    .write(to: outputURL)

    let workspace = ProjectWorkspace(
      title: "New Title",
      agentGuide: ProjectWorkspaceAgentGuide(enabled: true),
      repositories: [
        ProjectWorkspace.RepositoryEntry(id: "app", name: "App", path: "app")
      ]
    )

    try ProjectWorkspaceAgentGuideFileWriter().write(workspace: workspace, rootURL: rootURL)

    let guide = try String(contentsOf: outputURL, encoding: .utf8)
    #expect(guide.contains("keep before"))
    #expect(guide.contains("keep after"))
    #expect(guide.contains("- Title: New Title"))
    #expect(!guide.contains("\nold\n"))
  }

  @Test func metadataPatcherPreservesUnknownFields() throws {
    let rootURL = try makeTemporaryWorkspaceRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try writeWorkspaceJSON(
      """
      {
        "schema_version": "prowl.workspace.v1",
        "title": "Old",
        "custom_top": "keep",
        "repositories": [
          {
            "id": "app",
            "name": "App",
            "path": "app",
            "source_kind": "existing_path",
            "custom_repo": "keep"
          },
          {
            "id": "api",
            "name": "API",
            "path": "api",
            "source_kind": "remote"
          }
        ]
      }
      """,
      to: rootURL
    )

    var workspace = try #require(ProjectWorkspace.load(from: rootURL))
    workspace.title = "New"
    workspace.agentGuide = ProjectWorkspaceAgentGuide(enabled: true)
    workspace.repositories[0].role = "macOS app"
    workspace.repositories[0].agentNotes = "Test reducers."
    let saved = try ProjectWorkspaceMetadataPatcher(now: { Date(timeIntervalSince1970: 10) })
      .save(workspace, rootURL: rootURL)

    #expect(saved.title == "New")
    let data = try Data(contentsOf: ProjectWorkspace.metadataURL(for: rootURL))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["custom_top"] as? String == "keep")
    let repositories = try #require(object["repositories"] as? [[String: Any]])
    #expect(repositories[0]["custom_repo"] as? String == "keep")
    #expect(repositories[0]["role"] as? String == "macOS app")
    #expect(repositories[0]["agent_notes"] as? String == "Test reducers.")
  }

  @Test func metadataPatcherPreservesUnknownRepositoryFieldsWhenAddingAndRemoving() throws {
    let rootURL = try makeTemporaryWorkspaceRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try writeWorkspaceJSON(
      """
      {
        "schema_version": "prowl.workspace.v1",
        "title": "Old",
        "repositories": [
          {
            "id": "app",
            "name": "App",
            "path": "app",
            "source_kind": "existing_path",
            "custom_repo": "keep"
          },
          {
            "id": "api",
            "name": "API",
            "path": "api",
            "source_kind": "existing_path",
            "remove_me": true
          }
        ]
      }
      """,
      to: rootURL
    )

    var workspace = try #require(ProjectWorkspace.load(from: rootURL))
    workspace.repositories = [
      workspace.repositories[0],
      ProjectWorkspace.RepositoryEntry(
        id: "web",
        name: "Web",
        path: "web",
        sourceKind: .remote,
        sourceLocation: "git@github.com:onevcat/web.git",
        baseRef: "origin/main"
      ),
    ]

    _ = try ProjectWorkspaceMetadataPatcher(now: { Date(timeIntervalSince1970: 10) })
      .save(workspace, rootURL: rootURL)

    let data = try Data(contentsOf: ProjectWorkspace.metadataURL(for: rootURL))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let repositories = try #require(object["repositories"] as? [[String: Any]])
    #expect(repositories.map { $0["id"] as? String } == ["app", "web"])
    #expect(repositories[0]["custom_repo"] as? String == "keep")
    #expect(repositories[1]["source_location"] as? String == "git@github.com:onevcat/web.git")
    #expect(repositories[1]["base_ref"] as? String == "origin/main")
  }

  @Test func loadReturnsNilForMalformedWorkspaceMetadata() throws {
    let rootURL = try makeTemporaryWorkspaceRoot()
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try writeWorkspaceJSON("{ not json", to: rootURL)

    #expect(ProjectWorkspace.load(from: rootURL) == nil)
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

  @Test func createWorkspaceWritesMetadataAndRepositoryLinks() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "prowl-created-workspace-\(UUID().uuidString)")
      .standardizedFileURL
    let appURL = try makeTemporaryWorkspaceRoot()
    let apiURL = try makeTemporaryWorkspaceRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: appURL)
      try? FileManager.default.removeItem(at: apiURL)
    }
    let createdAt = Date(timeIntervalSince1970: 1_234_567)
    let workspace = try await ProjectWorkspace.create(
      ProjectWorkspaceCreationRequest(
        draft: ProjectWorkspaceCreationDraft(
          title: "Checkout Flow",
          rootURL: rootURL,
          repositories: [
            ProjectWorkspaceRepositoryPlan(
              id: "app",
              name: "App Repo",
              path: nil,
              sourceKind: .existingPath,
              sourceLocation: appURL.path(percentEncoded: false),
              checkout: .link
            ),
            ProjectWorkspaceRepositoryPlan(
              id: "api",
              name: "App Repo",
              path: nil,
              sourceKind: .existingPath,
              sourceLocation: apiURL.path(percentEncoded: false),
              checkout: .link
            ),
          ]
        ),
        createdAt: createdAt
      ),
      gitRunner: ProjectWorkspaceGitRunner { command in
        throw ProjectWorkspaceCreationError.gitCommandFailed(
          command: command.displayCommand, message: "unexpected")
      }
    )

    #expect(workspace.title == "Checkout Flow")
    #expect(workspace.schemaVersion == ProjectWorkspace.currentSchemaVersion)
    #expect(workspace.createdAt == createdAt)
    let loaded = try #require(ProjectWorkspace.load(from: rootURL))
    #expect(loaded.schemaVersion == ProjectWorkspace.currentSchemaVersion)
    #expect(loaded.repositories.map(\.path) == ["App-Repo", "App-Repo-2"])
    #expect(loaded.repositories.map(\.sourceKind) == [.existingPath, .existingPath])
    let appPath = normalizedTestPath(appURL)
    let apiPath = normalizedTestPath(apiURL)
    #expect(
      loaded.repositories.map(\.sourceLocation) == [
        appPath,
        apiPath,
      ])
    #expect(loaded.repositories.map(\.branchName) == [nil, nil])

    let appLinkPath = rootURL.appending(path: "App-Repo").path(percentEncoded: false)
    let apiLinkPath = rootURL.appending(path: "App-Repo-2").path(percentEncoded: false)
    #expect(
      URL(fileURLWithPath: appLinkPath).resolvingSymlinksInPath().path(percentEncoded: false)
        == appPath)
    #expect(
      URL(fileURLWithPath: apiLinkPath).resolvingSymlinksInPath().path(percentEncoded: false)
        == apiPath)
  }

  @Test func createWorkspaceMaterializesRemoteCloneAndBareWorktree() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "prowl-materialized-workspace-\(UUID().uuidString)")
      .standardizedFileURL
    let bareURL = try makeTemporaryWorkspaceRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: bareURL)
    }
    let commands = LockIsolated<[ProjectWorkspaceGitCommand]>([])
    let workspace = try await ProjectWorkspace.create(
      ProjectWorkspaceCreationRequest(
        draft: ProjectWorkspaceCreationDraft(
          title: "Materialized",
          rootURL: rootURL,
          repositories: [
            ProjectWorkspaceRepositoryPlan(
              id: "app",
              name: "App",
              path: "app",
              sourceKind: .remote,
              sourceLocation: "git@github.com:onevcat/app.git",
              checkout: .createBranch(branchName: "codex/app", baseRef: "origin/main")
            ),
            ProjectWorkspaceRepositoryPlan(
              id: "api",
              name: "API",
              path: "api",
              sourceKind: .bareRepository,
              sourceLocation: bareURL.path(percentEncoded: false),
              checkout: .createBranch(branchName: "codex/api", baseRef: "main")
            ),
          ]
        ),
        createdAt: Date(timeIntervalSince1970: 2_345_678)
      ),
      gitRunner: ProjectWorkspaceGitRunner { command in
        commands.withValue { $0.append(command) }
      }
    )

    #expect(workspace.repositories.map(\.path) == ["app", "api"])
    #expect(workspace.repositories.map(\.sourceKind) == [.remote, .bareRepository])
    let rootPath = rootURL.path(percentEncoded: false)
    let barePath = normalizedTestPath(bareURL)
    #expect(
      commands.value.map(\.arguments) == [
        ["clone", "--end-of-options", "git@github.com:onevcat/app.git", "\(rootPath)/app"],
        [
          "-C", "\(rootPath)/app", "checkout", "-B", "codex/app", "--end-of-options", "origin/main",
        ],
        [
          "-C", barePath, "worktree", "add", "-b", "codex/api", "\(rootPath)/api",
          "--end-of-options", "main",
        ],
      ])

    let loaded = try #require(ProjectWorkspace.load(from: rootURL))
    #expect(
      loaded.repositories.map(\.sourceLocation) == ["git@github.com:onevcat/app.git", barePath])
    #expect(loaded.repositories.map(\.branchName) == ["codex/app", "codex/api"])
    #expect(loaded.repositories.map(\.baseRef) == ["origin/main", "main"])
  }

  @Test func createWorkspaceUsesExistingRefsWithoutCreatingBranches() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "prowl-existing-ref-workspace-\(UUID().uuidString)")
      .standardizedFileURL
    let bareURL = try makeTemporaryWorkspaceRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: bareURL)
    }
    let commands = LockIsolated<[ProjectWorkspaceGitCommand]>([])
    _ = try await ProjectWorkspace.create(
      ProjectWorkspaceCreationRequest(
        draft: ProjectWorkspaceCreationDraft(
          title: "Existing Refs",
          rootURL: rootURL,
          repositories: [
            ProjectWorkspaceRepositoryPlan(
              id: "app",
              name: "App",
              path: "app",
              sourceKind: .remote,
              sourceLocation: "git@github.com:onevcat/app.git",
              checkout: .useExistingRef("origin/feature/login")
            ),
            ProjectWorkspaceRepositoryPlan(
              id: "api",
              name: "API",
              path: "api",
              sourceKind: .bareRepository,
              sourceLocation: bareURL.path(percentEncoded: false),
              checkout: .useExistingRef("main")
            ),
          ]
        ),
        createdAt: Date(timeIntervalSince1970: 3_456_789)
      ),
      gitRunner: ProjectWorkspaceGitRunner { command in
        commands.withValue { $0.append(command) }
      }
    )

    let rootPath = rootURL.path(percentEncoded: false)
    let barePath = normalizedTestPath(bareURL)
    #expect(
      commands.value.map(\.arguments) == [
        ["clone", "--end-of-options", "git@github.com:onevcat/app.git", "\(rootPath)/app"],
        ["-C", "\(rootPath)/app", "checkout", "--end-of-options", "feature/login"],
        ["-C", barePath, "worktree", "add", "\(rootPath)/api", "--end-of-options", "main"],
      ])

    let loaded = try #require(ProjectWorkspace.load(from: rootURL))
    #expect(loaded.repositories.map(\.branchName) == [nil, nil])
    #expect(loaded.repositories.map(\.baseRef) == ["origin/feature/login", "main"])
  }

  @Test func createWorkspaceTracksRemoteRefsAsLocalBranches() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "prowl-tracked-ref-workspace-\(UUID().uuidString)")
      .standardizedFileURL
    let bareURL = try makeTemporaryWorkspaceRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: bareURL)
    }
    let commands = LockIsolated<[ProjectWorkspaceGitCommand]>([])
    let workspace = try await ProjectWorkspace.create(
      ProjectWorkspaceCreationRequest(
        draft: ProjectWorkspaceCreationDraft(
          title: "Tracked Refs",
          rootURL: rootURL,
          repositories: [
            ProjectWorkspaceRepositoryPlan(
              id: "app",
              name: "App",
              path: "app",
              sourceKind: .remote,
              sourceLocation: "git@github.com:onevcat/app.git",
              checkout: .trackRemoteRef(
                remoteRef: "origin/chore/disable-spine", branchName: "chore/disable-spine")
            ),
            ProjectWorkspaceRepositoryPlan(
              id: "maker",
              name: "maker.git",
              path: nil,
              sourceKind: .bareRepository,
              sourceLocation: bareURL.path(percentEncoded: false),
              checkout: .trackRemoteRef(
                remoteRef: "origin/chore/disable-spine", branchName: "chore/disable-spine")
            ),
          ]
        ),
        createdAt: Date(timeIntervalSince1970: 8_901_234)
      ),
      gitRunner: ProjectWorkspaceGitRunner { command in
        commands.withValue { $0.append(command) }
      }
    )

    let rootPath = rootURL.path(percentEncoded: false)
    let barePath = normalizedTestPath(bareURL)
    #expect(
      commands.value.map(\.arguments) == [
        ["clone", "--end-of-options", "git@github.com:onevcat/app.git", "\(rootPath)/app"],
        ["-C", "\(rootPath)/app", "checkout", "--end-of-options", "chore/disable-spine"],
        [
          "-C", barePath, "worktree", "add", "--track", "-B", "chore/disable-spine",
          "\(rootPath)/maker", "--end-of-options", "origin/chore/disable-spine",
        ],
      ])
    #expect(workspace.repositories.map(\.path) == ["app", "maker"])
    #expect(
      workspace.repositories.map(\.branchName) == ["chore/disable-spine", "chore/disable-spine"])
    #expect(
      workspace.repositories.map(\.baseRef)
        == ["origin/chore/disable-spine", "origin/chore/disable-spine"]
    )
  }

  @Test func planMapsRemoteTrackingRefToTrackingBranch() {
    let repository = ProjectWorkspaceCreationRepository(
      id: "maker",
      name: "maker.git",
      sourceKind: .bareRepository,
      sourceLocation: "/tmp/maker.git",
      checkoutMode: .useExistingRef,
      baseRef: "origin/chore/x",
      baseRefOptions: [GitBranchRefOption(ref: "origin/chore/x", kind: .remoteTracking)]
    )

    #expect(
      WorkspaceCreationPromptFeature.plan(for: repository).map(\.checkout)
        == .success(.trackRemoteRef(remoteRef: "origin/chore/x", branchName: "chore/x"))
    )
  }

  @Test func planKeepsExistingLocalBranchWhenNotResetting() {
    let repository = ProjectWorkspaceCreationRepository(
      id: "maker",
      name: "maker.git",
      sourceKind: .bareRepository,
      sourceLocation: "/tmp/maker.git",
      checkoutMode: .useExistingRef,
      baseRef: "origin/chore/x",
      baseRefOptions: [
        GitBranchRefOption(ref: "origin/chore/x", kind: .remoteTracking),
        GitBranchRefOption(ref: "chore/x", kind: .local),
      ]
    )

    // A same-named local branch exists and the user keeps it (default): check
    // out the local branch directly instead of resetting it to the remote.
    #expect(repository.resettableLocalBranchName == "chore/x")
    #expect(
      WorkspaceCreationPromptFeature.plan(for: repository).map(\.checkout)
        == .success(.useExistingRef("chore/x"))
    )
  }

  @Test func localBranchNameForRemoteRefKeepsSlashedBranchName() {
    #expect(
      ProjectWorkspaceCreationRepository.localBranchName(forRemoteRef: "origin/chore/x")
        == "chore/x")
    #expect(
      ProjectWorkspaceCreationRepository.localBranchName(forRemoteRef: "upstream/main") == "main")
    #expect(ProjectWorkspaceCreationRepository.localBranchName(forRemoteRef: "main") == nil)
  }

  @Test func planResetsLocalBranchToRemoteWhenChosen() {
    var repository = ProjectWorkspaceCreationRepository(
      id: "maker",
      name: "maker.git",
      sourceKind: .bareRepository,
      sourceLocation: "/tmp/maker.git",
      checkoutMode: .useExistingRef,
      baseRef: "origin/chore/x",
      baseRefOptions: [
        GitBranchRefOption(ref: "origin/chore/x", kind: .remoteTracking),
        GitBranchRefOption(ref: "chore/x", kind: .local),
      ]
    )
    repository.resetLocalBranchToRemote = true

    #expect(
      WorkspaceCreationPromptFeature.plan(for: repository).map(\.checkout)
        == .success(.trackRemoteRef(remoteRef: "origin/chore/x", branchName: "chore/x"))
    )
  }

  @Test func defaultRepositoryNameStripsGitSuffix() {
    #expect(
      WorkspaceCreationPromptFeature.defaultRepositoryName(
        for: URL(fileURLWithPath: "/tmp/maker.git"))
        == "maker"
    )
    #expect(
      WorkspaceCreationPromptFeature.defaultRepositoryName(for: URL(fileURLWithPath: "/tmp/maker"))
        == "maker"
    )
  }

  @Test func createWorkspaceMaterializesLocalRepositoriesAsWorktrees() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "prowl-local-worktree-workspace-\(UUID().uuidString)")
      .standardizedFileURL
    let appURL = try makeTemporaryWorkspaceRoot()
    let apiURL = try makeTemporaryWorkspaceRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: appURL)
      try? FileManager.default.removeItem(at: apiURL)
    }
    let commands = LockIsolated<[ProjectWorkspaceGitCommand]>([])
    let workspace = try await ProjectWorkspace.create(
      ProjectWorkspaceCreationRequest(
        draft: ProjectWorkspaceCreationDraft(
          title: "Local Worktrees",
          rootURL: rootURL,
          repositories: [
            ProjectWorkspaceRepositoryPlan(
              id: "app",
              name: "App",
              path: "app",
              sourceKind: .localRepository,
              sourceLocation: appURL.path(percentEncoded: false),
              checkout: .createBranch(branchName: "codex/app", baseRef: "main")
            ),
            ProjectWorkspaceRepositoryPlan(
              id: "api",
              name: "API",
              path: "api",
              sourceKind: .existingPath,
              sourceLocation: apiURL.path(percentEncoded: false),
              checkout: .useExistingRef("origin/main")
            ),
          ]
        ),
        createdAt: Date(timeIntervalSince1970: 4_567_890)
      ),
      gitRunner: ProjectWorkspaceGitRunner { command in
        commands.withValue { $0.append(command) }
      }
    )

    let rootPath = rootURL.path(percentEncoded: false)
    let appPath = normalizedTestPath(appURL)
    let apiPath = normalizedTestPath(apiURL)
    #expect(
      commands.value.map(\.arguments) == [
        [
          "-C", appPath, "worktree", "add", "-b", "codex/app", "\(rootPath)/app",
          "--end-of-options", "main",
        ],
        ["-C", apiPath, "worktree", "add", "\(rootPath)/api", "--end-of-options", "origin/main"],
      ])
    #expect(workspace.repositories.map(\.branchName) == ["codex/app", nil])
    #expect(workspace.repositories.map(\.baseRef) == ["main", "origin/main"])
  }

  @Test func createWorkspaceRunsBootstrapAfterMaterialization() async throws {
    let rootURL = try makeTemporaryWorkspaceRoot()
    let appURL = try makeTemporaryWorkspaceRoot()
    let apiURL = try makeTemporaryWorkspaceRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: appURL)
      try? FileManager.default.removeItem(at: apiURL)
    }
    let bootstrapCalls = LockIsolated<[ProjectWorkspaceBootstrapContext]>([])
    _ = try await ProjectWorkspace.create(
      ProjectWorkspaceCreationRequest(
        draft: ProjectWorkspaceCreationDraft(
          title: "Bootstrap",
          rootURL: rootURL,
          repositories: [
            ProjectWorkspaceRepositoryPlan(
              id: "app",
              name: "App",
              path: "app",
              sourceKind: .localRepository,
              sourceLocation: appURL.path(percentEncoded: false),
              checkout: .createBranch(branchName: "codex/app", baseRef: "main"),
              bootstrap: ProjectWorkspaceRepositoryBootstrap(
                scriptKind: .userProfile,
                scriptID: "sync-app",
                runOn: [.create],
                required: true
              )
            ),
            ProjectWorkspaceRepositoryPlan(
              id: "api",
              name: "API",
              path: "api",
              sourceKind: .existingPath,
              sourceLocation: apiURL.path(percentEncoded: false),
              checkout: .link,
              bootstrap: ProjectWorkspaceRepositoryBootstrap(
                scriptKind: .userProfile,
                scriptID: "sync-api",
                runOn: [.create],
                required: true
              )
            ),
          ]
        ),
        createdAt: Date(timeIntervalSince1970: 9_012_345)
      ),
      gitRunner: ProjectWorkspaceGitRunner { command in
        if command.arguments.contains("worktree") {
          try FileManager.default.createDirectory(
            at: rootURL.appending(path: "app"),
            withIntermediateDirectories: true
          )
        }
      },
      bootstrapRunner: ProjectWorkspaceBootstrapRunner { _, context in
        bootstrapCalls.withValue { $0.append(context) }
      }
    )

    #expect(bootstrapCalls.value.map(\.repository.id) == ["app"])
    let loaded = try #require(ProjectWorkspace.load(from: rootURL))
    #expect(loaded.repositories.map(\.bootstrap?.scriptIDs) == [["sync-app"], ["sync-api"]])
  }

  @Test func updateRepositoriesAddsRemovesAndRunsOnAddBootstrap() async throws {
    let rootURL = try makeTemporaryWorkspaceRoot()
    let appURL = try makeTemporaryWorkspaceRoot()
    let apiURL = try makeTemporaryWorkspaceRoot()
    let webURL = try makeTemporaryWorkspaceRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: appURL)
      try? FileManager.default.removeItem(at: apiURL)
      try? FileManager.default.removeItem(at: webURL)
    }
    try FileManager.default.createDirectory(
      at: rootURL.appending(path: "api"), withIntermediateDirectories: true)

    let workspace = ProjectWorkspace(
      title: "Workspace",
      repositories: [
        ProjectWorkspace.RepositoryEntry(
          id: "app",
          name: "App",
          path: "app",
          sourceKind: .existingPath,
          sourceLocation: appURL.path(percentEncoded: false)
        ),
        ProjectWorkspace.RepositoryEntry(
          id: "api",
          name: "API",
          path: "api",
          sourceKind: .localRepository,
          sourceLocation: apiURL.path(percentEncoded: false)
        ),
      ]
    )

    let commands = LockIsolated<[ProjectWorkspaceGitCommand]>([])
    let bootstrapCalls = LockIsolated<[ProjectWorkspaceBootstrapContext]>([])
    let saved = try await ProjectWorkspace.updateRepositories(
      ProjectWorkspaceRepositoryUpdateRequest(
        workspace: workspace,
        rootURL: rootURL,
        additions: [
          ProjectWorkspaceRepositoryPlan(
            id: "web",
            name: "Web",
            path: "web",
            sourceKind: .localRepository,
            sourceLocation: webURL.path(percentEncoded: false),
            checkout: .createBranch(branchName: "codex/web", baseRef: "main"),
            bootstrap: ProjectWorkspaceRepositoryBootstrap(
              scriptKind: .userProfile,
              scriptID: "sync-web",
              runOn: [.onAdd],
              required: true
            )
          )
        ],
        removedRepositories: [workspace.repositories[1]],
        updatedAt: Date(timeIntervalSince1970: 42)
      ),
      gitRunner: ProjectWorkspaceGitRunner { command in
        commands.withValue { $0.append(command) }
        if command.arguments.contains(rootURL.appending(path: "web").path(percentEncoded: false)) {
          try FileManager.default.createDirectory(
            at: rootURL.appending(path: "web"),
            withIntermediateDirectories: true
          )
        }
      },
      bootstrapRunner: ProjectWorkspaceBootstrapRunner { _, context in
        bootstrapCalls.withValue { $0.append(context) }
      }
    ) { $0 }

    #expect(saved.repositories.map(\.id) == ["app", "web"])
    #expect(saved.updatedAt == Date(timeIntervalSince1970: 42))
    #expect(bootstrapCalls.value.map(\.repository.id) == ["web"])
    #expect(bootstrapCalls.value.map(\.timing) == [.onAdd])
    let rootPath = rootURL.path(percentEncoded: false)
    let apiPath = normalizedTestPath(apiURL)
    let webPath = normalizedTestPath(webURL)
    #expect(
      commands.value.map(\.arguments) == [
        ["-C", apiPath, "worktree", "remove", "--force", "\(rootPath)/api"],
        [
          "-C", webPath, "worktree", "add", "-b", "codex/web", "\(rootPath)/web",
          "--end-of-options", "main",
        ],
      ])
  }

  @Test func optionalBootstrapFailureKeepsWorkspace() async throws {
    let rootURL = try makeTemporaryWorkspaceRoot()
    let appURL = try makeTemporaryWorkspaceRoot()
    let apiURL = try makeTemporaryWorkspaceRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: appURL)
      try? FileManager.default.removeItem(at: apiURL)
    }

    let workspace = try await ProjectWorkspace.create(
      ProjectWorkspaceCreationRequest(
        draft: ProjectWorkspaceCreationDraft(
          title: "Optional Bootstrap",
          rootURL: rootURL,
          repositories: [
            ProjectWorkspaceRepositoryPlan(
              id: "app",
              name: "App",
              path: "app",
              sourceKind: .localRepository,
              sourceLocation: appURL.path(percentEncoded: false),
              checkout: .createBranch(branchName: "codex/app", baseRef: "main"),
              bootstrap: ProjectWorkspaceRepositoryBootstrap(
                scriptKind: .userProfile,
                scriptID: "sync-app",
                runOn: [.create],
                required: false
              )
            ),
            ProjectWorkspaceRepositoryPlan(
              id: "api",
              name: "API",
              path: "api",
              sourceKind: .localRepository,
              sourceLocation: apiURL.path(percentEncoded: false),
              checkout: .createBranch(branchName: "codex/api", baseRef: "main")
            ),
          ]
        ),
        createdAt: Date(timeIntervalSince1970: 9_123_456)
      ),
      gitRunner: ProjectWorkspaceGitRunner { command in
        let arguments = command.arguments.joined(separator: " ")
        if arguments.contains(rootURL.appending(path: "app").path(percentEncoded: false)) {
          try FileManager.default.createDirectory(
            at: rootURL.appending(path: "app"),
            withIntermediateDirectories: true
          )
        }
        if arguments.contains(rootURL.appending(path: "api").path(percentEncoded: false)) {
          try FileManager.default.createDirectory(
            at: rootURL.appending(path: "api"),
            withIntermediateDirectories: true
          )
        }
      },
      bootstrapRunner: ProjectWorkspaceBootstrapRunner { _, _ in
        throw ProjectWorkspaceCreationError.bootstrapFailed(repository: "App", message: "boom")
      }
    )

    #expect(workspace.title == "Optional Bootstrap")
    #expect(ProjectWorkspace.load(from: rootURL) != nil)
  }

  @Test func requiredBootstrapFailureRollsBackMaterialization() async throws {
    let rootURL = try makeTemporaryWorkspaceRoot()
    let appURL = try makeTemporaryWorkspaceRoot()
    let apiURL = try makeTemporaryWorkspaceRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: appURL)
      try? FileManager.default.removeItem(at: apiURL)
    }

    await #expect(
      throws: ProjectWorkspaceCreationError.bootstrapFailed(repository: "App", message: "boom")
    ) {
      try await ProjectWorkspace.create(
        ProjectWorkspaceCreationRequest(
          draft: ProjectWorkspaceCreationDraft(
            title: "Required Bootstrap",
            rootURL: rootURL,
            repositories: [
              ProjectWorkspaceRepositoryPlan(
                id: "app",
                name: "App",
                path: "app",
                sourceKind: .localRepository,
                sourceLocation: appURL.path(percentEncoded: false),
                checkout: .createBranch(branchName: "codex/app", baseRef: "main"),
                bootstrap: ProjectWorkspaceRepositoryBootstrap(
                  scriptKind: .userProfile,
                  scriptID: "sync-app",
                  runOn: [.create],
                  required: true
                )
              ),
              ProjectWorkspaceRepositoryPlan(
                id: "api",
                name: "API",
                path: "api",
                sourceKind: .localRepository,
                sourceLocation: apiURL.path(percentEncoded: false),
                checkout: .createBranch(branchName: "codex/api", baseRef: "main")
              ),
            ]
          ),
          createdAt: Date(timeIntervalSince1970: 9_234_567)
        ),
        gitRunner: ProjectWorkspaceGitRunner { command in
          let arguments = command.arguments.joined(separator: " ")
          if arguments.contains(rootURL.appending(path: "app").path(percentEncoded: false)) {
            try FileManager.default.createDirectory(
              at: rootURL.appending(path: "app"),
              withIntermediateDirectories: true
            )
          }
        },
        bootstrapRunner: ProjectWorkspaceBootstrapRunner { _, _ in
          throw ProjectWorkspaceCreationError.bootstrapFailed(repository: "App", message: "boom")
        }
      )
    }

    #expect(
      !FileManager.default.fileExists(
        atPath: rootURL.appending(path: "app").path(percentEncoded: false)))
    #expect(
      !FileManager.default.fileExists(
        atPath: ProjectWorkspace.metadataURL(for: rootURL).path(percentEncoded: false)
      )
    )
  }

  @Test func createWorkspaceRollsBackCloneWhenCheckoutFails() async throws {
    let rootURL = try makeTemporaryWorkspaceRoot()
    let bareURL = try makeTemporaryWorkspaceRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: bareURL)
    }
    let commands = LockIsolated<[ProjectWorkspaceGitCommand]>([])
    let cloneDestination = rootURL.appending(path: "app", directoryHint: .isDirectory)
    await #expect(throws: ProjectWorkspaceCreationError.self) {
      try await ProjectWorkspace.create(
        ProjectWorkspaceCreationRequest(
          draft: ProjectWorkspaceCreationDraft(
            title: "Half Done",
            rootURL: rootURL,
            repositories: [
              ProjectWorkspaceRepositoryPlan(
                id: "api",
                name: "API",
                path: "api",
                sourceKind: .bareRepository,
                sourceLocation: bareURL.path(percentEncoded: false),
                checkout: .createBranch(branchName: "codex/api", baseRef: "main")
              ),
              ProjectWorkspaceRepositoryPlan(
                id: "app",
                name: "App",
                path: "app",
                sourceKind: .remote,
                sourceLocation: "git@github.com:onevcat/app.git",
                checkout: .createBranch(branchName: "codex/app", baseRef: "origin/main")
              ),
            ]
          ),
          createdAt: Date(timeIntervalSince1970: 5_678_901)
        ),
        gitRunner: ProjectWorkspaceGitRunner { command in
          commands.withValue { $0.append(command) }
          if command.arguments.first == "clone" {
            try FileManager.default.createDirectory(
              at: cloneDestination, withIntermediateDirectories: true)
          }
          if command.arguments.contains("checkout") {
            throw ProjectWorkspaceCreationError.gitCommandFailed(
              command: command.displayCommand,
              message: "boom"
            )
          }
        }
      )
    }

    let rootPath = rootURL.path(percentEncoded: false)
    let barePath = normalizedTestPath(bareURL)
    #expect(
      commands.value.map(\.arguments).contains(
        ["-C", barePath, "worktree", "remove", "--force", "\(rootPath)/api"]
      )
    )
    #expect(!FileManager.default.fileExists(atPath: cloneDestination.path(percentEncoded: false)))
    #expect(
      !FileManager.default.fileExists(
        atPath: ProjectWorkspace.metadataURL(for: rootURL).path(percentEncoded: false)
      )
    )
    #expect(FileManager.default.fileExists(atPath: rootPath))
  }

  @Test func createWorkspaceRejectsCreateBranchWithoutName() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "prowl-invalid-workspace-\(UUID().uuidString)")
    let appURL = try makeTemporaryWorkspaceRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: appURL)
    }
    await #expect(throws: ProjectWorkspaceCreationError.missingBranchName("App")) {
      try await ProjectWorkspace.create(
        ProjectWorkspaceCreationRequest(
          draft: ProjectWorkspaceCreationDraft(
            title: "Invalid",
            rootURL: rootURL,
            repositories: [
              ProjectWorkspaceRepositoryPlan(
                id: "app",
                name: "App",
                path: "app",
                sourceKind: .localRepository,
                sourceLocation: appURL.path(percentEncoded: false),
                checkout: .createBranch(branchName: " ", baseRef: nil)
              ),
              ProjectWorkspaceRepositoryPlan(
                id: "api",
                name: "API",
                path: "api",
                sourceKind: .existingPath,
                sourceLocation: appURL.path(percentEncoded: false),
                checkout: .link
              ),
            ]
          ),
          createdAt: Date(timeIntervalSince1970: 6_789_012)
        ),
        gitRunner: ProjectWorkspaceGitRunner { _ in }
      )
    }
    #expect(!FileManager.default.fileExists(atPath: rootURL.path(percentEncoded: false)))
  }

  @Test func createWorkspaceRejectsLinkForBareRepository() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "prowl-invalid-link-workspace-\(UUID().uuidString)")
    let bareURL = try makeTemporaryWorkspaceRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: bareURL)
    }
    await #expect(throws: ProjectWorkspaceCreationError.linkCheckoutUnsupported("API")) {
      try await ProjectWorkspace.create(
        ProjectWorkspaceCreationRequest(
          draft: ProjectWorkspaceCreationDraft(
            title: "Invalid Link",
            rootURL: rootURL,
            repositories: [
              ProjectWorkspaceRepositoryPlan(
                id: "api",
                name: "API",
                path: "api",
                sourceKind: .bareRepository,
                sourceLocation: bareURL.path(percentEncoded: false),
                checkout: .link
              ),
              ProjectWorkspaceRepositoryPlan(
                id: "app",
                name: "App",
                path: "app",
                sourceKind: .existingPath,
                sourceLocation: bareURL.path(percentEncoded: false),
                checkout: .link
              ),
            ]
          ),
          createdAt: Date(timeIntervalSince1970: 7_890_123)
        ),
        gitRunner: ProjectWorkspaceGitRunner { _ in }
      )
    }
  }

  @Test func planRequiresBranchNameForCreateBranchOnLocalSources() {
    let repository = ProjectWorkspaceCreationRepository(
      id: "app",
      name: "App",
      rootURL: URL(fileURLWithPath: "/tmp/app"),
      checkoutMode: .createBranch
    )

    #expect(
      WorkspaceCreationPromptFeature.plan(for: repository)
        == .failure(.missingBranchName("App"))
    )
  }

  @Test func planMapsLinkAndExistingRefModes() throws {
    let linked = ProjectWorkspaceCreationRepository(
      id: "app",
      name: "App",
      rootURL: URL(fileURLWithPath: "/tmp/app")
    )
    #expect(WorkspaceCreationPromptFeature.plan(for: linked).map(\.checkout) == .success(.link))

    var existing = ProjectWorkspaceCreationRepository(
      id: "api",
      name: "API",
      sourceKind: .bareRepository,
      sourceLocation: "/tmp/api.git",
      checkoutMode: .useExistingRef
    )
    #expect(
      WorkspaceCreationPromptFeature.plan(for: existing)
        == .failure(.missingExistingRef("API"))
    )
    existing.baseRef = "main"
    #expect(
      WorkspaceCreationPromptFeature.plan(for: existing).map(\.checkout)
        == .success(.useExistingRef("main"))
    )
  }

  @Test func planMapsCreationBootstrapProfile() throws {
    let repository = ProjectWorkspaceCreationRepository(
      id: "app",
      name: "App",
      rootURL: URL(fileURLWithPath: "/tmp/app"),
      checkoutMode: .createBranch,
      branchName: "workspace/app",
      bootstrapScriptIDs: ["sync-app"],
      bootstrapRequired: true,
      bootstrapRunOnCreate: true
    )

    let plan = try WorkspaceCreationPromptFeature.plan(for: repository).get()
    #expect(
      plan.bootstrap
        == ProjectWorkspaceRepositoryBootstrap(
          scriptKind: .userProfile,
          scriptID: "sync-app",
          runOn: [.create],
          required: true
        ))
  }

  @Test func cleanupUnregistersWorktreesAndRemovesFolder() async throws {
    let rootURL = try makeTemporaryWorkspaceRoot()
    let linkedSourceURL = try makeTemporaryWorkspaceRoot()
    let bareURL = try makeTemporaryWorkspaceRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: linkedSourceURL)
      try? FileManager.default.removeItem(at: bareURL)
    }
    try FileManager.default.createSymbolicLink(
      at: rootURL.appending(path: "app"),
      withDestinationURL: linkedSourceURL
    )
    try FileManager.default.createDirectory(
      at: rootURL.appending(path: "api"),
      withIntermediateDirectories: true
    )

    let workspace = ProjectWorkspace(
      repositories: [
        ProjectWorkspace.RepositoryEntry(
          id: "app",
          name: "App",
          path: "app",
          sourceKind: .existingPath,
          sourceLocation: linkedSourceURL.path(percentEncoded: false)
        ),
        ProjectWorkspace.RepositoryEntry(
          id: "api",
          name: "API",
          path: "api",
          sourceKind: .bareRepository,
          sourceLocation: bareURL.path(percentEncoded: false),
          branchName: "chore/x"
        ),
      ]
    )
    let commands = LockIsolated<[ProjectWorkspaceGitCommand]>([])
    let apiPath = rootURL.appending(path: "api").standardizedFileURL.path(percentEncoded: false)
    let failures = await ProjectWorkspace.removeWorktrees(
      workspace,
      rootURL: rootURL,
      gitRunner: ProjectWorkspaceGitRunner { command in
        commands.withValue { $0.append(command) }
      }
    )

    #expect(failures.isEmpty)
    #expect(
      commands.value.map(\.arguments) == [
        ["-C", bareURL.path(percentEncoded: false), "worktree", "remove", "--force", apiPath]
      ])
    // removeWorktrees must leave the folder and the linked source intact.
    #expect(FileManager.default.fileExists(atPath: rootURL.path(percentEncoded: false)))
    ProjectWorkspace.removeWorkspaceFolder(at: rootURL)
    #expect(!FileManager.default.fileExists(atPath: rootURL.path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: linkedSourceURL.path(percentEncoded: false)))
  }

  @Test func removeWorktreesDoesNotDeleteBranches() async throws {
    let rootURL = try makeTemporaryWorkspaceRoot()
    let bareURL = try makeTemporaryWorkspaceRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: bareURL)
    }
    try FileManager.default.createDirectory(
      at: rootURL.appending(path: "api"),
      withIntermediateDirectories: true
    )

    let workspace = ProjectWorkspace(
      repositories: [
        ProjectWorkspace.RepositoryEntry(
          id: "api",
          name: "API",
          path: "api",
          sourceKind: .bareRepository,
          sourceLocation: bareURL.path(percentEncoded: false),
          branchName: "chore/x"
        )
      ]
    )
    let commands = LockIsolated<[ProjectWorkspaceGitCommand]>([])
    let apiPath = rootURL.appending(path: "api").standardizedFileURL.path(percentEncoded: false)
    let failures = await ProjectWorkspace.removeWorktrees(
      workspace,
      rootURL: rootURL,
      gitRunner: ProjectWorkspaceGitRunner { command in
        commands.withValue { $0.append(command) }
      }
    )

    let barePath = bareURL.path(percentEncoded: false)
    #expect(failures.isEmpty)
    // Branch deletion is routed through GitClient's guarded entry point, never
    // the workspace git runner — so no `branch -D` is issued here.
    #expect(
      commands.value.map(\.arguments) == [
        ["-C", barePath, "worktree", "remove", "--force", apiPath]
      ])
  }

  @Test func removeWorktreesReportsFailedRemovals() async throws {
    let rootURL = try makeTemporaryWorkspaceRoot()
    let bareURL = try makeTemporaryWorkspaceRoot()
    defer {
      try? FileManager.default.removeItem(at: rootURL)
      try? FileManager.default.removeItem(at: bareURL)
    }
    try FileManager.default.createDirectory(
      at: rootURL.appending(path: "api"),
      withIntermediateDirectories: true
    )

    let workspace = ProjectWorkspace(
      repositories: [
        ProjectWorkspace.RepositoryEntry(
          id: "api",
          name: "API",
          path: "api",
          sourceKind: .bareRepository,
          sourceLocation: bareURL.path(percentEncoded: false),
          branchName: "chore/x"
        )
      ]
    )
    let failures = await ProjectWorkspace.removeWorktrees(
      workspace,
      rootURL: rootURL,
      gitRunner: ProjectWorkspaceGitRunner { _ in
        throw ProjectWorkspaceCreationError.gitCommandFailed(
          command: "git worktree remove", message: "broken")
      }
    )

    #expect(failures == ["API"])
    // A failed worktree removal must not delete the folder.
    #expect(FileManager.default.fileExists(atPath: rootURL.path(percentEncoded: false)))
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

  @Test func repositoryWithWorkspaceIsAlwaysPlain() {
    let rootURL = URL(fileURLWithPath: "/tmp/workspace")
    let repository = Repository(
      id: rootURL.path(percentEncoded: false),
      rootURL: rootURL,
      name: "Workspace",
      kind: .git,
      worktrees: [],
      workspace: ProjectWorkspace(title: "Workspace")
    )

    #expect(repository.kind == .plain)
    #expect(repository.isWorkspace)
  }

  private func makeTemporaryWorkspaceRoot() throws -> URL {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "prowl-workspace-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    return rootURL
  }

  private func writeWorkspaceJSON(_ json: String, to rootURL: URL) throws {
    let metadataDirectoryURL = rootURL.appending(path: ProjectWorkspace.metadataDirectoryName)
    try FileManager.default.createDirectory(
      at: metadataDirectoryURL, withIntermediateDirectories: true)
    try Data(json.utf8).write(to: ProjectWorkspace.metadataURL(for: rootURL))
  }

  private func normalizedTestPath(_ url: URL) -> String {
    var path = PathPolicy.normalizeURL(url).path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") {
      path.removeLast()
    }
    return path
  }
}
