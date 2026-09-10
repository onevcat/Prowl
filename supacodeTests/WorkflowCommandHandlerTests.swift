// supacodeTests/WorkflowCommandHandlerTests.swift
// `prowl workflow list` over the socket: worktree resolution, three-source discovery, enabled set.

import Foundation
import GhosttyKit
import ProwlCLIShared
import Testing

@testable import supacode

@MainActor
struct WorkflowCommandHandlerTests {
  private static let minimal = """
    schema: prowl.workflow/v1
    id: %ID%
    name: Demo
    roles:
      author:
        source: current
    steps:
      - id: ask
        message: author
        prompt: "Say hello."
    """

  private struct Fixture {
    let root: URL
    let userWorkflows: URL
    let repoRoot: URL
    let paneID = UUID()
    let shellPID: pid_t = 4242

    init() throws {
      root =
        FileManager.default.temporaryDirectory
        .appending(path: "prowl-workflow-handler-\(UUID().uuidString)", directoryHint: .isDirectory)
        .standardizedFileURL
      userWorkflows = root.appending(path: "home/.prowl/workflows", directoryHint: .isDirectory)
      repoRoot = root.appending(path: "repo", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: userWorkflows, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: WorkflowSources.repoDirectory(root: repoRoot), withIntermediateDirectories: true)
      try write("demo", to: userWorkflows.appending(path: "demo.pwlworkflow"))
      try write(
        "repo-only", to: WorkflowSources.repoDirectory(root: repoRoot).appending(path: "repo.pwlworkflow"))
    }

    func write(_ id: String, to url: URL) throws {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      try Data(WorkflowCommandHandlerTests.minimal.replacingOccurrences(of: "%ID%", with: id).utf8)
        .write(to: url.appending(path: "workflow.yaml"))
    }

    func cleanUp() {
      try? FileManager.default.removeItem(at: root)
    }

    func snapshot(focused: Bool = true, disabled: Set<String> = []) -> WorkflowRuntimeSnapshot {
      let surfaceView = GhosttySurfaceView(
        runtime: GhosttyRuntime(),
        workingDirectory: nil,
        context: GHOSTTY_SURFACE_CONTEXT_TAB,
        skipsSurfaceCreationForTesting: true
      )
      let pane = TargetResolutionSnapshot.Pane(
        id: paneID, handle: 1, title: "shell", cwd: repoRoot.path(percentEncoded: false),
        isFocusedInTab: true,
        surfaceView: surfaceView)
      let tab = TargetResolutionSnapshot.Tab(
        id: UUID(), handle: 1, title: "Tab", selected: true, panes: [pane], focusedPaneID: paneID)
      let worktree = TargetResolutionSnapshot.Worktree(
        id: "wt-1", name: "main", path: repoRoot.path(percentEncoded: false),
        rootPath: repoRoot.path(percentEncoded: false), kind: .git, tabs: [tab])
      return WorkflowRuntimeSnapshot(
        resolution: TargetResolutionSnapshot(
          worktrees: [worktree], focusedWorktreeID: focused ? "wt-1" : nil),
        paneByShellPID: [shellPID: CallerPane(worktreeID: "wt-1", surfaceID: paneID)],
        bundleWorkflowsURL: nil,
        userWorkflowsURL: userWorkflows,
        disabledWorkflowIDs: disabled,
        bundledSkillIDs: [],
        knownAgents: ["codex", "claude"],
        installedAgents: nil,
        enabledProfiles: []
      )
    }
  }

  private func list(
    _ handler: WorkflowCommandHandler, target: TargetSelector = .none,
    context: CLICommandContext = CLICommandContext()
  ) async throws -> (CommandResponse, WorkflowListPayload?) {
    let envelope = CommandEnvelope(
      output: .json, command: .workflow(WorkflowInput(action: .list, target: target)))
    let response = await handler.handle(envelope: envelope, context: context)
    guard let data = response.data else { return (response, nil) }
    guard
      case .list(let payload) = try JSONDecoder().decode(
        WorkflowCommandPayload.self, from: data.bytes)
    else {
      return (response, nil)
    }
    return (response, payload)
  }

  @Test func callerPaneSelectsItsWorktreeAndTheRepoSource() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let handler = WorkflowCommandHandler {
      fixture.snapshot(focused: false, disabled: ["user/demo"])
    }
    let context = CLICommandContext(
      callerProcessID: 9999,
      callerProcessAncestry: [CallerProcessIdentity(processID: fixture.shellPID, startedAt: nil)])

    let (response, payload) = try await list(handler, context: context)
    #expect(response.ok)
    #expect(response.schemaVersion == "prowl.cli.workflow.v1")
    let listed = try #require(payload)
    #expect(listed.worktree?.id == "wt-1")
    #expect(
      listed.sources.repo
        == WorkflowSources.repoDirectory(root: fixture.repoRoot).path(percentEncoded: false))
    #expect(listed.sources.bundle == nil)
    #expect(listed.workflows.map(\.id) == ["demo", "repo-only"])
    #expect(listed.workflows.map(\.scope) == [.user, .repo])
    #expect(listed.workflows.map(\.enabled) == [false, true])
    #expect(listed.workflows.map(\.valid) == [true, true])
  }

  @Test func withoutACallerTheFocusedWorktreeIsUsed() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let handler = WorkflowCommandHandler { fixture.snapshot(focused: true) }
    let (_, payload) = try await list(handler)
    #expect(payload?.worktree?.id == "wt-1")
    #expect(payload?.workflows.map(\.id) == ["demo", "repo-only"])
  }

  @Test func withoutAnyWorktreeOnlyBundleAndUserSourcesAreSearched() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let handler = WorkflowCommandHandler { fixture.snapshot(focused: false) }
    let (response, payload) = try await list(handler)
    #expect(response.ok)
    #expect(payload?.worktree == nil)
    #expect(payload?.sources.repo == nil)
    #expect(payload?.workflows.map(\.id) == ["demo"])
  }

  @Test func explicitSelectorsResolveThroughTheTargetResolver() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let handler = WorkflowCommandHandler { fixture.snapshot(focused: false) }
    let (_, byName) = try await list(handler, target: .worktree("main"))
    #expect(byName?.worktree?.id == "wt-1")
    let (_, byPane) = try await list(handler, target: .auto("p1"))
    #expect(byPane?.worktree?.id == "wt-1")
    let (missing, _) = try await list(handler, target: .worktree("nope"))
    #expect(missing.ok == false)
    #expect(missing.error?.code == CLIErrorCode.targetNotFound)
  }

  @Test func unreadableSourceDirectoriesFailWithWorkflowFailed() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let path = fixture.userWorkflows.path(percentEncoded: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
    let handler = WorkflowCommandHandler { fixture.snapshot(focused: true) }
    let (response, _) = try await list(handler)
    #expect(response.ok == false)
    #expect(response.error?.code == CLIErrorCode.workflowFailed)
  }

  @Test func repositoryEnabledStateUsesTheResolvedRepositoryIdentity() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let disabledKey = WorkflowPreferenceKey.make(
      scope: .repo(repositoryID: fixture.repoRoot.path(percentEncoded: false)),
      workflowID: "repo-only")
    let handler = WorkflowCommandHandler {
      fixture.snapshot(focused: true, disabled: [disabledKey])
    }

    let (_, payload) = try await list(handler)

    #expect(payload?.workflows.map(\.enabled) == [true, false])
  }

  @Test func routerStubsWorkflowUntilWired() async {
    let response = await CLICommandRouter().route(
      CommandEnvelope(output: .json, command: .workflow(WorkflowInput())))
    #expect(response.command == "workflow")
    #expect(response.error?.code == "NOT_IMPLEMENTED")
  }
}
